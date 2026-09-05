//! ffmpeg-bundle build script.
//!
//! PRODUCES the static archives, then wires the consumer's link line to
//! them. It does not expect to find them: `scripts/build-ffmpeg.sh` is a
//! pinned recipe, and running it here is what lets this crate be resolved
//! from a git tag and built like any other dependency — no prebuilt binary
//! in the repository, no manual step before the first `cargo build`.
//!
//! Nothing is written into the source tree. Output goes to
//! `FFMPEG_BUNDLE_BUILD_DIR` when set, and otherwise to cargo's own
//! `OUT_DIR` — both are build directories, and neither is committed.
//! Pointing the variable at one shared location is worth doing in a
//! workspace with several target directories, because `OUT_DIR` differs per
//! target directory and ffmpeg would otherwise be compiled once per tree.
//!
//! The output directory is CONTENT-ADDRESSED by a build identity: the pinned
//! version, the recipe itself, and the target platform. A cached tree is
//! reused only when it was produced by exactly this input, so changing the
//! version or a configure flag cannot leave a consumer linked against the
//! previous build — and a tree is published by an atomic rename, so a reader
//! never observes a half-written one.

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

fn main() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let dist = ensure_dist(&manifest_dir);
    let dist_lib = dist.join("lib");

    // What the archives are CALLED, which is the platform's convention and
    // not ffmpeg's. ffmpeg names its static libraries `libavcodec.a` on every
    // toolchain including MSVC — the file is an MSVC archive either way — but
    // `link.exe` looks for `avcodec.lib` and so does rustc's
    // `link-lib=static=avcodec`, so the Windows recipe renames them and this
    // reads the names it wrote.
    let archives: [String; 6] = [
        "avdevice", "avformat", "avcodec", "avutil", "swscale", "swresample",
    ]
    .map(archive_file_name);

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
    // By reference: these are owned `String`s now, because the file name is
    // built per platform rather than being a literal. Iterating by value moves
    // each one into the join and then hashes it below.
    for archive in &archives {
        let path = dist_lib.join(archive);
        if !path.is_file() {
            // The build ran and reported success, so a missing archive means
            // the recipe and this list disagree about what it produces. That
            // is a defect in this crate, not something a consumer can act on.
            panic!(
                "ffmpeg-bundle: {:?} is missing after a successful build of {:?}.\n\
                 scripts/build-ffmpeg.sh and the archive list in build.rs disagree \
                 about what the recipe produces.",
                path, dist
            );
        }
        let meta = std::fs::metadata(&path).unwrap_or_else(|e| {
            panic!(
                "ffmpeg-embed: cannot stat {:?}: {} — required for fingerprinting",
                path, e
            );
        });

        // Platform check. A cached tree can be for the wrong OS — a
        // build directory shared across machines, or a network mount —
        // and the link then fails far down the build with the opaque
        // "archive member 'aacdec.o' not a mach-o file" error. Detect
        // it here by reading the file once and looking for ELF or
        // mach-o magic bytes. The build identity includes the target
        // platform, so this should be unreachable; it stays because the
        // failure it replaces is unreadable.
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

    println!("cargo:rerun-if-changed=src/accessors.c");
    println!("cargo:rerun-if-changed=src/lib.rs");

    // Compile the C shim that reads fields off ffmpeg's opaque
    // structs. Linking it in this same crate keeps the Rust side
    // free of any layout assumption about ffmpeg internals.
    let dist_include = dist.join("include");
    if !dist_include.is_dir() {
        panic!(
            "ffmpeg-bundle: {:?} is missing after a successful build — the recipe did not \
             stage headers, which the C accessors shim needs to compile.",
            dist_include
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
    //   avdevice -> avformat -> avcodec -> swresample -> avutil
    //   avformat -> swscale -> avutil
    //   avcodec  -> swresample -> avutil
    //   swscale  -> avutil
    // We list the most-dependent first. avdevice carries the capture
    // input formats (alsa/v4l2 on Linux, avfoundation on macOS) the
    // live-feed providers open (13.2 §Reference Media).
    println!("cargo:rustc-link-lib=static=avdevice");
    println!("cargo:rustc-link-lib=static=avformat");
    println!("cargo:rustc-link-lib=static=avcodec");
    println!("cargo:rustc-link-lib=static=swscale");
    println!("cargo:rustc-link-lib=static=swresample");
    println!("cargo:rustc-link-lib=static=avutil");

    // Standard C deps. The minimal config (--disable-autodetect) pulls zlib in
    // on Unix; the Windows build has no zlib (verified: no inflate/deflate
    // symbols in the archives), so z is linked only off-Windows.
    #[cfg(not(target_os = "windows"))]
    println!("cargo:rustc-link-lib=dylib=z");

    // avdevice's alsa indev (microphone capture) calls into the system
    // ALSA client library.
    #[cfg(target_os = "linux")]
    println!("cargo:rustc-link-lib=dylib=asound");

    #[cfg(target_os = "windows")]
    {
        // The archives are MSVC-format, built with cl.exe, because that is the
        // ABI everything downstream links against: the Rust toolchain on
        // Windows is MSVC-hosted, and it has to be — `rusty_v8` publishes no
        // `x86_64-pc-windows-gnu` build of V8, so a GNU-hosted toolchain
        // cannot build anything that depends on deno_core.
        //
        // The MSVC toolchain brings its own C runtime, so nothing is named for
        // that. What is named is what ffmpeg itself references, and each is a
        // system import library:
        //   bcrypt  - avutil's CPRNG via BCryptGenRandom
        //   secur32 - SSPI, pulled in by some avformat paths
        //   ws2_32  - Winsock (the pipe protocol and some demuxers)
        //
        // `winpthread` is deliberately absent: it is MinGW's pthread shim, and
        // an MSVC build of ffmpeg uses Win32 threads (`--enable-w32threads`)
        // and never references it. These mirror dist/link_flags.txt.
        println!("cargo:rustc-link-lib=bcrypt");
        println!("cargo:rustc-link-lib=secur32");
        println!("cargo:rustc-link-lib=ws2_32");
    }

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
        // avdevice's avfoundation indev (microphone/camera capture).
        println!("cargo:rustc-link-lib=framework=AVFoundation");
        println!("cargo:rustc-link-lib=framework=CoreAudio");
        println!("cargo:rustc-link-lib=framework=CoreGraphics");
        println!("cargo:rustc-link-lib=framework=Foundation");
    }

}

/// Produce the archives, or reuse a cached tree built from exactly this input.
///
/// Returns the dist directory to link against.
fn ensure_dist(manifest_dir: &Path) -> PathBuf {
    println!("cargo:rerun-if-env-changed=FFMPEG_BUNDLE_BUILD_DIR");
    println!("cargo:rerun-if-changed=ffmpeg-version.txt");
    // BOTH recipes, not this platform's. `rerun-if-changed` is about when to
    // run the build script at all, and running it when the other platform's
    // recipe moved costs one cheap re-execution that finds its dist already
    // there. Naming only one would mean a Windows machine never noticing an
    // edit to the recipe it actually uses.
    println!("cargo:rerun-if-changed=scripts/build-ffmpeg.sh");
    println!("cargo:rerun-if-changed=scripts/build-ffmpeg.ps1");

    let out_dir = PathBuf::from(
        std::env::var("OUT_DIR").expect("cargo always sets OUT_DIR for a build script"),
    );
    // `OUT_DIR` is cargo's build directory for this crate, so the default
    // already keeps output out of the source tree. The override exists because
    // `OUT_DIR` differs per target directory, and a workspace with several
    // would otherwise compile ffmpeg once per tree.
    let build_root = match std::env::var("FFMPEG_BUNDLE_BUILD_DIR") {
        Ok(dir) if !dir.trim().is_empty() => PathBuf::from(dir),
        _ => out_dir,
    };

    let identity = build_identity(manifest_dir);
    // Content-addressed: a tree is reused only when it was produced by this
    // exact version, recipe and platform. Reusing one across a version bump is
    // how a consumer ends up linked against libraries nobody asked for.
    let dist = build_root.join(format!("dist-{identity}"));
    if dist.join("lib").is_dir() {
        return dist;
    }

    // One builder at a time. Two cargo invocations can reach here at once —
    // a workspace test run drives several target directories in parallel and
    // more than one depends on this crate — and compiling ffmpeg twice into
    // the same place wastes many minutes for a result only one can publish.
    let lock = build_root.join(format!("lock-{identity}"));
    let held = acquire(&lock);
    if !held {
        // Someone else is building it. Wait for their tree, then use it.
        if wait_for(&dist) {
            return dist;
        }
        // They died without publishing. Take over rather than fail: the
        // alternative is a build that cannot proceed until a human removes a
        // lock directory they never knew existed.
        println!("cargo:warning=ffmpeg-bundle: taking over a stale build lock at {lock:?}");
        let _ = std::fs::remove_dir(&lock);
        if !acquire(&lock) && !wait_for(&dist) {
            panic!("ffmpeg-bundle: cannot acquire the build lock at {lock:?}");
        }
    }

    // Re-check under the lock: the previous holder may have finished between
    // our first look and our acquiring it.
    if dist.join("lib").is_dir() {
        let _ = std::fs::remove_dir(&lock);
        return dist;
    }

    // Build in a scratch tree and PUBLISH by rename. A reader can then only
    // ever see a complete tree — never one mid-write, which links against
    // whatever archives happened to exist at that instant.
    //
    // The scratch is named from the identity, not the process: it holds the
    // fetched tarball and the make tree, both worth reusing when a build is
    // retried, and the lock above already guarantees a single writer. Naming
    // it per process would leave a fresh multi-hundred-megabyte copy behind on
    // every attempt.
    let scratch = build_root.join(format!("scratch-{identity}"));
    let result = run_recipe(manifest_dir, &scratch);
    if result.is_ok() {
        // The recipe writes `dist/` under the directory it is given.
        if std::fs::rename(scratch.join("dist"), &dist).is_err() && !dist.join("lib").is_dir() {
            let _ = std::fs::remove_dir(&lock);
            panic!(
                "ffmpeg-bundle: cannot publish the built archives to {dist:?} — \
                 the build succeeded but its output could not be moved into place."
            );
        }
    }
    let _ = std::fs::remove_dir(&lock);
    match result {
        Ok(()) => dist,
        Err(message) => panic!("{message}"),
    }
}

/// One ffmpeg static library's file name on this platform.
///
/// `avcodec.lib` on Windows, `libavcodec.a` everywhere else. Windows is the
/// odd one because its LINKER is: `link.exe` resolves `avcodec` to
/// `avcodec.lib`, and a file called `libavcodec.a` is a file it will not find
/// however many MSVC objects are inside it.
fn archive_file_name(stem: &str) -> String {
    if cfg!(target_os = "windows") {
        format!("{stem}.lib")
    } else {
        format!("lib{stem}.a")
    }
}

/// The recipe for this platform, and the program that runs it.
///
/// Two recipes, because the build environments are not the same shape: a Unix
/// host has make and clang on PATH, and a Windows host has the MSVC compiler
/// from the Build Tools plus MSYS2 for the shell `configure` needs — which the
/// PowerShell recipe locates and drives.
///
/// The Windows recipe was committed and never referenced. Every Windows build
/// ran `bash build-ffmpeg.sh`, found no bash, and reported that the SCRIPT
/// could not be found — which sent the reader to look at a file that was
/// sitting right there.
fn recipe(manifest_dir: &Path) -> (&'static str, Vec<String>, PathBuf) {
    let scripts = manifest_dir.join("scripts");
    if cfg!(target_os = "windows") {
        let script = scripts.join("build-ffmpeg.ps1");
        (
            "powershell",
            vec![
                "-NoProfile".to_string(),
                // The recipe is a file, and a guest's default execution policy
                // is Restricted, which refuses one. `Bypass` applies to what
                // this command loads.
                "-ExecutionPolicy".to_string(),
                "Bypass".to_string(),
                "-File".to_string(),
                script.display().to_string(),
            ],
            script,
        )
    } else {
        let script = scripts.join("build-ffmpeg.sh");
        ("bash", vec![script.display().to_string()], script)
    }
}

/// Run the pinned recipe, with its output directed at `into`.
fn run_recipe(manifest_dir: &Path, into: &Path) -> Result<(), String> {
    let (program, args, script) = recipe(manifest_dir);
    println!(
        "cargo:warning=ffmpeg-bundle: building ffmpeg from source into {into:?} \
         (once per version and platform; several minutes)"
    );
    let status = std::process::Command::new(program)
        .args(&args)
        .current_dir(manifest_dir)
        .env("FFMPEG_BUNDLE_BUILD_DIR", into)
        .status()
        // The PROGRAM, not the script. `Command::status` reports ENOENT about
        // the thing it tried to execute, and naming the script instead turned
        // "there is no bash on this machine" into "this file is missing" about
        // a file that is present — which is how a Windows build spent its
        // whole diagnosis on the wrong object.
        .map_err(|e| {
            format!(
                "ffmpeg-bundle: cannot run {program} to build the recipe {script:?}: {e}\n\
                 {program} is what runs the recipe on this platform, and it was not found."
            )
        })?;
    if !status.success() {
        return Err(format!(
            "ffmpeg-bundle: {script:?} failed ({status}).\n\
             {}",
            // What it NEEDS, not what is wrong: the recipe checks each tool and
            // prints `ok: <tool>` for the ones it found, so by the time this
            // runs the tools are usually all present and the failure is further
            // in. Stating a missing toolchain as the reason sent a whole
            // diagnosis after tools that were never absent; the compiler error
            // above this line is the thing to read.
            if cfg!(target_os = "windows") {
                "The recipe's own output above says where it stopped. It requires the \
                 Visual Studio Build Tools with the VC workload (cl.exe), nasm on PATH, \
                 and MSYS2 with make, diffutils and pkgconf — it reports each as `ok:` \
                 when it finds it, so a failure after those lines is a build error, not \
                 a missing tool."
            } else {
                "The recipe's own output above says where it stopped. It requires make, \
                 clang, pkg-config, curl, tar and one of nasm/yasm on PATH."
            }
        ));
    }
    Ok(())
}

/// A directory created atomically, held for the duration of a build.
///
/// `create_dir` is the primitive: it either creates the directory or reports
/// that it exists, in one step, on every filesystem worth building on. A lock
/// file written after a check is not the same thing.
fn acquire(lock: &Path) -> bool {
    if let Some(parent) = lock.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    std::fs::create_dir(lock).is_ok()
}

/// Wait for another builder to publish `dist`. Bounded, because a builder that
/// died holding the lock must not stall every consumer forever.
fn wait_for(dist: &Path) -> bool {
    let deadline = Instant::now() + Duration::from_secs(30 * 60);
    while Instant::now() < deadline {
        if dist.join("lib").is_dir() {
            return true;
        }
        std::thread::sleep(Duration::from_secs(2));
    }
    false
}

/// What the output depends on: the pinned version, the recipe that builds it,
/// and the platform it is built for.
///
/// The configure flags live inside the recipe, so hashing the recipe covers
/// them — there is no second place a flag can change without this noticing.
fn build_identity(manifest_dir: &Path) -> String {
    let mut hasher = DefaultHasher::new();
    // The pinned version, and THIS platform's recipe — the one that will
    // actually run. It used to name `build-ffmpeg.sh` outright, which was the
    // whole answer while that was the only recipe. It stopped being: a change
    // to the PowerShell recipe would have left every Windows dist addressed by
    // an identity that had not moved, so the stale one would be reused for
    // ever and the change would appear to have done nothing.
    let (_, _, script) = recipe(manifest_dir);
    for path in [manifest_dir.join("ffmpeg-version.txt"), script] {
        let bytes = std::fs::read(&path)
            .unwrap_or_else(|e| panic!("ffmpeg-bundle: cannot read {path:?}: {e}"));
        bytes.hash(&mut hasher);
    }
    std::env::var("TARGET").unwrap_or_default().hash(&mut hasher);
    format!("{:016x}", hasher.finish())
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

    // Windows was checked for nothing at all, because the check was written as
    // "is it the object format I want" and there was no marker named for COFF.
    // The mistake it exists to catch does not need one: what goes wrong is an
    // archive built on another platform ending up here, and an archive that is
    // ELF or mach-o is exactly that, whatever COFF looks like.
    if cfg!(target_os = "windows") && (has_elf || has_macho) {
        let detected = if has_elf { "ELF (Linux)" } else { "mach-o (macOS)" };
        panic!(
            "ffmpeg-bundle: archive {:?} holds {} objects, and this is a Windows build. \
             The dist it came from was produced on another platform. Delete it and let \
             `scripts/build-ffmpeg.ps1` run, which needs the Visual Studio Build Tools \
             and MSYS2.",
            path, detected
        );
    }
}
