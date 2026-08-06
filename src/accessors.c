/*
 * accessors.c — tiny C shim that reads fields off ffmpeg's structs
 * without forcing the Rust side to mirror the struct layouts.
 *
 * Mirrors the role of the C header in pdfium-render-bundled: the
 * offsets of fields inside an AVFormatContext / AVStream / etc. are
 * an implementation detail of whatever ffmpeg version we link
 * against. By implementing accessors here in C, we get the compiler
 * to compute those offsets at build time using the headers from the
 * exact ffmpeg version we just built. The Rust side talks only to
 * these stable accessors and never lays out an ffmpeg struct itself.
 *
 * This file is compiled by build.rs against ffmpeg's headers in
 * `dist/include/`.
 */

#include <libavformat/avformat.h>
#include <libavformat/avio.h>
#include <libavcodec/avcodec.h>
#include <libavutil/error.h>
#include <libavutil/frame.h>
#include <libavutil/rational.h>
#include <errno.h>

/* AVERROR codes that derive from system errno values are platform-
 * specific (Linux EAGAIN=11, macOS EAGAIN=35). Expose them as
 * accessors so the Rust side does not have to hardcode platform
 * numerics — the embedding C compiler decides the right value at
 * build time using the actual <errno.h> in scope. The tagged-string
 * codes (EOF, INVALIDDATA, etc.) are stable across platforms and
 * stay as Rust-side constants. */

int ffmpeg_embed_averror_eagain(void) {
    return AVERROR(EAGAIN);
}

int ffmpeg_embed_averror_einval(void) {
    return AVERROR(EINVAL);
}

int ffmpeg_embed_averror_enomem(void) {
    return AVERROR(ENOMEM);
}

/* Returned by swr_convert_frame() (and swr's internals more generally)
 * when the input frame's format/rate/layout differs from what the
 * resampler was configured for. Caller responds by re-configuring
 * the SwrContext from the new input frame and retrying. The
 * numeric value is FFERRTAG('I','C','H','I') / similar — exposing
 * via accessor sidesteps any version-to-version churn in libavutil's
 * tag definition. */
int ffmpeg_embed_averror_input_changed(void) {
    return AVERROR_INPUT_CHANGED;
}

/* AVFormatContext */

unsigned int ffmpeg_embed_format_nb_streams(const AVFormatContext *ctx) {
    return ctx ? ctx->nb_streams : 0;
}

AVStream *ffmpeg_embed_format_stream(const AVFormatContext *ctx, unsigned int index) {
    if (!ctx || index >= ctx->nb_streams) {
        return NULL;
    }
    return ctx->streams[index];
}

/* Attach a custom AVIOContext to a format context. Used when the
 * caller is feeding bytes from memory (or any non-file source)
 * rather than letting libavformat open a path itself. ffmpeg's
 * public API is to assign `ctx->pb = avio_ctx`; we shim it here so
 * Rust callers don't have to lay out AVFormatContext. */
void ffmpeg_embed_format_set_pb(AVFormatContext *ctx, AVIOContext *pb) {
    if (ctx) {
        ctx->pb = pb;
    }
}

/* AVIOContext: return the buffer pointer ffmpeg owns inside the
 * context. avio_context_free does NOT free this buffer; callers
 * must free it themselves with av_free. Exposed via this accessor
 * so the Rust drop glue can fetch the pointer without knowing the
 * AVIOContext layout. */
unsigned char *ffmpeg_embed_avio_buffer(AVIOContext *ctx) {
    return ctx ? ctx->buffer : NULL;
}

/* AVStream */

const AVCodecParameters *ffmpeg_embed_stream_codecpar(const AVStream *s) {
    return s ? s->codecpar : NULL;
}

int ffmpeg_embed_stream_index(const AVStream *s) {
    return s ? s->index : -1;
}

AVRational ffmpeg_embed_stream_time_base(const AVStream *s) {
    return s ? s->time_base : (AVRational){0, 1};
}

/* Configure an (unref'd) output frame for swr_convert_frame: s16
 * interleaved at the given rate/channel count. The capture providers'
 * single conversion target (13.2 live feeds deliver s16le PCM items). */
void ffmpeg_embed_frame_set_audio_out(AVFrame *f, int sample_rate, int channels) {
    if (!f) return;
    f->format = AV_SAMPLE_FMT_S16;
    f->sample_rate = sample_rate;
    av_channel_layout_default(&f->ch_layout, channels);
}

AVRational ffmpeg_embed_stream_avg_frame_rate(const AVStream *s) {
    return s ? s->avg_frame_rate : (AVRational){0, 1};
}

int64_t ffmpeg_embed_stream_duration(const AVStream *s) {
    return s ? s->duration : 0;
}

