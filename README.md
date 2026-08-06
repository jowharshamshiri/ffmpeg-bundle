# ffmpeg-bundle

Embedded LGPL-only ffmpeg static archives + a hand-written Rust FFI
shim. Mirrors the role of [`pdfcartridge/pdfium-render-bundled`](../pdfcartridge/pdfium-render-bundled):
the project that builds the C library and exposes it to a downstream
Rust cartridge as a self-contained dependency, with no system
ffmpeg required at runtime.

## What's here

- `scripts/build-ffmpeg.sh` — fetches the pinned ffmpeg release
  (`ffmpeg-version.txt`), runs `./configure` with a tightly minimised
  feature set, builds, and stages `dist/{lib,include,link_flags.txt}`.
- `src/lib.rs` — hand-curated `extern "C"` declarations for the
  ~30-symbol API surface used by `videocartridge` (libavformat
  open/read, libavcodec decode loop, libswscale color conversion,
  libavutil frame allocation).
- `src/accessors.c` — tiny C shim implementing field accessors over
  ffmpeg's opaque structs (`AVFormatContext`, `AVStream`,
  `AVCodecParameters`, `AVPacket`, `AVFrame`). Compiled by `build.rs`
  against `dist/include/`. The Rust side never lays out an ffmpeg
  struct itself.
- `build.rs` — emits `cargo:rustc-link-*` directives pointing at
  `dist/lib/` and the macOS frameworks ffmpeg needs at link time.

## Producing the artifacts

From this directory:

```sh
./scripts/build-ffmpeg.sh
```

Requirements on the build host:

- Xcode command-line tools (clang, make).
- `nasm` or `yasm` for x86 SIMD asm (Apple Silicon: `brew install nasm`).
- `pkg-config`, `curl`, `tar`.

The script:

1. Reads `ffmpeg-version.txt` (e.g. `n7.1`).
2. Downloads `https://ffmpeg.org/releases/ffmpeg-7.1.tar.gz` into
   `sources/ffmpeg-n7.1/` if not already present.
3. Configures ffmpeg with `--disable-everything` plus a small
   re-enable list (see the script for the exact codecs/demuxers/
   parsers/protocols).
4. Builds in `build/n7.1/` with `make -j$(nproc)`.
5. Installs into `dist/`. Wipes `dist/` first to keep it idempotent.

Re-run on demand. To bump the ffmpeg version, edit
`ffmpeg-version.txt` and re-run.

## Feature scope

The current configuration enables only what `videocartridge`'s
video-to-frames cap needs:

| Category | Enabled |
|---|---|
| Decoders | h264, hevc, vp8, vp9, av1, mpeg4, mjpeg |
| Demuxers | mov (mp4/mov), matroska (mkv/webm), avi, mpegts, flv |
| Parsers | h264, hevc, vp8, vp9, av1, mpeg4video, mjpeg |
| Bitstream filters | h264_mp4toannexb, hevc_mp4toannexb |
| Protocols | file, pipe |
| swscale, swresample | yes (used directly via C API) |
| Encoders, muxers, filters, avfilter | **disabled** — frame output happens in Rust via the `image` crate |
| avdevice (+ alsa/v4l2 indevs on Linux, avfoundation on macOS) | **enabled** — live-feed capture backends (microphone/webcam providers, 13.2 §Reference Media). Requires regenerating `dist/` per platform; the capture providers in audio/videocartridge land against the regenerated archives. |
| GPL, nonfree | **disabled** |
| Network, autodetect | **disabled** |

Programs (`ffmpeg`, `ffplay`, `ffprobe`), docs, and shared libraries
are all disabled. Output is exclusively static archives + headers.

## License

ffmpeg is built **LGPL-2.1-or-later** here (no `--enable-gpl`, no
`--enable-nonfree`). Downstream redistribution must comply with
LGPL section 4 (allow relinking against a different libffmpeg).
This is the same posture as pdfcartridge's libpdfium bundle.

## Linking

`build.rs` emits the necessary `cargo:rustc-link-*` directives so
that any crate depending on `ffmpeg-bundle` gets the static archives
and Apple frameworks linked automatically. There is no system
ffmpeg dependency.

If `dist/lib/` is missing when a downstream crate compiles,
`build.rs` panics with a clear instruction to run the build script.
**There is no fallback to a system ffmpeg** — by design. We want
the link to fail loudly rather than silently pick up whatever ffmpeg
happens to be installed on the host.

## Why hand-written FFI instead of `bindgen` / `ffmpeg-sys-next`

- The API surface we need is tiny (~30 functions, a handful of
  opaque struct types).
- Hand-written `extern "C"` is more stable across ffmpeg point
  releases than bindgen output, which regenerates from headers and
  produces noisy diffs on every minor version.
- We avoid pulling `bindgen` + `libclang` into the build of every
  cartridge that depends on us.
- The `accessors.c` shim handles every place where we'd otherwise
  need to know an ffmpeg struct's layout, so a future ffmpeg version
  bump is a re-build of `accessors.c` against the new headers — no
  Rust change required.
