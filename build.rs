//! ffmpeg-embed build script.
//!
//! Wires the consumer crate's link line to the static archives staged
//! under `dist/lib/` by `scripts/build-ffmpeg.sh`. Mirrors the role of
//! pdfium-render-bundled's build.rs.
//!
//! Hard requirement: `dist/lib/` must contain libavformat.a,
//! libavcodec.a, libavutil.a, libswscale.a, libswresample.a. If the
//! script has not been run, this build fails fast with a clear
//! message — no fallback, no silent partial link.

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::path::PathBuf;

fn main() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let dist_lib = manifest_dir.join("dist").join("lib");

    let archives = [
        "libavformat.a",
        "libavcodec.a",
        "libavutil.a",
        "libswscale.a",
        "libswresample.a",
    ];

    // Fingerprint the static archives by hashing (path, mtime, size)
    // for each one. Emitting it as a `cargo:rustc-env=` makes cargo
    // re-run rustc on this crate every time the archives change,
    // which in turn forces every downstream binary to relink against
    // the fresh `.a` content. Without this, replacing the archives
    // in place leaves cargo with stale incremental state and ships
    // binaries linked to whatever ffmpeg config existed at first
    // build (e.g. video-only decoders), even though the archives
    // on disk now contain the audio decoders/encoders the new code
    // calls into. Watching `dist/lib` as a directory is unreliable
    // because cargo's directory-mtime check varies by filesystem;
    // a per-file (mtime, size) hash is deterministic.
    let mut fingerprint = DefaultHasher::new();
    for archive in archives {
        let path = dist_lib.join(archive);
        if !path.is_file() {
            panic!(
                "ffmpeg-embed: required static archive {:?} not present.\n\
                 Run scripts/build-ffmpeg.sh from the ffmpeg-embed directory to produce dist/.\n\
                 Mirroring pdfium-render-bundled, the bundled artifacts are this crate's contract — \
                 they are not optional and must not be silently fallen back on system ffmpeg.",
                path
            );
        }
        let meta = std::fs::metadata(&path).unwrap_or_else(|e| {
            panic!(
                "ffmpeg-embed: cannot stat {:?}: {} — required for fingerprinting",
                path, e
            );
        });

        // Platform check. The archives committed to the repo can be
        // for the wrong OS — e.g. a Linux build of ffmpeg-bundle
        // committed by accident — and the link will fail far down
        // the build with the opaque
        // "archive member 'aacdec.o' not a mach-o file" error.
        // Detect that here by reading the file once and looking for
        // ELF or mach-o magic bytes. On the wrong OS we panic with a
        // message that says exactly what to do.
        verify_archive_platform(&path);

        archive.hash(&mut fingerprint);
        meta.len().hash(&mut fingerprint);
        if let Ok(mtime) = meta.modified() {
            // Hash the SystemTime; its Debug shape is stable enough
            // for hashing across runs on the same machine.
            format!("{:?}", mtime).hash(&mut fingerprint);
        }
        // Per-file rerun-if-changed. Cargo watches each file for
        // mtime/content changes — far more reliable than watching
        // the parent directory.
        println!("cargo:rerun-if-changed={}", path.to_string_lossy());
    }

    // Fold the C accessors source into the fingerprint too. Editing
    // accessors.c (without changing any `.a`) recompiles the shim
    // object via `cc::Build` below, but downstream cartridge bins
    // would otherwise reuse their cached link of the prior shim
    // object — leaving them missing any newly-added accessor symbol.
    // Hashing accessors.c into the env-baked fingerprint guarantees
    // the rlib's content changes, which forces every dependent
    // binary to relink against the freshly-compiled accessors object.
    let accessors_path = manifest_dir.join("src").join("accessors.c");
    if let Ok(bytes) = std::fs::read(&accessors_path) {
        bytes.hash(&mut fingerprint);
    }

    println!(
        "cargo:rustc-env=FFMPEG_BUNDLE_FINGERPRINT={:016x}",
        fingerprint.finish()
    );

    println!("cargo:rerun-if-changed=dist/link_flags.txt");
    println!("cargo:rerun-if-changed=src/accessors.c");
    println!("cargo:rerun-if-changed=src/lib.rs");

    // Compile the C shim that reads fields off ffmpeg's opaque
    // structs. Linking it in this same crate keeps the Rust side
    // free of any layout assumption about ffmpeg internals.
    let dist_include = manifest_dir.join("dist").join("include");
    if !dist_include.is_dir() {
        panic!(
            "ffmpeg-embed: dist/include is missing — scripts/build-ffmpeg.sh has not staged headers. \
             dist/include is required to compile the C accessors shim."
        );
    }
    cc::Build::new()
        .file("src/accessors.c")
        .include(&dist_include)
        .warnings(true)
        .extra_warnings(true)
        // ffmpeg's headers use older C99; -std=c11 is fine for our shim.
        .flag_if_supported("-std=c11")
        .compile("ffmpeg_embed_accessors");

    // Tell rustc where to find the archives and which to link.
    println!(
        "cargo:rustc-link-search=native={}",
        dist_lib.to_string_lossy()
    );

    // Link order matters with --as-needed linkers; the dependency
    // direction inside ffmpeg is roughly:
    //   avformat -> avcodec -> swresample -> avutil
    //   avformat -> swscale -> avutil
    //   avcodec  -> swresample -> avutil
    //   swscale  -> avutil
    // We list the most-dependent first.
    println!("cargo:rustc-link-lib=static=avformat");
    println!("cargo:rustc-link-lib=static=avcodec");
    println!("cargo:rustc-link-lib=static=swscale");
    println!("cargo:rustc-link-lib=static=swresample");
    println!("cargo:rustc-link-lib=static=avutil");

    // Standard C deps that every ffmpeg build pulls in.
    println!("cargo:rustc-link-lib=dylib=z");

    #[cfg(target_os = "macos")]
    {
        // Apple frameworks ffmpeg's mac codepaths reference. These
        // mirror the entries in dist/link_flags.txt; the txt file is
        // there for downstream consumers that want a manual link
        // line (e.g. C tooling or non-cargo build systems).
        println!("cargo:rustc-link-lib=framework=CoreFoundation");
        println!("cargo:rustc-link-lib=framework=CoreVideo");
        println!("cargo:rustc-link-lib=framework=CoreMedia");
        println!("cargo:rustc-link-lib=framework=VideoToolbox");
        println!("cargo:rustc-link-lib=framework=AudioToolbox");
        println!("cargo:rustc-link-lib=framework=Security");
        println!("cargo:rustc-link-lib=framework=CoreServices");
    }

    // Allow downstream override of the search path. Useful for CI
    // setups where dist/ is staged elsewhere.
    if let Ok(extra) = std::env::var("FFMPEG_EMBED_LIB_PATH") {
        println!("cargo:rustc-link-search=native={}", extra);
    }
}

