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
