//! Hand-written FFI shim for the embedded ffmpeg static archives.
//!
//! Mirrors the role of pdfium-render-bundled's lib crate, but the
//! API surface is intentionally tiny: only what a video → frames
//! decoder needs. Adding more entry points means adding extern blocks
//! here, on demand.
//!
//! Deliberate non-goals:
//!   - No bindgen. We expose ~30 functions and a handful of opaque
//!     struct types; hand-written FFI is more stable across ffmpeg
//!     point releases than bindgen output, and avoids pulling
//!     bindgen+libclang into every dependent crate's build.
//!   - No safe wrappers. This crate exposes raw `extern "C"` bindings.
//!     Cartridges build their own thin safe wrappers on top, sized to
//!     the operations they actually perform. A fat "safe ffmpeg"
//!     wrapper is exactly the thing that ages badly and accumulates
//!     cruft — we don't want one here.
//!
//! Linking is owned by build.rs: the static archives in `dist/lib/`
//! are linked in dependency order, with macOS frameworks pulled in
//! conditionally.

#![allow(non_camel_case_types)]
#![allow(non_snake_case)]
#![allow(non_upper_case_globals)]

use std::os::raw::{c_char, c_int, c_uint, c_void};

/// Stable hash of the bundled ffmpeg static archives this crate was
/// linked against. Set by `build.rs` from the (path, size, mtime)
/// of every `dist/lib/*.a` file at build time. Two purposes:
///
///  1. Diagnostic — surfaceable from any tool that links this crate,
///     so `dx` can report which archive set is in a given binary.
///  2. Cargo-incremental glue — embedding the fingerprint as a
///     `pub const` forces cargo to rerun rustc whenever the
///     archives change. The recompiled `.rlib` then has different
///     content, which makes cargo invalidate every downstream
///     binary's incremental cache and re-link it. Without this,
///     replacing `dist/lib/*.a` in place would not propagate to
///     already-built cartridge binaries.
pub const FFMPEG_BUNDLE_FINGERPRINT: &str = env!("FFMPEG_BUNDLE_FINGERPRINT");

// ---------------------------------------------------------------------------
// Opaque types
// ---------------------------------------------------------------------------
//
// We treat ffmpeg's structs as opaque pointers wherever possible. The
// only struct we need to peek into is `AVRational` (for time-base
// math) and a few field accesses on AVStream/AVCodecContext/AVFrame
// that we expose via small accessor inlines below.
//
// Treating the structs as opaque keeps ABI stability concerns
// off-table: we never lay out fields here, so an ffmpeg minor version
// bump that re-orders or grows a struct doesn't break us.

#[repr(C)]
pub struct AVFormatContext { _private: [u8; 0] }

#[repr(C)]
pub struct AVCodec { _private: [u8; 0] }

#[repr(C)]
pub struct AVCodecContext { _private: [u8; 0] }

#[repr(C)]
pub struct AVCodecParameters { _private: [u8; 0] }

#[repr(C)]
pub struct AVStream { _private: [u8; 0] }

#[repr(C)]
pub struct AVPacket { _private: [u8; 0] }

#[repr(C)]
pub struct AVFrame { _private: [u8; 0] }

#[repr(C)]
pub struct AVDictionary { _private: [u8; 0] }

#[repr(C)]
pub struct AVOutputFormat { _private: [u8; 0] }

#[repr(C)]
pub struct AVIOContext { _private: [u8; 0] }

#[repr(C)]
pub struct SwrContext { _private: [u8; 0] }

#[repr(C)]
pub struct AVAudioFifo { _private: [u8; 0] }

#[repr(C)]
pub struct SwsContext { _private: [u8; 0] }

