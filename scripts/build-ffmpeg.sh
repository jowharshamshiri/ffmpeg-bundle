#!/usr/bin/env bash
#
# build-ffmpeg.sh — fetch a pinned ffmpeg release and produce static
# archives + headers under ./dist/, suitable for embedding into a
# downstream Rust crate without any system ffmpeg dependency.
#
# Mirrors the role of pdfcartridge/pdfium-render-bundled/dist: this
# script is the one source of truth for *how* the bundled libraries
# were configured. Re-running this script regenerates dist/ exactly,
# bit-for-bit modulo timestamps embedded by ffmpeg itself.
#
# We disable everything by default and re-enable only the muxers,
# demuxers, decoders, parsers, encoders, filters, and protocols
# strictly needed for video → frames decoding inside videocartridge.
# Network, GPL, nonfree, programs (ffmpeg/ffplay/ffprobe), examples,
# documentation: all off. On macOS we use the system clang and the
# Apple toolchain — no third-party deps.
#
# Hard requirements on the build machine:
#   - clang/cc (Xcode CLT)
#   - make, pkg-config, nasm or yasm (for x86 SIMD; the configure
#     auto-detects which)
#   - curl (or git) for source fetch
#
# Output:
#   ./dist/lib/libavformat.a
#   ./dist/lib/libavcodec.a
#   ./dist/lib/libavutil.a
#   ./dist/lib/libswscale.a
#   ./dist/lib/libswresample.a   (avformat depends on it)
#   ./dist/include/libav*/...
#   ./dist/include/libswscale/...
#   ./dist/include/libswresample/...
#   ./dist/link_flags.txt
#   ./dist/ffmpeg-version.txt
#
# Re-run on demand. Idempotent — wipes dist/ at the start.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

VERSION="$(cat ffmpeg-version.txt | tr -d '[:space:]')"
if [[ -z "$VERSION" ]]; then
    echo "ffmpeg-version.txt is empty; refusing to build" >&2
    exit 1
fi

SOURCES_DIR="$ROOT/sources"
SOURCE_DIR="$SOURCES_DIR/ffmpeg-$VERSION"
DIST_DIR="$ROOT/dist"
BUILD_DIR="$ROOT/build/$VERSION"

echo "==> ffmpeg-embed: building ffmpeg $VERSION"
echo "    SOURCE_DIR = $SOURCE_DIR"
echo "    BUILD_DIR  = $BUILD_DIR"
echo "    DIST_DIR   = $DIST_DIR"

# ---------------------------------------------------------------------------
# Tool sanity
# ---------------------------------------------------------------------------

require() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "missing required tool: $1" >&2
        exit 1
    fi
}
require make
require clang
require pkg-config
# nasm OR yasm — configure picks whichever is present
if ! command -v nasm >/dev/null 2>&1 && ! command -v yasm >/dev/null 2>&1; then
    echo "missing nasm or yasm (need one for SIMD asm); install with: brew install nasm" >&2
    exit 1
fi
require curl
require tar

# ---------------------------------------------------------------------------
# Fetch
# ---------------------------------------------------------------------------

if [[ ! -d "$SOURCE_DIR" ]]; then
    mkdir -p "$SOURCES_DIR"
    TARBALL="$SOURCES_DIR/ffmpeg-$VERSION.tar.gz"
    if [[ ! -f "$TARBALL" ]]; then
        URL="https://ffmpeg.org/releases/ffmpeg-${VERSION#n}.tar.gz"
        echo "==> Fetching $URL"
        curl -fL -o "$TARBALL" "$URL"
    fi
    echo "==> Extracting $TARBALL"
    tar -xzf "$TARBALL" -C "$SOURCES_DIR"
    # Tarball top-level directory is "ffmpeg-X.Y" (no n prefix); rename
    # to match our pinned tag form so everything else stays stable.
    if [[ -d "$SOURCES_DIR/ffmpeg-${VERSION#n}" && ! -d "$SOURCE_DIR" ]]; then
        mv "$SOURCES_DIR/ffmpeg-${VERSION#n}" "$SOURCE_DIR"
    fi
fi

# ---------------------------------------------------------------------------
# Configure
# ---------------------------------------------------------------------------
# Feature philosophy: disable EVERYTHING, then enable only what
# videocartridge needs to decode H.264, HEVC, VP9, AV1, MJPEG, MPEG-4
# from MP4/MOV/MKV/WebM containers, scale to a target size, and emit
# PNG/MJPEG frame images. No network protocols, no GPL/nonfree
# components, no programs, no docs. This keeps the static archives
# small and the patent/license posture clean (LGPL only).

# Decoders. Video: codecs you actually find in real-world video
# files (h264/hevc mandatory; vp8/vp9/av1 for web; mpeg4 for older
# MOV/MP4; mjpeg appears in some AVIs). Audio: aac (MOV/MP4 audio
# track), opus (WebM/MKV audio), flac/pcm/mp3 to support audio
# transcoding pipelines (audiocartridge).
# rawvideo: what v4l2/avfoundation webcams deliver for YUYV/NV12-class
# pixel formats (capture would otherwise fail with "no decoder for the
# device's codec"); mjpeg covers MJPEG cameras.
DECODERS=(h264 hevc vp8 vp9 av1 mpeg4 mjpeg rawvideo
          aac opus flac mp3 pcm_s16le pcm_s16be pcm_s24le pcm_s32le pcm_f32le vorbis alac)