/// Verify that a static archive's object members match the host
/// platform. Reads the file once and scans for known object-file magic
/// markers — ELF (`\x7fELF`) and mach-o (the four canonical mach-o
/// magic words plus the fat `\xCA\xFE\xBA\xBE`/`\xCA\xFE\xBA\xBF`
/// variants). On a mismatch — e.g. a Linux ELF archive landing in a
/// macOS build — panic with the rebuild instruction. Without this
/// check the link fails much later with the cryptic clang error
/// "archive member 'X.o' not a mach-o file".
fn verify_archive_platform(path: &std::path::Path) {
    let bytes = match std::fs::read(path) {
        Ok(b) => b,
        Err(e) => panic!(
            "ffmpeg-bundle: cannot read {:?} for platform verification: {}",
            path, e
        ),
    };

    // Quick sniff for ELF (`\x7fELF`) and mach-o magic anywhere in the
    // archive payload. Static `.a` files are an `ar` archive of object
    // members — looking for the magic of those members is enough to
    // identify the platform without parsing the archive format.
    let elf_magic = b"\x7fELF";
    let macho_magics: &[&[u8]] = &[
        b"\xfe\xed\xfa\xce", // MH_MAGIC      (32-bit, BE host)
        b"\xfe\xed\xfa\xcf", // MH_MAGIC_64   (64-bit, BE host)
        b"\xce\xfa\xed\xfe", // MH_CIGAM      (32-bit, LE host)
        b"\xcf\xfa\xed\xfe", // MH_CIGAM_64   (64-bit, LE host)
        b"\xca\xfe\xba\xbe", // FAT_MAGIC
        b"\xca\xfe\xba\xbf", // FAT_MAGIC_64
    ];

    fn contains(hay: &[u8], needle: &[u8]) -> bool {
        hay.windows(needle.len()).any(|w| w == needle)
    }

    let has_elf = contains(&bytes, elf_magic);
    let has_macho = macho_magics.iter().any(|m| contains(&bytes, m));

    let want_macho = cfg!(target_os = "macos");
    let want_elf = cfg!(any(target_os = "linux", target_os = "android"));

    if want_macho && !has_macho {
        let detected = if has_elf { "ELF (Linux)" } else { "unknown" };
        panic!(
            "ffmpeg-bundle: archive {:?} is not a macOS static library (detected: {}). \
             The committed ffmpeg-bundle/dist/ artifacts appear to be for a different platform. \
             Rebuild them from this machine: run `scripts/build-ffmpeg.sh` from the ffmpeg-bundle \
             directory.",
            path, detected
        );
    }
    if want_elf && !has_elf {
        let detected = if has_macho { "mach-o (macOS)" } else { "unknown" };
        panic!(
            "ffmpeg-bundle: archive {:?} is not a Linux static library (detected: {}). \
             The committed ffmpeg-bundle/dist/ artifacts appear to be for a different platform. \
             Rebuild them from this machine: run `scripts/build-ffmpeg.sh` from the ffmpeg-bundle \
             directory.",
            path, detected
        );
    }
}