int64_t ffmpeg_embed_stream_nb_frames(const AVStream *s) {
    return s ? s->nb_frames : 0;
}

/* AVCodecParameters */

int ffmpeg_embed_codecpar_codec_id(const AVCodecParameters *p) {
    return p ? (int)p->codec_id : 0;
}

int ffmpeg_embed_codecpar_codec_type(const AVCodecParameters *p) {
    return p ? (int)p->codec_type : -1;
}

int ffmpeg_embed_codecpar_width(const AVCodecParameters *p) {
    return p ? p->width : 0;
}

int ffmpeg_embed_codecpar_height(const AVCodecParameters *p) {
    return p ? p->height : 0;
}

int ffmpeg_embed_codecpar_pix_fmt(const AVCodecParameters *p) {
    return p ? p->format : -1;
}

/* AVCodecContext */

void ffmpeg_embed_codecctx_set_pkt_timebase(AVCodecContext *ctx, AVRational tb) {
    if (ctx) {
        ctx->pkt_timebase = tb;
    }
}

/* AVPacket */

int ffmpeg_embed_packet_stream_index(const AVPacket *pkt) {
    return pkt ? pkt->stream_index : -1;
}

int64_t ffmpeg_embed_packet_pts(const AVPacket *pkt) {
    return pkt ? pkt->pts : AV_NOPTS_VALUE;
}

int64_t ffmpeg_embed_packet_dts(const AVPacket *pkt) {
    return pkt ? pkt->dts : AV_NOPTS_VALUE;
}

/* AVFrame */

int ffmpeg_embed_frame_width(const AVFrame *f) {
    return f ? f->width : 0;
}

int ffmpeg_embed_frame_height(const AVFrame *f) {
    return f ? f->height : 0;
}

int ffmpeg_embed_frame_pix_fmt(const AVFrame *f) {
    return f ? f->format : -1;
}

int64_t ffmpeg_embed_frame_pts(const AVFrame *f) {
    return f ? f->pts : AV_NOPTS_VALUE;
}

uint8_t *ffmpeg_embed_frame_data(const AVFrame *f, int plane) {
    if (!f || plane < 0 || plane >= AV_NUM_DATA_POINTERS) {
        return NULL;
    }
    return f->data[plane];
}

int ffmpeg_embed_frame_linesize(const AVFrame *f, int plane) {
    if (!f || plane < 0 || plane >= AV_NUM_DATA_POINTERS) {
        return 0;
    }
    return f->linesize[plane];
}

/* AVCodecParameters (read more fields needed for transcoding/remuxing). */

int ffmpeg_embed_codecpar_sample_rate(const AVCodecParameters *p) {
    return p ? p->sample_rate : 0;
}

int ffmpeg_embed_codecpar_channels(const AVCodecParameters *p) {
    return p ? p->ch_layout.nb_channels : 0;
}

uint64_t ffmpeg_embed_codecpar_channel_layout(const AVCodecParameters *p) {
    /* Older ffmpeg used `channel_layout` (u64 mask). Newer ffmpeg
     * (5.1+) replaced it with `ch_layout` (an AVChannelLayout
     * struct). Expose the legacy `u_mask` so the Rust side can keep
     * dealing with a single u64. For non-default layouts the
     * channel-count accessor above is the authoritative count. */
    return p ? p->ch_layout.u.mask : 0;
}

int ffmpeg_embed_codecpar_format(const AVCodecParameters *p) {
    return p ? p->format : -1;
}

int ffmpeg_embed_codecpar_frame_size(const AVCodecParameters *p) {
    return p ? p->frame_size : 0;
}

int ffmpeg_embed_codecpar_bit_rate(const AVCodecParameters *p) {
    return p ? (int)p->bit_rate : 0;
}

void ffmpeg_embed_codecpar_set_codec_id(AVCodecParameters *p, int codec_id) {
    if (p) p->codec_id = (enum AVCodecID)codec_id;
}

void ffmpeg_embed_codecpar_set_codec_type(AVCodecParameters *p, int codec_type) {
    if (p) p->codec_type = (enum AVMediaType)codec_type;
}

/* AVCodecContext (output side: set fields the encoder needs). */

void ffmpeg_embed_codecctx_set_sample_rate(AVCodecContext *ctx, int rate) {
    if (ctx) ctx->sample_rate = rate;
}

int ffmpeg_embed_codecctx_sample_rate(const AVCodecContext *ctx) {
    return ctx ? ctx->sample_rate : 0;
}

int ffmpeg_embed_codecctx_frame_size(const AVCodecContext *ctx) {
    return ctx ? ctx->frame_size : 0;
}