# Encoders. flac for audiocartridge convert-audio outputs; aac for
# m4a remuxing fallback (the remux path doesn't transcode, but
# having the encoder makes the codec known to the muxer); pcm_s16le
# as the universal intermediate for WAV outputs.
ENCODERS=(flac aac pcm_s16le pcm_s24le pcm_f32le)
# Demuxers: containers we must read. mov covers .mov/.mp4/.m4a
# (they share the ISOBMFF demuxer). matroska covers .mkv/.webm.
# wav/flac/mp3/ogg/aac/aiff cover the standalone audio formats
# audiocartridge transcodes between.
DEMUXERS=(mov matroska avi mpegts flv
          wav flac mp3 ogg aac aiff)
# Muxers. ipod is ffmpeg's name for the M4A muxer (audio-only MP4
# variant); flac, wav, ogg, aac for the transcoded outputs the
# audiocartridge exposes.
MUXERS=(ipod mp4 flac wav ogg aac)
# Parsers: keyframe boundary parsing for the codecs above.
PARSERS=(h264 hevc vp8 vp9 av1 mpeg4video mjpeg
         aac opus flac mpegaudio)
# Filters: NONE. Our fps selection and resizing happens in Rust on
# already-decoded frames (sw scale is invoked directly via swscale's
# C API, not through libavfilter). Dropping libavfilter is the
# biggest single win — removes ~400 KB of static archive plus the
# huge filter graph machinery we don't need.
FILTERS=()
# Bitstream filters: needed to repackage encoded frames between
# extradata-bearing containers and our decoders.
BSFS=(h264_mp4toannexb hevc_mp4toannexb aac_adtstoasc)
# Protocols: only file: — we operate on bytes from stdin or a path,
# never the network. `pipe` lets us feed bytes via /dev/stdin.
PROTOCOLS=(file pipe)

# Build comma-separated lists for ./configure
join_csv() { local IFS=,; echo "$*"; }

CONFIG_FLAGS=(
    --prefix="$DIST_DIR"
    # Self-contained: static libraries, no shared, no programs.
    --disable-shared
    --enable-static
    --disable-programs
    --disable-doc
    --disable-htmlpages
    --disable-manpages
    --disable-podpages
    --disable-txtpages

    # License posture: stay LGPL-only.
    --disable-gpl
    --disable-nonfree

    # Networking / DRM / autodetect off.
    --disable-network
    --disable-autodetect

    # libavfilter pulls in a lot of code we don't use; drop it.
    --disable-avfilter
    # libavdevice: live-feed capture backends (13.2 §Reference Media) —
    # microphone/webcam providers in the audio/video cartridges open
    # devices through avdevice input formats (alsa/v4l2 on Linux,
    # avfoundation on macOS — enabled per-platform below). Regenerating
    # dist/ with this enabled is the gate for landing the capture
    # providers.
    --enable-avdevice
    # We never write container files, so libavformat's muxer path is
    # not exercised; the demuxer half is still on. Disabling muxers
    # globally saves a small amount.
    # (Per-muxer enables below win over the global; we just don't
    # re-enable any.)

    # Disable everything in each category, then re-enable per the lists.
    --disable-everything

    # Re-enable our minimal set.
    --enable-decoder=$(join_csv "${DECODERS[@]}")
    --enable-demuxer=$(join_csv "${DEMUXERS[@]}")
    --enable-parser=$(join_csv "${PARSERS[@]}")
    --enable-bsf=$(join_csv "${BSFS[@]}")
    --enable-protocol=$(join_csv "${PROTOCOLS[@]}")

    # swscale + swresample are needed by avformat/avcodec for our
    # decode pipeline (color conversion when emitting RGBA frames,
    # sample format coercion in libavformat internals).
    --enable-swscale
    --enable-swresample

    # PIC for static archives that may be linked into final binaries
    # built as PIE (the cartridge SDK link line on macOS ARM64 is PIE).
    --enable-pic

    # Position the toolchain.
    --cc=clang
    --cxx=clang++
    --ld=clang
)