#[repr(C)]
#[derive(Copy, Clone, Debug)]
pub struct AVRational {
    pub num: c_int,
    pub den: c_int,
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
//
// These mirror the values in ffmpeg's headers verbatim. They are
// stable across the entire FFmpeg 4.x/5.x/6.x/7.x line — none of them
// have ever been renumbered.

pub const AVMEDIA_TYPE_UNKNOWN: c_int = -1;
pub const AVMEDIA_TYPE_VIDEO: c_int = 0;
pub const AVMEDIA_TYPE_AUDIO: c_int = 1;
pub const AVMEDIA_TYPE_DATA: c_int = 2;
pub const AVMEDIA_TYPE_SUBTITLE: c_int = 3;
pub const AVMEDIA_TYPE_ATTACHMENT: c_int = 4;
pub const AVMEDIA_TYPE_NB: c_int = 5;

// AVPixelFormat values we actually use.
pub const AV_PIX_FMT_NONE: c_int = -1;
pub const AV_PIX_FMT_RGBA: c_int = 26; // RGBA-8888

// SwsContext flags.
pub const SWS_BILINEAR: c_int = 2;

// ffmpeg error sentinels (see libavutil/error.h).
//
// The tagged-string codes (EOF, INVALIDDATA, DECODER_NOT_FOUND) are
// stable across platforms — ffmpeg defines them via FFERRTAG so the
// numeric value is identical on every host. These can stay as Rust
// constants.
//
// errno-derived codes are NOT stable. `AVERROR(EAGAIN)` is -11 on
// Linux but -35 on macOS; the same goes for EINVAL, ENOMEM, and any
// other libc errno. Hardcoding -11 led to a real bug where the
// decode loop's `if rc == AVERROR_EAGAIN { break }` never matched on
// macOS and the loop fell through to `bail!("avcodec_receive_frame
// failed: Resource temporarily unavailable")`. Use the accessor
// functions below — the embedding C compiler picks the platform's
// errno at build time, so we never hardcode it from Rust.
pub const AVERROR_EOF: c_int = -0x20464F45; // FFERRTAG('E','O','F',' ')
pub const AVERROR_INVALIDDATA: c_int = -0x3415_3331; // INDA
pub const AVERROR_DECODER_NOT_FOUND: c_int = -0xbcb_a09a;

extern "C" {
    fn ffmpeg_embed_averror_eagain() -> c_int;
    fn ffmpeg_embed_averror_einval() -> c_int;
    fn ffmpeg_embed_averror_enomem() -> c_int;
    fn ffmpeg_embed_averror_input_changed() -> c_int;
}

/// Platform-correct `AVERROR(EAGAIN)`. Use this in send/receive loops
/// to detect "needs more input" / "decoder full".
#[inline]
pub fn averror_eagain() -> c_int {
    unsafe { ffmpeg_embed_averror_eagain() }
}

/// Platform-correct `AVERROR(EINVAL)`.
#[inline]
pub fn averror_einval() -> c_int {
    unsafe { ffmpeg_embed_averror_einval() }
}

/// Platform-correct `AVERROR(ENOMEM)`.
#[inline]
pub fn averror_enomem() -> c_int {
    unsafe { ffmpeg_embed_averror_enomem() }
}

/// `AVERROR_INPUT_CHANGED`. swresample returns this from
/// `swr_convert_frame` when the input frame's sample-format / rate /
/// channel-layout differs from what the resampler was last
/// configured for. Caller responds by reconfiguring swr from the
/// new input frame and retrying the convert.
#[inline]
pub fn averror_input_changed() -> c_int {
    unsafe { ffmpeg_embed_averror_input_changed() }
}

/// Map an ffmpeg negative return code into a human-readable string
/// using `av_strerror`. Returns owned String. Buffer size 256 is
/// what ffmpeg's own ffplay uses.
pub fn av_strerror_owned(errnum: c_int) -> String {
    let mut buf = [0u8; 256];
    let rc = unsafe {
        av_strerror(errnum, buf.as_mut_ptr() as *mut c_char, buf.len())
    };
    if rc < 0 {
        return format!("ffmpeg error {} (av_strerror failed)", errnum);
    }
    let nul = buf.iter().position(|b| *b == 0).unwrap_or(buf.len());
    String::from_utf8_lossy(&buf[..nul]).into_owned()
}

// ---------------------------------------------------------------------------
// libavformat
// ---------------------------------------------------------------------------

extern "C" {
    /// Allocate an AVFormatContext (empty). Used when feeding bytes
    /// via custom AVIO; for path-based open, pass a null pointer to
    /// avformat_open_input and it allocates internally.
    pub fn avformat_alloc_context() -> *mut AVFormatContext;

    /// Open a media file for reading. On entry `*ps` may be NULL
    /// (avformat allocates) or point to a context allocated by
    /// avformat_alloc_context. Returns 0 on success or a negative
    /// AVERROR.
    pub fn avformat_open_input(
        ps: *mut *mut AVFormatContext,
        url: *const c_char,
        fmt: *const c_void,
        options: *mut *mut AVDictionary,
    ) -> c_int;

    /// Read packets to fill in stream information. Some containers
    /// (notably MOV/MP4) carry the codec params in the moov box up
    /// front, but for raw ES streams ffmpeg has to actually scan
    /// frames to figure out width/height/codec params.
    pub fn avformat_find_stream_info(
        ic: *mut AVFormatContext,
        options: *mut *mut AVDictionary,
    ) -> c_int;

    /// Close the input and free the context. After this call the
    /// `*s` pointer is set to NULL.
    pub fn avformat_close_input(s: *mut *mut AVFormatContext);

    /// Read the next packet from any stream into `pkt`. Returns 0 on
    /// success, AVERROR_EOF on clean end-of-file, or other AVERROR.
    pub fn av_read_frame(s: *mut AVFormatContext, pkt: *mut AVPacket) -> c_int;

    /// Number of streams in the format context. Implemented as a
    /// tiny accessor in our `accessors` C shim because the
    /// AVFormatContext layout is opaque to us at the Rust level.
    pub fn ffmpeg_embed_format_nb_streams(ctx: *const AVFormatContext) -> c_uint;

    /// Returns the i-th AVStream pointer.
    pub fn ffmpeg_embed_format_stream(
        ctx: *const AVFormatContext,
        index: c_uint,
    ) -> *mut AVStream;

    /// Attach a custom AVIO context (`pb`) to the format context.
    /// The C shim does `ctx->pb = pb`. Used when the caller is
    /// driving libavformat from in-memory bytes via avio_alloc_context
    /// rather than letting libavformat open a path itself.
    pub fn ffmpeg_embed_format_set_pb(
        ctx: *mut AVFormatContext,
        pb: *mut AVIOContext,
    );

    /// Read the buffer pointer from an AVIOContext. Used so the Rust
    /// drop glue can free the buffer with `av_free` after calling
    /// `avio_context_free` (which does not free the buffer itself).
    pub fn ffmpeg_embed_avio_buffer(ctx: *mut AVIOContext) -> *mut u8;
}

// ---------------------------------------------------------------------------
// libavcodec
// ---------------------------------------------------------------------------

extern "C" {
    pub fn avcodec_find_decoder(id: c_int) -> *const AVCodec;
    pub fn avcodec_alloc_context3(codec: *const AVCodec) -> *mut AVCodecContext;
    pub fn avcodec_free_context(ctx: *mut *mut AVCodecContext);
    pub fn avcodec_parameters_to_context(
        codec_ctx: *mut AVCodecContext,
        par: *const AVCodecParameters,
    ) -> c_int;
    pub fn avcodec_open2(
        ctx: *mut AVCodecContext,
        codec: *const AVCodec,
        options: *mut *mut AVDictionary,
    ) -> c_int;
    pub fn avcodec_send_packet(ctx: *mut AVCodecContext, pkt: *const AVPacket) -> c_int;
    pub fn avcodec_receive_frame(ctx: *mut AVCodecContext, frame: *mut AVFrame) -> c_int;
    pub fn avcodec_flush_buffers(ctx: *mut AVCodecContext);

    pub fn av_packet_alloc() -> *mut AVPacket;
    pub fn av_packet_free(pkt: *mut *mut AVPacket);
    pub fn av_packet_unref(pkt: *mut AVPacket);
}

// ---------------------------------------------------------------------------
// libavutil
// ---------------------------------------------------------------------------

extern "C" {
    pub fn av_frame_alloc() -> *mut AVFrame;
    pub fn av_frame_free(frame: *mut *mut AVFrame);
    pub fn av_frame_unref(frame: *mut AVFrame);

    /// Convert a quantity expressed in time-base `bq` to time-base `cq`.
    pub fn av_rescale_q(a: i64, bq: AVRational, cq: AVRational) -> i64;

    /// Translate a (negative) AVERROR into a human string. Used by
    /// `av_strerror_owned` above.
    pub fn av_strerror(errnum: c_int, errbuf: *mut c_char, errbuf_size: usize) -> c_int;

    /// Free a pointer allocated by ffmpeg (e.g. the output buffer of
    /// av_image_alloc). Note this is the avutil free, not stdlib.
    pub fn av_freep(ptr: *mut c_void);

    /// Allocate an aligned image buffer for the given pixel format
    /// and dimensions. Used to materialize an RGBA frame for the
    /// `image` crate to encode as PNG/JPEG.
    pub fn av_image_alloc(
        pointers: *mut *mut u8,
        linesizes: *mut c_int,
        w: c_int,
        h: c_int,
        pix_fmt: c_int,
        align: c_int,
    ) -> c_int;

    /// Number of bytes for a packed image row at `pix_fmt × width`.
    /// Used in conjunction with av_image_copy_to_buffer for tightly
    /// packed RGBA copies.
    pub fn av_image_get_buffer_size(pix_fmt: c_int, w: c_int, h: c_int, align: c_int) -> c_int;

    /// Pack a planar/multi-buffer AVFrame into a contiguous buffer.
    /// Source planes/strides come from ffmpeg's accessors below; the
    /// destination is a Rust-owned Vec<u8>.
    pub fn av_image_copy_to_buffer(
        dst: *mut u8,
        dst_size: c_int,
        src_data: *const *const u8,
        src_linesize: *const c_int,
        pix_fmt: c_int,
        width: c_int,
        height: c_int,
        align: c_int,
    ) -> c_int;
}

// ---------------------------------------------------------------------------
// libswscale
// ---------------------------------------------------------------------------

extern "C" {
    pub fn sws_getContext(
        srcW: c_int,
        srcH: c_int,
        srcFormat: c_int,
        dstW: c_int,
        dstH: c_int,
        dstFormat: c_int,
        flags: c_int,
        srcFilter: *mut c_void,
        dstFilter: *mut c_void,
        param: *const f64,
    ) -> *mut SwsContext;

    pub fn sws_scale(
        c: *mut SwsContext,
        srcSlice: *const *const u8,
        srcStride: *const c_int,
        srcSliceY: c_int,
        srcSliceH: c_int,
        dst: *const *mut u8,
        dstStride: *const c_int,
    ) -> c_int;

    pub fn sws_freeContext(c: *mut SwsContext);
}

// ---------------------------------------------------------------------------
// Accessors (implemented in src/accessors.c)
// ---------------------------------------------------------------------------
//
// AVFormatContext, AVStream, AVCodecParameters, AVFrame, AVPacket are
// opaque to Rust. To read fields off them without depending on
// ffmpeg's struct layout we declare a small set of accessor functions
// implemented in a C shim that ships with this crate. The shim
// includes ffmpeg's headers and uses the public field names; whatever
// ffmpeg version we link against decides their offsets.

extern "C" {
    pub fn ffmpeg_embed_stream_codecpar(stream: *const AVStream) -> *const AVCodecParameters;
    pub fn ffmpeg_embed_stream_index(stream: *const AVStream) -> c_int;
    pub fn ffmpeg_embed_stream_time_base(stream: *const AVStream) -> AVRational;
    pub fn ffmpeg_embed_stream_avg_frame_rate(stream: *const AVStream) -> AVRational;
    pub fn ffmpeg_embed_stream_duration(stream: *const AVStream) -> i64;
    pub fn ffmpeg_embed_stream_nb_frames(stream: *const AVStream) -> i64;

    pub fn ffmpeg_embed_codecpar_codec_id(par: *const AVCodecParameters) -> c_int;
    pub fn ffmpeg_embed_codecpar_codec_type(par: *const AVCodecParameters) -> c_int;
    pub fn ffmpeg_embed_codecpar_width(par: *const AVCodecParameters) -> c_int;
    pub fn ffmpeg_embed_codecpar_height(par: *const AVCodecParameters) -> c_int;
    pub fn ffmpeg_embed_codecpar_pix_fmt(par: *const AVCodecParameters) -> c_int;

    pub fn ffmpeg_embed_codecctx_set_pkt_timebase(ctx: *mut AVCodecContext, tb: AVRational);

    pub fn ffmpeg_embed_packet_stream_index(pkt: *const AVPacket) -> c_int;
    pub fn ffmpeg_embed_packet_pts(pkt: *const AVPacket) -> i64;
    pub fn ffmpeg_embed_packet_dts(pkt: *const AVPacket) -> i64;

    pub fn ffmpeg_embed_frame_width(frame: *const AVFrame) -> c_int;
    pub fn ffmpeg_embed_frame_height(frame: *const AVFrame) -> c_int;
    pub fn ffmpeg_embed_frame_pix_fmt(frame: *const AVFrame) -> c_int;
    pub fn ffmpeg_embed_frame_pts(frame: *const AVFrame) -> i64;
    pub fn ffmpeg_embed_frame_data(frame: *const AVFrame, plane: c_int) -> *mut u8;
    pub fn ffmpeg_embed_frame_linesize(frame: *const AVFrame, plane: c_int) -> c_int;

    // Audio-side codec parameters & context accessors (used for
    // remux/transcode pipelines).
    pub fn ffmpeg_embed_codecpar_sample_rate(par: *const AVCodecParameters) -> c_int;
    pub fn ffmpeg_embed_codecpar_channels(par: *const AVCodecParameters) -> c_int;
    pub fn ffmpeg_embed_codecpar_channel_layout(par: *const AVCodecParameters) -> u64;
    pub fn ffmpeg_embed_codecpar_format(par: *const AVCodecParameters) -> c_int;
    pub fn ffmpeg_embed_codecpar_frame_size(par: *const AVCodecParameters) -> c_int;
    pub fn ffmpeg_embed_codecpar_bit_rate(par: *const AVCodecParameters) -> c_int;
    pub fn ffmpeg_embed_codecpar_set_codec_id(par: *mut AVCodecParameters, codec_id: c_int);
    pub fn ffmpeg_embed_codecpar_set_codec_type(par: *mut AVCodecParameters, codec_type: c_int);

    pub fn ffmpeg_embed_codecctx_set_sample_rate(ctx: *mut AVCodecContext, rate: c_int);
    pub fn ffmpeg_embed_codecctx_sample_rate(ctx: *const AVCodecContext) -> c_int;
    pub fn ffmpeg_embed_codecctx_frame_size(ctx: *const AVCodecContext) -> c_int;
    pub fn ffmpeg_embed_codecctx_set_sample_fmt(ctx: *mut AVCodecContext, fmt: c_int);
    pub fn ffmpeg_embed_codecctx_sample_fmt(ctx: *const AVCodecContext) -> c_int;
    pub fn ffmpeg_embed_codecctx_set_bit_rate(ctx: *mut AVCodecContext, bit_rate: i64);
    pub fn ffmpeg_embed_codecctx_set_bits_per_raw_sample(ctx: *mut AVCodecContext, bits: c_int);

    /// Configure a SwrContext from a pair of AVFrames (input shape +
    /// output shape) and initialise it. Sidesteps `swr_config_frame`'s
    /// broken first-call behaviour by copying each frame's
    /// `ch_layout` verbatim — `av_channel_layout_compare` treats
    /// `UNSPEC` and `NATIVE` as non-equal even with matching counts,
    /// so swr's stored layout must be byte-identical to what the
    /// decoder produces. Returns 0 / negative AVERROR.
    pub fn ffmpeg_embed_swr_setup(
        swr: *mut SwrContext,
        in_frame: *const AVFrame,
        out_frame: *const AVFrame,
    ) -> c_int;

    /// Promote an `AV_CHANNEL_ORDER_UNSPEC` frame ch_layout to the
    /// canonical native-order layout for its channel count. No-op
    /// if the frame is already in a specified order. Caller must
    /// guarantee the frame is mutable (no concurrent readers).
    /// Returns 0 / negative AVERROR.
    pub fn ffmpeg_embed_frame_normalize_ch_layout(frame: *mut AVFrame) -> c_int;
    pub fn ffmpeg_embed_codecctx_set_time_base(ctx: *mut AVCodecContext, tb: AVRational);
    pub fn ffmpeg_embed_codecctx_time_base(ctx: *const AVCodecContext) -> AVRational;
    pub fn ffmpeg_embed_codecctx_set_default_ch_layout(ctx: *mut AVCodecContext, channels: c_int)
        -> c_int;
    pub fn ffmpeg_embed_codecctx_channels(ctx: *const AVCodecContext) -> c_int;

    pub fn ffmpeg_embed_stream_set_time_base(stream: *mut AVStream, tb: AVRational);
    pub fn ffmpeg_embed_packet_set_stream_index(pkt: *mut AVPacket, index: c_int);

    pub fn ffmpeg_embed_format_oformat(ctx: *const AVFormatContext) -> *const AVOutputFormat;
    pub fn ffmpeg_embed_oformat_flags(f: *const AVOutputFormat) -> c_uint;

    pub fn ffmpeg_embed_avio_open_dyn_buf(s: *mut *mut AVIOContext) -> c_int;
    pub fn ffmpeg_embed_avio_close_dyn_buf(s: *mut AVIOContext, pbuffer: *mut *mut u8) -> c_int;

    pub fn ffmpeg_embed_frame_set_nb_samples(frame: *mut AVFrame, n: c_int);
    pub fn ffmpeg_embed_frame_nb_samples(frame: *const AVFrame) -> c_int;
    pub fn ffmpeg_embed_frame_set_format(frame: *mut AVFrame, fmt: c_int);
    pub fn ffmpeg_embed_frame_set_sample_rate(frame: *mut AVFrame, rate: c_int);
    pub fn ffmpeg_embed_frame_sample_rate(frame: *const AVFrame) -> c_int;
    pub fn ffmpeg_embed_frame_set_default_ch_layout(frame: *mut AVFrame, channels: c_int) -> c_int;
    pub fn ffmpeg_embed_frame_channels(frame: *const AVFrame) -> c_int;
}

// ---------------------------------------------------------------------------
// libavformat — muxing / output side
// ---------------------------------------------------------------------------

extern "C" {
    /// Allocate an output `AVFormatContext` for the named format.
    /// `format_name` is e.g. "mp4", "ipod" (M4A), "flac". Pass NULL
    /// for `oformat` to let avformat infer from `format_name` /
    /// `filename`.
    pub fn avformat_alloc_output_context2(
        ctx: *mut *mut AVFormatContext,
        oformat: *const AVOutputFormat,
        format_name: *const c_char,
        filename: *const c_char,
    ) -> c_int;

    /// Free an output AVFormatContext. The caller is responsible for
    /// closing/freeing the AVIOContext attached via `pb`.
    pub fn avformat_free_context(ctx: *mut AVFormatContext);

    /// Add a new stream to the output context. `codec` may be NULL —
    /// the caller fills `codecpar` afterwards via
    /// `avcodec_parameters_copy`.
    pub fn avformat_new_stream(
        ctx: *mut AVFormatContext,
        codec: *const AVCodec,
    ) -> *mut AVStream;

    /// Write the file header and metadata. Must be called before any
    /// `av_interleaved_write_frame`.
    pub fn avformat_write_header(
        ctx: *mut AVFormatContext,
        options: *mut *mut AVDictionary,
    ) -> c_int;

    /// Write one packet to the output. Takes ownership of the
    /// packet's contents (libavformat may call `av_packet_unref`).
    pub fn av_interleaved_write_frame(
        ctx: *mut AVFormatContext,
        pkt: *mut AVPacket,
    ) -> c_int;

    /// Write the trailer, finalising the container.
    pub fn av_write_trailer(ctx: *mut AVFormatContext) -> c_int;
}

// ---------------------------------------------------------------------------
// libavcodec — encoder + parameter copy + timestamp rescaling
// ---------------------------------------------------------------------------

extern "C" {
    /// Find an encoder by codec id (e.g. AV_CODEC_ID_FLAC).
    pub fn avcodec_find_encoder(id: c_int) -> *const AVCodec;

    /// Find an encoder by name, e.g. "flac". Useful when the build
    /// has multiple encoders for the same codec id.
    pub fn avcodec_find_encoder_by_name(name: *const c_char) -> *const AVCodec;

    /// Copy codec parameters from one stream to another. Used during
    /// remux to clone the input's codec params onto the output stream
    /// so the muxer knows the codec without re-encoding.
    pub fn avcodec_parameters_copy(
        dst: *mut AVCodecParameters,
        src: *const AVCodecParameters,
    ) -> c_int;

    /// Copy parameters from a codec context onto codec parameters
    /// (used to populate the output stream's `codecpar` from the
    /// encoder context).
    pub fn avcodec_parameters_from_context(
        par: *mut AVCodecParameters,
        ctx: *const AVCodecContext,
    ) -> c_int;

    /// Encode-side counterpart of `avcodec_send_packet` /
    /// `avcodec_receive_frame`.
    pub fn avcodec_send_frame(ctx: *mut AVCodecContext, frame: *const AVFrame) -> c_int;
    pub fn avcodec_receive_packet(ctx: *mut AVCodecContext, pkt: *mut AVPacket) -> c_int;

    /// Rescale a packet's pts/dts from one timebase to another.
    pub fn av_packet_rescale_ts(pkt: *mut AVPacket, src_tb: AVRational, dst_tb: AVRational);

    /// Allocate the data buffers for an audio AVFrame using the
    /// `format`, `nb_samples`, `sample_rate`, and `ch_layout` fields
    /// already set on the frame.
    pub fn av_frame_get_buffer(frame: *mut AVFrame, align: c_int) -> c_int;

    /// Make the frame writable (allocates a fresh buffer if the
    /// existing one is shared). Required before mutating sample
    /// data after a previous use.
    pub fn av_frame_make_writable(frame: *mut AVFrame) -> c_int;
}

// ---------------------------------------------------------------------------
// libswresample — sample-format / rate / layout conversion
// ---------------------------------------------------------------------------

extern "C" {
    pub fn swr_alloc() -> *mut SwrContext;
    pub fn swr_free(ctx: *mut *mut SwrContext);
    pub fn swr_init(ctx: *mut SwrContext) -> c_int;
    pub fn swr_close(ctx: *mut SwrContext);
    pub fn swr_is_initialized(ctx: *mut SwrContext) -> c_int;

    /// Read configuration from input/output AVFrames (preferred over
    /// the deprecated `swr_alloc_set_opts*` family for ffmpeg ≥ 5.1).
    pub fn swr_config_frame(
        ctx: *mut SwrContext,
        out: *const AVFrame,
        in_: *const AVFrame,
    ) -> c_int;

    /// Convert one input frame's worth of samples into `out`. Either
    /// of `in_` / `out` may be NULL to flush.
    pub fn swr_convert_frame(
        ctx: *mut SwrContext,
        out: *mut AVFrame,
        in_: *const AVFrame,
    ) -> c_int;

    /// Returns the number of samples buffered inside swr awaiting
    /// output. Used to decide when to flush after the input EOF.
    pub fn swr_get_delay(ctx: *mut SwrContext, base: i64) -> i64;
}

// ---------------------------------------------------------------------------
// libavutil — AVAudioFifo
// ---------------------------------------------------------------------------
//
// FIFO between swresample's variable-sized output and a fixed-frame-
// size encoder (FLAC). Without this, the encoder's first undersized
// frame trips its `last_audio_frame` flag and every subsequent send
// returns EINVAL ("frame_size was not respected for a non-last frame").

extern "C" {
    pub fn av_audio_fifo_alloc(
        sample_fmt: c_int,
        channels: c_int,
        nb_samples: c_int,
    ) -> *mut AVAudioFifo;
    pub fn av_audio_fifo_free(af: *mut AVAudioFifo);
    pub fn av_audio_fifo_realloc(af: *mut AVAudioFifo, nb_samples: c_int) -> c_int;
    pub fn av_audio_fifo_write(
        af: *mut AVAudioFifo,
        data: *const *mut c_void,
        nb_samples: c_int,
    ) -> c_int;
    pub fn av_audio_fifo_read(
        af: *mut AVAudioFifo,
        data: *const *mut c_void,
        nb_samples: c_int,
    ) -> c_int;
    pub fn av_audio_fifo_size(af: *const AVAudioFifo) -> c_int;
}

// ---------------------------------------------------------------------------
// Tests — pure compile-time API surface check.
// ---------------------------------------------------------------------------
//
// We do not link-test here because the tests run as a separate
// binary that would need the full ffmpeg link line. The downstream
// videocartridge integration tests are where actual decoding gets
// exercised end-to-end against a real .mp4 fixture.

#[cfg(test)]
mod tests {
    use super::*;

    /// AVRational must be POD-compatible with ffmpeg's struct (two
    /// `int` fields, no padding) so we can pass it by value across
    /// the FFI boundary. If a future Rust ABI change ever broke this
    /// invariant, the call sites would silently corrupt frame-rate
    /// math; this test pins it down.
    #[test]
    fn test999_avrational_is_two_ints_no_padding() {
        assert_eq!(std::mem::size_of::<AVRational>(), 2 * std::mem::size_of::<c_int>());
        assert_eq!(std::mem::align_of::<AVRational>(), std::mem::align_of::<c_int>());
    }
}