void ffmpeg_embed_codecctx_set_sample_fmt(AVCodecContext *ctx, int sample_fmt) {
    if (ctx) ctx->sample_fmt = (enum AVSampleFormat)sample_fmt;
}

int ffmpeg_embed_codecctx_sample_fmt(const AVCodecContext *ctx) {
    return ctx ? (int)ctx->sample_fmt : -1;
}

void ffmpeg_embed_codecctx_set_bit_rate(AVCodecContext *ctx, int64_t bit_rate) {
    if (ctx) ctx->bit_rate = bit_rate;
}

/* FLAC and other lossless codecs require `bits_per_raw_sample` to be set
 * before avcodec_open2; without it the encoder rejects the open with
 * EINVAL. Caller passes 16 / 24 / 32 to match the chosen sample format. */
int ffmpeg_embed_codecctx_bits_per_raw_sample(const AVCodecContext *ctx) {
    return ctx ? ctx->bits_per_raw_sample : 0;
}

void ffmpeg_embed_codecctx_set_bits_per_raw_sample(AVCodecContext *ctx, int bits) {
    if (ctx) ctx->bits_per_raw_sample = bits;
}

#include <libswresample/swresample.h>
#include <libavutil/opt.h>
#include <libavutil/channel_layout.h>

/* If the frame's ch_layout is `AV_CHANNEL_ORDER_UNSPEC`, replace it
 * with the canonical native-order layout for the same channel count.
 * Many decoders emit frames with UNSPEC, but `swr_init` internally
 * promotes UNSPEC to NATIVE — leaving the frame's stored layout
 * `UNSPEC` while swr's stored layout is `NATIVE` makes
 * `av_channel_layout_compare` return non-zero and every subsequent
 * `swr_convert_frame` call returns `AVERROR_INPUT_CHANGED`.
 * Normalising the frame in place (caller-owned, mutated under
 * `unsafe`) keeps swr and the decoder agreeing on byte-identical
 * layouts. Returns 0 / negative AVERROR. */
int ffmpeg_embed_frame_normalize_ch_layout(AVFrame *f) {
    if (!f) return AVERROR(EINVAL);
    if (f->ch_layout.order != AV_CHANNEL_ORDER_UNSPEC) return 0;
    int channels = f->ch_layout.nb_channels;
    av_channel_layout_uninit(&f->ch_layout);
    av_channel_layout_default(&f->ch_layout, channels);
    return 0;
}

/* Configure a SwrContext from a pair of AVFrames (one for input
 * shape, one for output shape) and initialise it.
 *
 * Why this exists rather than calling `swr_config_frame` from Rust:
 * `swr_config_frame()` configures the context, but the very next
 * `swr_convert_frame()` call runs through `config_changed()` (see
 * libswresample/swresample_frame.c) which compares the frame's
 * stored ch_layout to swr's stored ch_layout via
 * `av_channel_layout_compare`. That comparison treats
 * `AV_CHANNEL_ORDER_UNSPEC` and `AV_CHANNEL_ORDER_NATIVE` as
 * non-equal even when channel counts match. Many decoders emit
 * frames with `UNSPEC` order; if anything we configured swr with
 * (e.g. via `av_channel_layout_default`, which returns NATIVE)
 * disagrees on `order`, the very first convert call returns
 * AVERROR_INPUT_CHANGED and the whole pipeline is dead in the
 * water.
 *
 * The fix is to copy the input frame's ch_layout verbatim into
 * swr's `in_chlayout`. That way the order/mask values swr stores
 * match what the decoder produces, and `config_changed()` returns
 * 0 on every well-formed subsequent frame.
 *
 * For the output side we use the caller-provided AVFrame's
 * ch_layout (the encoder-shaped frame) verbatim too — same logic.
 *
 * Returns 0 on success or a negative AVERROR. */
/* `dither` selects swresample's dither_method for depth-REDUCING
 * conversions (float/32-bit int → 16/24-bit int): 0 = none,
 * nonzero = triangular (SWR_DITHER_TRIANGULAR). Depth-preserving
 * conversions should pass 0 — dithering same-or-widening
 * conversions only adds noise. */