# If the encoder/muxer/filter lists are non-empty in a future
# refactor, append the corresponding --enable-* flags. We leave the
# scaffolding in place but emit nothing today.
if (( ${#ENCODERS[@]} > 0 )); then
    CONFIG_FLAGS+=(--enable-encoder=$(join_csv "${ENCODERS[@]}"))
fi
if (( ${#MUXERS[@]} > 0 )); then
    CONFIG_FLAGS+=(--enable-muxer=$(join_csv "${MUXERS[@]}"))
fi
if (( ${#FILTERS[@]} > 0 )); then
    CONFIG_FLAGS+=(--enable-filter=$(join_csv "${FILTERS[@]}"))
fi

# Per-platform capture input devices (live feeds, 13.2 §Reference Media).
if [[ "$(uname)" == "Linux" ]]; then
    # Preflight: without the ALSA headers, ffmpeg's configure silently
    # drops the alsa indev and the dist ships WITHOUT microphone capture
    # — a broken live-feed backend nobody notices until runtime. Refuse.
    if [[ ! -e /usr/include/alsa/asoundlib.h ]]; then
        echo "ERROR: ALSA development headers not found (/usr/include/alsa/asoundlib.h)." >&2
        echo "Microphone capture (avdevice alsa indev) cannot be built without them." >&2
        echo "Install them first: sudo apt install libasound2-dev  (Debian/Ubuntu)" >&2
        echo "                    sudo dnf install alsa-lib-devel   (Fedora)" >&2
        exit 1
    fi
    # --disable-autodetect turns the ALSA external library OFF regardless
    # of the indev flag (configure then silently drops the alsa indev), so
    # it must be enabled explicitly alongside the indev.
    CONFIG_FLAGS+=(--enable-alsa --enable-indev=alsa --enable-indev=v4l2)
fi

# macOS-specific: VideoToolbox HW decode is available but we keep the
# build host-portable. The fallback software decoders are always in.
if [[ "$(uname)" == "Darwin" ]]; then
    CONFIG_FLAGS+=(--enable-videotoolbox)
    CONFIG_FLAGS+=(--enable-indev=avfoundation)
    # Match deployment target to whatever the consuming Rust target
    # uses (the cartridge SDK currently targets recent macOS). Pin to
    # 12.0 conservatively.
    export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}"
fi

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

if [[ ! -f config.mak || "${RECONFIGURE:-0}" == "1" ]]; then
    echo "==> Configuring"
    "$SOURCE_DIR/configure" "${CONFIG_FLAGS[@]}"
fi

CORES="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
echo "==> Building with -j$CORES"
make -j"$CORES"

# ---------------------------------------------------------------------------
# Stage dist/
# ---------------------------------------------------------------------------

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

echo "==> Installing into $DIST_DIR"
make install

# Drop the .pc files and any docs/examples shipped under prefix; we
# only want lib/ + include/.
rm -rf "$DIST_DIR/share" "$DIST_DIR/lib/pkgconfig"

# ---------------------------------------------------------------------------
# Emit link_flags.txt and version stamp
# ---------------------------------------------------------------------------

LINK_FLAGS="-Ldist/lib"
LINK_FLAGS+=" -lavformat -lavcodec -lswscale -lswresample -lavutil"
# C runtime
LINK_FLAGS+=" -lm -lpthread"
# zlib is pulled in by avformat/avcodec for various container parsers.
LINK_FLAGS+=" -lz"
if [[ "$(uname)" == "Darwin" ]]; then
    # Apple frameworks ffmpeg's mac codepaths reference at link time.
    # CoreFoundation/CoreVideo/CoreMedia/VideoToolbox are required when
    # --enable-videotoolbox is on. AudioToolbox and Security are pulled
    # in by some avformat hooks; CoreServices for content type sniffing.
    LINK_FLAGS+=" -framework CoreFoundation"
    LINK_FLAGS+=" -framework CoreVideo"
    LINK_FLAGS+=" -framework CoreMedia"
    LINK_FLAGS+=" -framework VideoToolbox"
    LINK_FLAGS+=" -framework AudioToolbox"
    LINK_FLAGS+=" -framework Security"
    LINK_FLAGS+=" -framework CoreServices"
fi

# Post-build verification: the capture backends this dist EXISTS to
# provide must actually be inside the archive — configure variants have
# silently dropped them before (missing headers, --disable-autodetect).
# A dist without them ships broken live-feed capture; refuse.
if [[ "$(uname)" == "Linux" ]]; then
    if ! ar t "$DIST_DIR/lib/libavdevice.a" | grep -q "^alsa"; then
        echo "ERROR: built libavdevice.a contains no alsa members — the alsa indev was dropped." >&2
        echo "Check ffmpeg's configure output for why alsa was not enabled." >&2
        exit 1
    fi
    if ! ar t "$DIST_DIR/lib/libavdevice.a" | grep -q "^v4l2"; then
        echo "ERROR: built libavdevice.a contains no v4l2 members — webcam capture was dropped." >&2
        exit 1
    fi
fi
if [[ "$(uname)" == "Darwin" ]]; then
    if ! ar t "$DIST_DIR/lib/libavdevice.a" | grep -qi "avfoundation"; then
        echo "ERROR: built libavdevice.a contains no avfoundation members — capture was dropped." >&2
        exit 1
    fi
fi

echo "$LINK_FLAGS" > "$DIST_DIR/link_flags.txt"
cp "$ROOT/ffmpeg-version.txt" "$DIST_DIR/ffmpeg-version.txt"

echo "==> Done. dist/ contents:"
( cd "$DIST_DIR" && find lib include -maxdepth 2 -type f | sort )
echo
echo "    Total static archive size: $(du -ch "$DIST_DIR/lib"/*.a | tail -n1 | awk '{print $1}')"
