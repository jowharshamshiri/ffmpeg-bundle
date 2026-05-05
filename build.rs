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
    }

    // Re-run if any of the archives changes on disk.
    println!("cargo:rerun-if-changed=dist/lib");
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