int ffmpeg_embed_swr_setup(
    SwrContext *swr,
    const AVFrame *in_frame,
    const AVFrame *out_frame,
    int dither
) {
    int ret;
    AVChannelLayout in_layout_copy = {0};
    AVChannelLayout out_layout_copy = {0};

    if (!in_frame || !out_frame) {
        return AVERROR(EINVAL);
    }

    if (dither) {
        ret = av_opt_set_int(swr, "dither_method", SWR_DITHER_TRIANGULAR, 0);
        if (ret < 0) goto done;
    }

    ret = av_channel_layout_copy(&in_layout_copy, &in_frame->ch_layout);
    if (ret < 0) goto done;
    ret = av_channel_layout_copy(&out_layout_copy, &out_frame->ch_layout);
    if (ret < 0) goto done;

    ret = av_opt_set_chlayout(swr, "in_chlayout", &in_layout_copy, 0);
    if (ret < 0) goto done;
    ret = av_opt_set_int(swr, "in_sample_rate", in_frame->sample_rate, 0);
    if (ret < 0) goto done;
    ret = av_opt_set_sample_fmt(swr, "in_sample_fmt", in_frame->format, 0);
    if (ret < 0) goto done;

    ret = av_opt_set_chlayout(swr, "out_chlayout", &out_layout_copy, 0);
    if (ret < 0) goto done;
    ret = av_opt_set_int(swr, "out_sample_rate", out_frame->sample_rate, 0);
    if (ret < 0) goto done;
    ret = av_opt_set_sample_fmt(swr, "out_sample_fmt", out_frame->format, 0);
    if (ret < 0) goto done;

    ret = swr_init(swr);
done:
    av_channel_layout_uninit(&in_layout_copy);
    av_channel_layout_uninit(&out_layout_copy);
    return ret;
}

void ffmpeg_embed_codecctx_set_time_base(AVCodecContext *ctx, AVRational tb) {
    if (ctx) ctx->time_base = tb;
}

AVRational ffmpeg_embed_codecctx_time_base(const AVCodecContext *ctx) {
    return ctx ? ctx->time_base : (AVRational){0, 1};
}

/* Set the channel layout to a default for the given channel count.
 * Encapsulates the AVChannelLayout API so the Rust side stays
 * agnostic of the ch_layout / channel_layout transition. */
int ffmpeg_embed_codecctx_set_default_ch_layout(AVCodecContext *ctx, int channels) {
    if (!ctx) return -1;
    av_channel_layout_uninit(&ctx->ch_layout);
    av_channel_layout_default(&ctx->ch_layout, channels);
    return 0;
}

int ffmpeg_embed_codecctx_channels(const AVCodecContext *ctx) {
    return ctx ? ctx->ch_layout.nb_channels : 0;
}

/* AVStream (output side). */

void ffmpeg_embed_stream_set_time_base(AVStream *s, AVRational tb) {
    if (s) s->time_base = tb;
}

/* AVPacket helpers used during muxing. av_packet_rescale_ts is a
 * libavcodec public function (already extern'd from Rust) but
 * setting stream_index on a packet has no public C function — it's
 * a direct field assignment, exposed here. */
void ffmpeg_embed_packet_set_stream_index(AVPacket *pkt, int index) {
    if (pkt) pkt->stream_index = index;
}

/* AVFormatContext (output side). */

const struct AVOutputFormat *ffmpeg_embed_format_oformat(const AVFormatContext *ctx) {
    return ctx ? ctx->oformat : NULL;
}

unsigned int ffmpeg_embed_oformat_flags(const struct AVOutputFormat *f) {
    return f ? f->flags : 0;
}

/* AVIOContext (output side): expose the in-memory buffer the
 * encoder wrote, paired with avio_close_dyn_buf semantics. The
 * caller picks the bytes out of `*pbuffer` and must av_free them. */
int ffmpeg_embed_avio_close_dyn_buf(AVIOContext *s, uint8_t **pbuffer) {
    return avio_close_dyn_buf(s, pbuffer);
}

int ffmpeg_embed_avio_open_dyn_buf(AVIOContext **s) {
    return avio_open_dyn_buf(s);
}

/* AVFrame (audio): set the fields needed before allocating sample
 * buffers / sending into an audio encoder. */
void ffmpeg_embed_frame_set_nb_samples(AVFrame *f, int n) {
    if (f) f->nb_samples = n;
}

int ffmpeg_embed_frame_nb_samples(const AVFrame *f) {
    return f ? f->nb_samples : 0;
}

void ffmpeg_embed_frame_set_format(AVFrame *f, int fmt) {
    if (f) f->format = fmt;
}

void ffmpeg_embed_frame_set_sample_rate(AVFrame *f, int rate) {
    if (f) f->sample_rate = rate;
}

int ffmpeg_embed_frame_sample_rate(const AVFrame *f) {
    return f ? f->sample_rate : 0;
}

int ffmpeg_embed_frame_set_default_ch_layout(AVFrame *f, int channels) {
    if (!f) return -1;
    av_channel_layout_uninit(&f->ch_layout);
    av_channel_layout_default(&f->ch_layout, channels);
    return 0;
}

int ffmpeg_embed_frame_channels(const AVFrame *f) {
    return f ? f->ch_layout.nb_channels : 0;
}
