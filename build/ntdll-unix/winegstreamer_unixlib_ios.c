/* iOS unix side for dlls/winegstreamer: the WMA decoder, on libavcodec.
 *                                                        (MADEIRA, 2026-09-19)
 *
 * WHY THIS EXISTS
 * ---------------
 * A 2008-era title that plays its music and cutscene dialogue through
 * XAudio2 2.2 gets loud static instead.  The chain, from the device log:
 *
 *   err:module:load_dll [dll-missing] L"C:\windows\system32\winegstreamer.dll"
 *                        status=c0000135
 *   err:ole:com_get_class_object no class object {5b4d4e54-...} (wg_wma_decoder)
 *   fixme:ole:CoCreateInstanceEx no instance created for interface
 *       {bf94c121-...} (IMFTransform) of class {2eeb4adf-...}
 *       (CLSID_CWMADecMediaObject), hr 0x80070005
 *
 * FAudio decodes an xWMA/WMA voice by asking COM for the Windows WMA decoder
 * MFT (libs/faudio/src/FAudio_platform_win32_wmadec.c: CoCreateInstance of
 * CLSID_CWMADecMediaObject for IMFTransform).  In Wine that CLSID lives in
 * wmadmod.dll, which forwards to CLSID_wg_wma_decoder {5b4d4e54-...} in
 * winegstreamer.dll, whose decoder is a GStreamer pipeline in
 * winegstreamer.so.  There is no GStreamer on iOS, so the whole chain was
 * absent -- and FAudio, given no decoder, submits the COMPRESSED bytes to the
 * mixer as if they were PCM.  That is exactly the "wrong audio" plus the
 * 8x-full-scale peaks our audio census reported, while a PCM menu sound (which
 * needs no decoder at all) stayed clean.
 *
 * The prefix registry already registers all of it (the shipped
 * app/Madeira/prefix-template.tar.gz was snapshotted from a host Wine that ran
 * wine.inf's RegisterDllsSection), so nothing has to be registered here: what
 * was missing is the PE winegstreamer.dll (now built by the farm scripts) and
 * this, its unix side.
 *
 * SHAPE
 * -----
 * Same shape as nsi_unixlib_ios.c: the unix call table of a Wine DLL,
 * hand-written for this port, bound BY NAME in virtual_ios.c's
 * load_builtin_unixlib().  The table's INDEX LAYOUT is dlls/winegstreamer/
 * unixlib.h's `enum unix_funcs`, entry for entry, including the entries this
 * port does not implement -- an index that drifts from the header silently
 * dispatches one call to another function's argument block.
 *
 * What is implemented is the wg_transform subset that wma_decoder.c uses:
 * create / destroy / push_data / read_data / get_output_type /
 * set_output_type / drain / flush / get_status (+ notify_qos as a no-op, and
 * wg_init_gstreamer as a benign success so main.c's init_gstreamer_proc lets
 * the DLL load).  Everything else -- the wg_parser side (quartz splitter,
 * media source, wm_reader) and the wg_muxer side -- returns
 * STATUS_NOT_IMPLEMENTED.  Those callers already handle a decoder that is not
 * available; what they must never get is a success with an untouched output
 * field (WOW64_DESIGN.md §7.4 rule 4: no fake success).
 *
 * wg_transform_create also REFUSES anything that is not a WMA family stream.
 * winegstreamer's other transforms (aac, h264, wmv, the resampler, the colour
 * converter) are real GStreamer pipelines with no libavcodec replacement here,
 * and a transform that accepts an H.264 stream and then emits nothing is worse
 * for the caller than one that never opened.
 *
 * DECODING
 * --------
 * libavcodec, from .xtool/build-ffmpeg.sh (FFmpeg 7.1.1, LGPL configuration:
 * --disable-gpl --disable-nonfree, wmav1/wmav2/wmapro/wmalossless/xma1/xma2
 * only).  The input media type is a WAVEFORMATEX -- wg_media_type_from_mf()
 * produces it with MFCreateWaveFormatExFromMFMediaType -- so the codec id,
 * sample rate, channel count/mask, nBlockAlign and the cbSize codec-private
 * bytes are all right there, and no container parser is needed.
 *
 * PACKETISATION: every WMA decoder in libavcodec wants ONE packet of exactly
 * avctx->block_align bytes.  A pushed sample is one or more such packets
 * (FAudio submits whole xWMA blocks), so the bytes are accumulated and split
 * here; a trailing partial packet waits for the next push and is only decoded
 * at drain time.
 *
 * FORMAT CONVERSION: libswresample, for sample format and channel layout ONLY.
 * The output type's sample rate must equal the input's -- a resampler is a
 * different transform (CLSID_wg_resampler), the WMA MFT never advertises a
 * rate change, and silently resampling here would hide a negotiation bug as a
 * pitch bug.
 *
 * -------------------------------------------------------------------------
 * xWMA AND ITS LYING BIT RATE   (device log u87, 2026-09-19)
 * -------------------------------------------------------------------------
 * The first device run decoded one stream and failed EVERY packet of another:
 *
 *   [wma] decoder created fmt=wmav2 tag=0x161 44100Hz 1ch block=139 extradata=10 ...
 *   [wma] decoder created fmt=wmav2 tag=0x161 22050Hz 2ch block=1487 extradata=16 ...
 *   [wma] avcodec_send_packet failed (-1), dropping 1487 bytes   x4762
 *
 * The two streams differ in where their codec-private data comes from, and
 * that is the whole story.
 *
 * `extradata=10` is a REAL WMA v2 codec-private blob, the one an ASF header
 * carries: {DWORD samples_per_block; WORD encode_options; DWORD
 * super_block_align}.  libavcodec reads flags2 = AV_RL16(extradata + 4) out of
 * it (libavcodec/wmadec.c wma_decode_init), which is `encode_options`, and
 * that stream decodes.
 *
 * `extradata=16` is NOT codec-private data at all.  FAudio has none to give --
 * an xWMA RIFF's `fmt ` chunk is a plain WAVEFORMATEX with no tail -- so
 * FAudio_WMADEC_init INVENTS one:
 *
 *   static const uint8_t fake_codec_data[16] = {0,0,0,0,31,0,0,0,0,0,0,0,0,0,0,0};
 *
 * That is the right thing to do and the 31 is not arbitrary: FFmpeg's own xWMA
 * demuxer writes the identical shape, six bytes with [4] = 31, over the
 * comment "setup extradata with our experimentally obtained value"
 * (libavformat/xwma.c).  flags2 = 31 means exp-VLC + bit reservoir + variable
 * block length, which is what the Microsoft xWMA encoder produces -- and it is
 * why block_align is 1487 rather than a couple of hundred bytes: with a bit
 * reservoir a packet is a SUPERFRAME holding several 1024-sample frames.
 *
 * So the flags are right.  What is wrong is the bit rate, and xwma.c says so
 * in as many words, right above the fixup this file now mirrors:
 *
 *   "XWMA encoder only allows a few channel/sample rate/bitrate combinations,
 *    but some create identical files with fake bitrate (1ch 22050hz at
 *    20/48/192kbps are all 20kbps, with the exact same codec data).
 *    Decoder needs correct bitrate to work, so it's normalized here."
 *
 * 22050 Hz stereo -- our failing stream -- is one of the listed rows.  The
 * bit rate is not cosmetic to libavcodec: ff_wma_init (libavcodec/wma.c)
 * derives `bps` from it and then picks the coefficient VLC table
 * (coef_vlc_table, wma.c:335-343), the high band start (high_freq, :149-181),
 * whether noise coding is on (:111) and -- decisively for a bit-reservoir
 * stream -- `byte_offset_bits` (:141), which is how many bits of the
 * SUPERFRAME HEADER hold the offset of the first frame.  Get that wrong and
 * every superframe is misparsed and wma_decode_superframe falls through to its
 * `fail:` label, whose statement is a bare `return -1` (wmadec.c:992).  The
 * log's `(-1)` is that exact line and no other error path in the decoder.
 *
 * WHAT THIS FILE DOES ABOUT IT, AND WHY IT IS A RETRY AND NOT A TABLE LOOKUP.
 * xwma.c's table is applied here (xwma_true_bit_rate below), but only as a
 * CANDIDATE, because a table cannot be trusted on its own from this side: the
 * same entry point also serves honest ASF WMA v2 (that is the 44100 Hz stream
 * that already worked), and "1ch 44100 Hz at 96 kbps" is both a row in that
 * table and a perfectly ordinary real file.  So the decoder is opened with the
 * bit rate the media type reported, and only if a packet FAILS BEFORE ANY
 * OUTPUT HAS BEEN PRODUCED is it reopened once with the normalised rate and
 * the same packet retried.  That is self-validating: it cannot touch a stream
 * that already decodes, it costs one reopen on a stream that does not, and
 * whichever rate wins is logged so the next device log states it as fact
 * rather than leaving it to be inferred.
 *
 * A HOST REPRODUCTION IS ONLY PARTIAL, and the honest note is worth keeping:
 * FFmpeg's own wmav2 ENCODER emits flags2 = 0x0001 -- no bit reservoir, one
 * frame per packet -- so it cannot produce a superframe stream to reproduce
 * the device failure exactly.  Decoding such a stream with flags2 = 31 fails
 * every packet (verified), which confirms the flags path; the bit-rate
 * sensitivity above is read from libavcodec's source and from FFmpeg's own
 * xWMA fixup, not measured here.
 *
 * -------------------------------------------------------------------------
 * A FAILED PACKET MUST STILL PRODUCE TIME
 * -------------------------------------------------------------------------
 * Dropping a packet silently is not the same as producing silence, and the
 * difference is audible.  FAudio's decode loop
 * (FAudio_INTERNAL_DecodeWMAMF) walks the voice with two independent cursors:
 * `samples_pos`, which advances by what the VOICE consumed, and `output_pos`,
 * which advances by what the DECODER produced, and it copies
 * `output_buf + samples_pos`.  Its output buffer is sized from the xWMA dpds
 * table -- the byte count the stream PROMISES -- and allocated with pRealloc,
 * which does not zero.  A decoder that returns fewer bytes than the dpds table
 * promised therefore leaves the tail of that buffer holding whatever was in
 * the heap, and a voice whose cursor has run past `output_pos` reads it.
 *
 * So a packet that fails to decode now emits SILENCE of the length that packet
 * represented (its share of nAvgBytesPerSec, or the frame count of the last
 * packet that did decode) rather than nothing at all.  The decoder's byte
 * budget then still matches the container's, and the failure is inaudible
 * instead of being someone else's uninitialised memory.
 *
 * The per-packet failure line is capped at 8 per decoder -- the first run
 * printed 4,762 identical lines, which is a way to lose a device log -- and a
 * one-line summary is printed when the transform is flushed or destroyed.
 */

#include "config.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>

#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
#include <libavutil/mem.h>
#include <libavutil/opt.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>

#include "ntstatus.h"
#define WIN32_NO_STATUS
#include "windef.h"
#include "winbase.h"
#include "winternl.h"
#include "winerror.h"
#include "mferror.h"

#include "unixlib.h"

/* XMA is not in mmreg.h (it is an Xbox-era tag that never reached the public
 * SDK header), and neither is the WAVEFORMATEXTENSIBLE subformat base. */
#define MADEIRA_WAVE_FORMAT_XMA1  0x0165
#define MADEIRA_WAVE_FORMAT_XMA2  0x0166

/* Per-decoder cap on the per-packet failure line; the rest are counted and
 * reported once. */
#define MADEIRA_WMA_MAX_FAIL_LOGS 8

static const GUID madeira_MFMediaType_Audio =
    { 0x73647561, 0x0000, 0x0010, { 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 } };

/* {0000XXXX-0000-0010-8000-00AA00389B71}: the MEDIASUBTYPE / KSDATAFORMAT
 * family whose Data1 IS the wave format tag.  Used to read the real tag out of
 * a WAVEFORMATEXTENSIBLE, which is what MFCreateWaveFormatExFromMFMediaType
 * produces for >2 channels or >16 bits. */
static BOOL madeira_subtype_tag( const GUID *guid, UINT *tag )
{
    static const GUID base =
        { 0x00000000, 0x0000, 0x0010, { 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 } };

    if (guid->Data2 != base.Data2 || guid->Data3 != base.Data3 ||
        memcmp( guid->Data4, base.Data4, sizeof(base.Data4) ))
        return FALSE;
    *tag = guid->Data1;
    return TRUE;
}

#define MADEIRA_WG_TRANSFORM_MAGIC 0x574d4144  /* 'WMAD' */

struct wma_transform
{
    UINT32 magic;
    pthread_mutex_t lock;

    const AVCodec *codec;
    AVCodecContext *avctx;
    AVFrame *frame;
    AVPacket *packet;
    SwrContext *swr;

    /* everything needed to REOPEN the decoder with a different bit rate */
    enum AVCodecID codec_id;
    BYTE *extradata;
    UINT32 extradata_size;
    UINT32 channel_mask;
    INT64 bit_rate;         /* what the decoder is open with now */
    INT64 bit_rate_alt;     /* xwma.c's normalised value, 0 if none applies */
    BOOL alt_tried;
    BOOL produced_output;

    UINT32 block_align;     /* input packet size, bytes */
    UINT32 rate;
    UINT32 in_channels;
    UINT32 avg_bytes;       /* nAvgBytesPerSec, for the silence estimate */

    /* negotiated PCM output */
    enum AVSampleFormat out_sample_fmt;
    AVChannelLayout out_layout;
    UINT32 out_channels;
    UINT32 out_frame_size;  /* bytes per PCM frame (all channels) */

    /* the exact WAVEFORMATEX(-EXTENSIBLE) the caller set as the output type,
     * kept verbatim so wg_transform_get_output_type hands back what was
     * negotiated rather than a reconstruction of it */
    BYTE *out_format;
    UINT32 out_format_size;

    /* staged compressed input */
    BYTE *in_buf;
    size_t in_cap, in_len;

    /* decoded PCM, consumed by read_data */
    BYTE *pcm_buf;
    size_t pcm_cap, pcm_pos, pcm_len;

    /* 100 ns, of the first frame still in pcm_buf */
    INT64 pts;
    BOOL have_pts;
    BOOL draining;
    BOOL discontinuity;

    /* failure accounting (see the header comment's last section) */
    UINT32 fail_count;
    UINT32 fail_logged;
    UINT64 silence_frames;
    UINT32 last_frames;     /* frames the last SUCCESSFUL packet produced */
};

/* The whole file logs with dprintf(2, ...) rather than ERR/TRACE: this unix
 * side has no Wine debug channel of its own in this build, and the app runs
 * with WINEDEBUG=err+all,err-virtual, so a channel-gated line would be
 * invisible in exactly the device logs these messages exist for. */
#define WMA_LOG( fmt, ... ) dprintf( 2, "[wma] " fmt, ## __VA_ARGS__ )

static struct wma_transform *get_transform( wg_transform_t handle )
{
    struct wma_transform *transform = (struct wma_transform *)(UINT_PTR)handle;

    if (!transform || transform->magic != MADEIRA_WG_TRANSFORM_MAGIC) return NULL;
    return transform;
}

/***********************************************************************
 *           media type helpers
 */
static const WAVEFORMATEX *audio_format( const struct wg_media_type *type )
{
    if (!IsEqualGUID( &type->major, &madeira_MFMediaType_Audio )) return NULL;
    if (!type->u.audio || type->format_size < sizeof(WAVEFORMATEX)) return NULL;
    return type->u.audio;
}

/* The effective format tag: WAVE_FORMAT_EXTENSIBLE hides it in SubFormat. */
static UINT format_tag( const WAVEFORMATEX *wfx, UINT32 size )
{
    UINT tag = wfx->wFormatTag;

    if (tag == WAVE_FORMAT_EXTENSIBLE && size >= sizeof(WAVEFORMATEXTENSIBLE))
    {
        const WAVEFORMATEXTENSIBLE *ext = (const WAVEFORMATEXTENSIBLE *)wfx;
        UINT sub;
        if (madeira_subtype_tag( &ext->SubFormat, &sub )) return sub;
    }
    return tag;
}

static UINT32 channel_mask( const WAVEFORMATEX *wfx, UINT32 size )
{
    if (wfx->wFormatTag == WAVE_FORMAT_EXTENSIBLE && size >= sizeof(WAVEFORMATEXTENSIBLE))
        return ((const WAVEFORMATEXTENSIBLE *)wfx)->dwChannelMask;
    return 0;
}

static enum AVCodecID codec_id_from_tag( UINT tag )
{
    switch (tag)
    {
    case WAVE_FORMAT_MSAUDIO1:          return AV_CODEC_ID_WMAV1;
    case WAVE_FORMAT_WMAUDIO2:          return AV_CODEC_ID_WMAV2;
    case WAVE_FORMAT_WMAUDIO3:          return AV_CODEC_ID_WMAPRO;
    case WAVE_FORMAT_WMAUDIO_LOSSLESS:  return AV_CODEC_ID_WMALOSSLESS;
    case MADEIRA_WAVE_FORMAT_XMA1:      return AV_CODEC_ID_XMA1;
    case MADEIRA_WAVE_FORMAT_XMA2:      return AV_CODEC_ID_XMA2;
    default:                            return AV_CODEC_ID_NONE;
    }
}

/* WinMM's dwChannelMask and FFmpeg's AV_CH_* share the first 18 bit positions
 * (SPEAKER_FRONT_LEFT == AV_CH_FRONT_LEFT == 1, and so on in the same order),
 * which is why this is a widen and not a table. */
static void layout_from_mask( AVChannelLayout *layout, UINT32 mask, UINT32 channels )
{
    if (mask && av_popcount( mask ) == (int)channels &&
        av_channel_layout_from_mask( layout, mask ) >= 0)
        return;
    av_channel_layout_default( layout, channels );
}

/***********************************************************************
 *           xwma_true_bit_rate
 *
 * libavformat/xwma.c, verbatim: the (channels, sample rate, reported bit rate)
 * combinations the Microsoft xWMA encoder is known to LIE about, and what the
 * stream really is.  Returns 0 when the combination is not one of them.
 *
 * Kept as a candidate rather than applied unconditionally -- see the header
 * comment: "1ch 44100 Hz at 96 kbps" is both a row here and an ordinary real
 * ASF file, and this entry point serves both.
 */
static INT64 xwma_true_bit_rate( UINT32 channels, UINT32 rate, INT64 br )
{
    if (channels == 1)
    {
        if (rate == 22050 && (br == 48000 || br == 192000)) return 20000;
        if (rate == 32000 && (br == 48000 || br == 192000)) return 20000;
        if (rate == 44100 && (br == 96000 || br == 192000)) return 48000;
    }
    else if (channels == 2)
    {
        if (rate == 22050 && (br == 48000 || br == 192000)) return 32000;
        if (rate == 32000 && br == 192000) return 48000;
    }
    return 0;
}

/* The flags word libavcodec reads out of WMA v1/v2 codec-private data
 * (wmadec.c wma_decode_init).  Logged on creation because it is the single
 * most useful number for diagnosing a stream that will not decode. */
static UINT wma_flags2( enum AVCodecID id, const BYTE *ed, UINT32 n )
{
    if (id == AV_CODEC_ID_WMAV1 && n >= 4) return ed[2] | (ed[3] << 8);
    if (id == AV_CODEC_ID_WMAV2 && n >= 6) return ed[4] | (ed[5] << 8);
    return 0;
}

/***********************************************************************
 *           buffers
 */
static BOOL buffer_reserve( BYTE **buf, size_t *cap, size_t need )
{
    size_t want;
    BYTE *grown;

    if (*cap >= need) return TRUE;
    want = *cap ? *cap : 4096;
    while (want < need) want *= 2;
    if (!(grown = realloc( *buf, want ))) return FALSE;
    *buf = grown;
    *cap = want;
    return TRUE;
}

static void pcm_compact( struct wma_transform *transform )
{
    if (!transform->pcm_pos) return;
    if (transform->pcm_pos >= transform->pcm_len)
    {
        transform->pcm_pos = transform->pcm_len = 0;
        return;
    }
    memmove( transform->pcm_buf, transform->pcm_buf + transform->pcm_pos,
             transform->pcm_len - transform->pcm_pos );
    transform->pcm_len -= transform->pcm_pos;
    transform->pcm_pos = 0;
}

/***********************************************************************
 *           open_decoder
 *
 * Opens (or REOPENS) the libavcodec decoder at a given bit rate.  Everything
 * it needs is kept on the transform, because the retry path below has to be
 * able to build a second context after the media type is long gone.
 */
static int open_decoder( struct wma_transform *transform, INT64 bit_rate )
{
    AVCodecContext *avctx;
    int err;

    if (transform->avctx) avcodec_free_context( &transform->avctx );
    swr_free( &transform->swr );

    if (!(avctx = avcodec_alloc_context3( transform->codec ))) return AVERROR(ENOMEM);
    avctx->sample_rate = transform->rate;
    avctx->block_align = transform->block_align;
    avctx->bit_rate = bit_rate;
    /* bits_per_coded_sample is deliberately NOT set from the WAVEFORMATEX:
     * wma_decoder.c's SetOutputType writes the OUTPUT sample size back into
     * the input block (`wfx->wBitsPerSample = sample_size;`), so for a float
     * output that field says 32, which is not the coded sample size.  No WMA
     * decoder in libavcodec reads it -- they take everything from extradata,
     * block_align and bit_rate -- so the honest value is none. */
    layout_from_mask( &avctx->ch_layout, transform->channel_mask, transform->in_channels );

    if (transform->extradata_size)
    {
        if (!(avctx->extradata = av_mallocz( transform->extradata_size + AV_INPUT_BUFFER_PADDING_SIZE )))
        {
            avcodec_free_context( &avctx );
            return AVERROR(ENOMEM);
        }
        memcpy( avctx->extradata, transform->extradata, transform->extradata_size );
        avctx->extradata_size = transform->extradata_size;
    }

    if ((err = avcodec_open2( avctx, transform->codec, NULL )) < 0)
    {
        avcodec_free_context( &avctx );
        return err;
    }
    transform->avctx = avctx;
    transform->bit_rate = bit_rate;
    return 0;
}

/***********************************************************************
 *           decode
 *
 * Converts one decoded AVFrame into the negotiated PCM format and appends it
 * to pcm_buf.  swr is built on the FIRST frame, not at open time: the decoder
 * only commits to a sample format and channel layout once it has seen a
 * packet, and using the frame's own values keeps this correct for the
 * multi-stream XMA decoders too.
 */
static NTSTATUS append_frame( struct wma_transform *transform, AVFrame *frame )
{
    int out_samples, converted;
    size_t need;
    uint8_t *dst;

    if (!transform->swr)
    {
        AVChannelLayout in_layout = {0};
        int err;

        if (frame->ch_layout.nb_channels)
            av_channel_layout_copy( &in_layout, &frame->ch_layout );
        else
            av_channel_layout_default( &in_layout, transform->in_channels );

        err = swr_alloc_set_opts2( &transform->swr,
                &transform->out_layout, transform->out_sample_fmt, transform->rate,
                &in_layout, frame->format, frame->sample_rate ? frame->sample_rate : (int)transform->rate,
                0, NULL );
        av_channel_layout_uninit( &in_layout );
        if (err < 0 || !transform->swr)
        {
            WMA_LOG( "swr_alloc_set_opts2 failed (%d)\n", err );
            return STATUS_UNSUCCESSFUL;
        }
        if ((err = swr_init( transform->swr )) < 0)
        {
            WMA_LOG( "swr_init failed (%d)\n", err );
            swr_free( &transform->swr );
            return STATUS_UNSUCCESSFUL;
        }
    }

    /* swr_get_out_samples() accounts for whatever the converter is holding
     * back; the rate is unchanged, so this is nb_samples plus that. */
    out_samples = swr_get_out_samples( transform->swr, frame->nb_samples );
    if (out_samples <= 0) return STATUS_SUCCESS;

    need = transform->pcm_len + (size_t)out_samples * transform->out_frame_size;
    if (!buffer_reserve( &transform->pcm_buf, &transform->pcm_cap, need ))
        return STATUS_NO_MEMORY;

    dst = transform->pcm_buf + transform->pcm_len;
    converted = swr_convert( transform->swr, &dst, out_samples,
                             (const uint8_t **)frame->extended_data, frame->nb_samples );
    if (converted < 0)
    {
        WMA_LOG( "swr_convert failed (%d)\n", converted );
        return STATUS_UNSUCCESSFUL;
    }
    transform->pcm_len += (size_t)converted * transform->out_frame_size;
    if (converted > 0) transform->produced_output = TRUE;
    return STATUS_SUCCESS;
}

/* Silence of the length a packet that failed to decode represented, so the
 * decoder's byte budget keeps matching the container's (see the header
 * comment: FAudio indexes its own output buffer by the VOICE's cursor, and
 * that buffer is not zeroed). */
static NTSTATUS append_silence_for_packet( struct wma_transform *transform, size_t bytes )
{
    UINT32 frames = transform->last_frames;
    size_t need;

    /* Prefer the frame count of the last packet that DID decode -- exact for
     * the constant-geometry WMA superframes xWMA uses.  Failing that, the
     * packet's share of the stream's own byte rate, which is what a CBR
     * container's block_align encodes. */
    if (!frames && transform->avg_bytes)
        frames = (UINT32)((UINT64)bytes * transform->rate / transform->avg_bytes);
    if (!frames) return STATUS_SUCCESS;

    need = transform->pcm_len + (size_t)frames * transform->out_frame_size;
    if (!buffer_reserve( &transform->pcm_buf, &transform->pcm_cap, need ))
        return STATUS_NO_MEMORY;
    memset( transform->pcm_buf + transform->pcm_len, 0,
            (size_t)frames * transform->out_frame_size );
    transform->pcm_len += (size_t)frames * transform->out_frame_size;
    transform->silence_frames += frames;
    return STATUS_SUCCESS;
}

/* Feed one packet and drain whatever frames it produced.  Returns the
 * libavcodec status of the send. */
static int send_one_packet( struct wma_transform *transform, const BYTE *data, size_t size,
                            NTSTATUS *status )
{
    UINT32 frames = 0;
    int err;

    /* The retry path below can leave this NULL if BOTH opens fail; a decoder
     * that is gone must report that, not be called. */
    if (!transform->avctx) return AVERROR(EINVAL);

    /* av_new_packet zero-fills AV_INPUT_BUFFER_PADDING_SIZE past the end,
     * which every bitstream reader in libavcodec reads past into. */
    if ((err = av_new_packet( transform->packet, size )) < 0) return err;
    memcpy( transform->packet->data, data, size );

    err = avcodec_send_packet( transform->avctx, transform->packet );
    av_packet_unref( transform->packet );
    if (err < 0 && err != AVERROR(EAGAIN)) return err;

    for (;;)
    {
        int ret = avcodec_receive_frame( transform->avctx, transform->frame );
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) break;
        if (ret < 0)
        {
            WMA_LOG( "avcodec_receive_frame failed (%d)\n", ret );
            break;
        }
        frames += transform->frame->nb_samples;
        *status = append_frame( transform, transform->frame );
        av_frame_unref( transform->frame );
        if (*status) return 0;
    }
    if (frames) transform->last_frames = frames;
    return 0;
}

/* Decode every whole block_align-sized packet currently staged.  `flush_tail`
 * also submits a trailing partial packet (drain only): mid-stream a short tail
 * is the front of the next push, not a short packet. */
static NTSTATUS decode_staged( struct wma_transform *transform, BOOL flush_tail )
{
    NTSTATUS status = STATUS_SUCCESS;
    size_t offset = 0;

    while (offset < transform->in_len)
    {
        size_t avail = transform->in_len - offset;
        size_t take = transform->block_align;
        const BYTE *data;
        int err;

        if (avail < take)
        {
            if (!flush_tail) break;
            take = avail;
        }
        data = transform->in_buf + offset;

        err = send_one_packet( transform, data, take, &status );
        if (status) return status;

        /* THE xWMA BIT-RATE RETRY (see the header comment).  Only before any
         * output has been produced, and only once: a stream that has already
         * decoded a frame has proved its parameters, and reopening under it
         * would throw away the bit reservoir for no reason. */
        if (err < 0 && !transform->produced_output && !transform->alt_tried &&
            transform->bit_rate_alt && transform->bit_rate_alt != transform->bit_rate)
        {
            INT64 was = transform->bit_rate;

            transform->alt_tried = TRUE;
            if (!open_decoder( transform, transform->bit_rate_alt ))
            {
                WMA_LOG( "no packet decoded at %d bit/s; xWMA reports a fake rate for "
                         "%uHz %uch, retrying at %d bit/s (libavformat/xwma.c)\n",
                         (int)was, transform->rate, transform->in_channels,
                         (int)transform->bit_rate_alt );
                err = send_one_packet( transform, data, take, &status );
                if (status) return status;
                if (err >= 0)
                    WMA_LOG( "bit rate %d bit/s accepted; decoding resumed\n",
                             (int)transform->bit_rate );
            }
            else
            {
                /* Reopening failed outright: put the working context back so
                 * the transform stays usable rather than becoming a NULL
                 * decoder that faults on the next push. */
                open_decoder( transform, was );
            }
        }

        offset += take;

        if (err < 0)
        {
            transform->fail_count++;
            if (transform->fail_logged < MADEIRA_WMA_MAX_FAIL_LOGS)
            {
                transform->fail_logged++;
                WMA_LOG( "avcodec_send_packet failed (%d) on %zu bytes at %d bit/s "
                         "(%uHz %uch block=%u flags2=%#x)%s\n",
                         err, take, (int)transform->bit_rate, transform->rate,
                         transform->in_channels, transform->block_align,
                         wma_flags2( transform->codec_id, transform->extradata,
                                     transform->extradata_size ),
                         transform->fail_logged == MADEIRA_WMA_MAX_FAIL_LOGS
                             ? " -- further failures counted only" : "" );
            }
            /* Emit silence for this packet rather than dropping it: the
             * container promised these bytes and FAudio's output buffer is not
             * zeroed (header comment). */
            if ((status = append_silence_for_packet( transform, take ))) return status;
        }
    }

    if (offset)
    {
        memmove( transform->in_buf, transform->in_buf + offset, transform->in_len - offset );
        transform->in_len -= offset;
    }
    return status;
}

static void report_failures( struct wma_transform *transform )
{
    if (!transform->fail_count) return;
    WMA_LOG( "%u packets failed to decode on transform %p (%llu frames of silence emitted "
             "in their place), %uHz %uch block=%u at %d bit/s\n",
             transform->fail_count, transform, (unsigned long long)transform->silence_frames,
             transform->rate, transform->in_channels, transform->block_align,
             (int)transform->bit_rate );
    transform->fail_count = 0;
    transform->fail_logged = 0;
    transform->silence_frames = 0;
}

/***********************************************************************
 *           wg_transform_create
 */
static NTSTATUS transform_create( struct wg_transform_create_params *params )
{
    const WAVEFORMATEX *in = audio_format( &params->input_type );
    const WAVEFORMATEX *out = audio_format( &params->output_type );
    struct wma_transform *transform;
    enum AVCodecID codec_id;
    UINT in_tag, out_tag;
    UINT32 extra;
    int err;

    params->transform = 0;

    if (!in || !out)
    {
        /* Video, or a malformed block: winegstreamer's other transforms live
         * here too and this port has no replacement for them. */
        return STATUS_NOT_SUPPORTED;
    }

    in_tag = format_tag( in, params->input_type.format_size );
    out_tag = format_tag( out, params->output_type.format_size );
    if ((codec_id = codec_id_from_tag( in_tag )) == AV_CODEC_ID_NONE)
    {
        WMA_LOG( "input format tag %#x is not a WMA family stream; refusing\n", in_tag );
        return STATUS_NOT_SUPPORTED;
    }
    if (out_tag != WAVE_FORMAT_PCM && out_tag != WAVE_FORMAT_IEEE_FLOAT)
    {
        WMA_LOG( "output format tag %#x is not PCM or float; refusing\n", out_tag );
        return STATUS_NOT_SUPPORTED;
    }
    if (out->nSamplesPerSec != in->nSamplesPerSec)
    {
        /* See the header comment: resampling is a different transform. */
        WMA_LOG( "refusing %u Hz -> %u Hz: this decoder does not resample\n",
                 (UINT)in->nSamplesPerSec, (UINT)out->nSamplesPerSec );
        return STATUS_NOT_SUPPORTED;
    }
    if (!in->nChannels || !in->nSamplesPerSec || !in->nBlockAlign || !out->nChannels)
        return STATUS_INVALID_PARAMETER;
    if (out_tag == WAVE_FORMAT_PCM && out->wBitsPerSample != 16)
    {
        WMA_LOG( "refusing %u-bit integer PCM output (only 16-bit and float32 are produced)\n",
                 (UINT)out->wBitsPerSample );
        return STATUS_NOT_SUPPORTED;
    }
    if (out_tag == WAVE_FORMAT_IEEE_FLOAT && out->wBitsPerSample != 32)
        return STATUS_NOT_SUPPORTED;

    if (!(transform = calloc( 1, sizeof(*transform) ))) return STATUS_NO_MEMORY;
    pthread_mutex_init( &transform->lock, NULL );
    transform->magic = MADEIRA_WG_TRANSFORM_MAGIC;
    transform->codec_id = codec_id;
    transform->block_align = in->nBlockAlign;
    transform->rate = in->nSamplesPerSec;
    transform->in_channels = in->nChannels;
    transform->avg_bytes = in->nAvgBytesPerSec;
    transform->channel_mask = channel_mask( in, params->input_type.format_size );
    transform->out_channels = out->nChannels;
    transform->out_sample_fmt = (out_tag == WAVE_FORMAT_IEEE_FLOAT) ? AV_SAMPLE_FMT_FLT
                                                                    : AV_SAMPLE_FMT_S16;
    transform->out_frame_size = out->nChannels * (out->wBitsPerSample / 8);
    layout_from_mask( &transform->out_layout,
                      channel_mask( out, params->output_type.format_size ), out->nChannels );

    transform->out_format_size = params->output_type.format_size;
    if (!(transform->out_format = malloc( transform->out_format_size )))
        goto nomem;
    memcpy( transform->out_format, out, transform->out_format_size );

    /* The codec private data is the cbSize bytes that follow the WAVEFORMATEX
     * -- for WMA that is the decoder's flags/superframe configuration, and the
     * decoder refuses to open without it.  Kept on the transform because the
     * bit-rate retry has to reopen with it. */
    extra = in->cbSize;
    if (extra > params->input_type.format_size - sizeof(WAVEFORMATEX))
        extra = params->input_type.format_size - sizeof(WAVEFORMATEX);
    if (extra)
    {
        if (!(transform->extradata = malloc( extra ))) goto nomem;
        memcpy( transform->extradata, (const BYTE *)in + sizeof(WAVEFORMATEX), extra );
        transform->extradata_size = extra;
    }

    if (!(transform->codec = avcodec_find_decoder( codec_id )))
    {
        WMA_LOG( "libavcodec has no decoder for codec id %d (tag %#x)\n", codec_id, in_tag );
        goto unsupported;
    }
    if (!(transform->frame = av_frame_alloc())) goto nomem;
    if (!(transform->packet = av_packet_alloc())) goto nomem;

    transform->bit_rate_alt = xwma_true_bit_rate( in->nChannels, in->nSamplesPerSec,
                                                  (INT64)in->nAvgBytesPerSec * 8 );

    if ((err = open_decoder( transform, (INT64)in->nAvgBytesPerSec * 8 )) < 0)
    {
        WMA_LOG( "avcodec_open2(%s) failed (%d) at %u bit/s\n", transform->codec->name, err,
                 (UINT)in->nAvgBytesPerSec * 8 );
        goto unsupported;
    }

    params->transform = (wg_transform_t)(UINT_PTR)transform;
    WMA_LOG( "decoder created fmt=%s tag=%#x %uHz %uch block=%u avg=%uB/s bitrate=%d"
             " extradata=%u flags2=%#x -> pcm %s %uHz %uch %ubit (transform %p)%s\n",
             transform->codec->name, in_tag, (UINT)in->nSamplesPerSec, (UINT)in->nChannels,
             (UINT)in->nBlockAlign, (UINT)in->nAvgBytesPerSec, (int)transform->bit_rate,
             extra, wma_flags2( codec_id, transform->extradata, extra ),
             transform->out_sample_fmt == AV_SAMPLE_FMT_FLT ? "float32" : "s16",
             (UINT)out->nSamplesPerSec, (UINT)out->nChannels, (UINT)out->wBitsPerSample,
             transform,
             transform->bit_rate_alt ? " [xWMA fake-rate candidate available]" : "" );
    return STATUS_SUCCESS;

nomem:
    err = STATUS_NO_MEMORY;
    goto fail;
unsupported:
    err = STATUS_NOT_SUPPORTED;
fail:
    if (transform->avctx) avcodec_free_context( &transform->avctx );
    if (transform->frame) av_frame_free( &transform->frame );
    if (transform->packet) av_packet_free( &transform->packet );
    av_channel_layout_uninit( &transform->out_layout );
    free( transform->extradata );
    free( transform->out_format );
    pthread_mutex_destroy( &transform->lock );
    transform->magic = 0;
    free( transform );
    return (NTSTATUS)err;
}

static NTSTATUS transform_destroy( wg_transform_t handle )
{
    struct wma_transform *transform = get_transform( handle );

    if (!transform) return STATUS_INVALID_HANDLE;

    pthread_mutex_lock( &transform->lock );
    report_failures( transform );
    transform->magic = 0;
    if (transform->swr) swr_free( &transform->swr );
    if (transform->avctx) avcodec_free_context( &transform->avctx );
    if (transform->frame) av_frame_free( &transform->frame );
    if (transform->packet) av_packet_free( &transform->packet );
    av_channel_layout_uninit( &transform->out_layout );
    free( transform->extradata );
    free( transform->out_format );
    free( transform->in_buf );
    free( transform->pcm_buf );
    pthread_mutex_unlock( &transform->lock );
    pthread_mutex_destroy( &transform->lock );
    free( transform );
    return STATUS_SUCCESS;
}

/***********************************************************************
 *           push / read
 *
 * `data` is passed separately from `sample` because struct wg_sample's `data`
 * member is a GUEST address for a 32-bit caller (it is a UINT64 field holding
 * a PE-side pointer); the wow64 thunk converts it with ios_wow_host_ptr() and
 * the 64-bit entry just widens it.  Everything else in struct wg_sample has
 * the same layout in both builds -- pts/duration are INT64/UINT64 and i386
 * aligns them to 8 like the host does -- so the OUT fields are written through
 * the caller's own struct.
 */
static NTSTATUS transform_push_data( wg_transform_t handle, struct wg_sample *sample,
                                     const void *data, HRESULT *result )
{
    struct wma_transform *transform = get_transform( handle );
    NTSTATUS status;

    if (!transform || !sample) return STATUS_INVALID_HANDLE;
    /* No fake success (WOW64_DESIGN.md §7.4 rule 4): bytes with nowhere to read
     * them from is a caller bug, and quietly accepting them would look like a
     * decoder that swallows audio. */
    if (sample->size && !data) return STATUS_INVALID_PARAMETER;

    pthread_mutex_lock( &transform->lock );

    /* MFT back-pressure: refuse new input while a decoded buffer is still
     * waiting, so ProcessInput/ProcessOutput alternate the way the caller's
     * loop expects instead of letting pcm_buf grow without bound. */
    if (transform->pcm_len > transform->pcm_pos)
    {
        *result = MF_E_NOTACCEPTING;
        pthread_mutex_unlock( &transform->lock );
        return STATUS_SUCCESS;
    }

    if (sample->size && data)
    {
        if (!buffer_reserve( &transform->in_buf, &transform->in_cap,
                             transform->in_len + sample->size ))
        {
            pthread_mutex_unlock( &transform->lock );
            return STATUS_NO_MEMORY;
        }
        memcpy( transform->in_buf + transform->in_len, data, sample->size );
        transform->in_len += sample->size;
    }

    if (!transform->have_pts && (sample->flags & WG_SAMPLE_FLAG_HAS_PTS))
    {
        transform->pts = sample->pts;
        transform->have_pts = TRUE;
    }
    if (sample->flags & WG_SAMPLE_FLAG_DISCONTINUITY) transform->discontinuity = TRUE;

    transform->draining = FALSE;
    pcm_compact( transform );
    status = decode_staged( transform, FALSE );
    pthread_mutex_unlock( &transform->lock );

    *result = status ? E_FAIL : S_OK;
    return status ? status : STATUS_SUCCESS;
}

static NTSTATUS transform_read_data( wg_transform_t handle, struct wg_sample *sample,
                                     void *data, HRESULT *result )
{
    struct wma_transform *transform = get_transform( handle );
    size_t avail, copy, frames;

    if (!transform || !sample) return STATUS_INVALID_HANDLE;
    /* Consuming PCM into a buffer that does not exist would lose it silently. */
    if (sample->max_size && !data) return STATUS_INVALID_PARAMETER;

    pthread_mutex_lock( &transform->lock );
    avail = transform->pcm_len - transform->pcm_pos;
    if (!avail)
    {
        sample->size = 0;
        pthread_mutex_unlock( &transform->lock );
        *result = MF_E_TRANSFORM_NEED_MORE_INPUT;
        return STATUS_SUCCESS;
    }

    copy = avail < sample->max_size ? avail : sample->max_size;
    /* Never hand back a partial PCM frame: a caller that treats size/frame
     * size as a sample count would silently shear the channel interleave. */
    copy -= copy % transform->out_frame_size;
    if (!copy)
    {
        sample->size = 0;
        pthread_mutex_unlock( &transform->lock );
        *result = MF_E_TRANSFORM_NEED_MORE_INPUT;
        return STATUS_SUCCESS;
    }

    memcpy( data, transform->pcm_buf + transform->pcm_pos, copy );
    sample->size = copy;
    frames = copy / transform->out_frame_size;

    sample->flags &= ~(WG_SAMPLE_FLAG_INCOMPLETE | WG_SAMPLE_FLAG_HAS_PTS |
                       WG_SAMPLE_FLAG_HAS_DURATION | WG_SAMPLE_FLAG_DISCONTINUITY);
    sample->flags |= WG_SAMPLE_FLAG_SYNC_POINT;
    if (transform->have_pts)
    {
        sample->flags |= WG_SAMPLE_FLAG_HAS_PTS;
        sample->pts = transform->pts;
    }
    sample->flags |= WG_SAMPLE_FLAG_HAS_DURATION;
    sample->duration = (UINT64)frames * 10000000 / transform->rate;
    transform->pts += (INT64)sample->duration;
    if (transform->discontinuity)
    {
        sample->flags |= WG_SAMPLE_FLAG_DISCONTINUITY;
        transform->discontinuity = FALSE;
    }

    transform->pcm_pos += copy;
    if (transform->pcm_pos < transform->pcm_len)
        sample->flags |= WG_SAMPLE_FLAG_INCOMPLETE;
    else
        pcm_compact( transform );

    pthread_mutex_unlock( &transform->lock );
    *result = S_OK;
    return STATUS_SUCCESS;
}

/***********************************************************************
 *           output type
 */
static NTSTATUS transform_get_output_type( wg_transform_t handle, struct wg_media_type *type )
{
    struct wma_transform *transform = get_transform( handle );
    UINT32 size;

    if (!transform) return STATUS_INVALID_HANDLE;

    pthread_mutex_lock( &transform->lock );
    size = transform->out_format_size;
    type->major = madeira_MFMediaType_Audio;

    /* Two-phase, as main.c's wg_transform_get_output_type() expects: the first
     * call carries a NULL format and only learns the size. */
    if (!type->u.format || type->format_size < size)
    {
        type->format_size = size;
        pthread_mutex_unlock( &transform->lock );
        return STATUS_BUFFER_TOO_SMALL;
    }
    memcpy( type->u.format, transform->out_format, size );
    type->format_size = size;
    pthread_mutex_unlock( &transform->lock );
    return STATUS_SUCCESS;
}

static NTSTATUS transform_set_output_type( wg_transform_t handle, const struct wg_media_type *type )
{
    struct wma_transform *transform = get_transform( handle );
    const WAVEFORMATEX *out = audio_format( type );
    enum AVSampleFormat sample_fmt;
    AVChannelLayout layout = {0};
    BYTE *copy;
    UINT tag;

    if (!transform) return STATUS_INVALID_HANDLE;
    if (!out) return STATUS_NOT_SUPPORTED;

    tag = format_tag( out, type->format_size );
    if (tag == WAVE_FORMAT_IEEE_FLOAT && out->wBitsPerSample == 32)
        sample_fmt = AV_SAMPLE_FMT_FLT;
    else if (tag == WAVE_FORMAT_PCM && out->wBitsPerSample == 16)
        sample_fmt = AV_SAMPLE_FMT_S16;
    else
        return STATUS_NOT_SUPPORTED;
    if (out->nSamplesPerSec != transform->rate || !out->nChannels) return STATUS_NOT_SUPPORTED;

    if (!(copy = malloc( type->format_size ))) return STATUS_NO_MEMORY;
    memcpy( copy, out, type->format_size );
    layout_from_mask( &layout, channel_mask( out, type->format_size ), out->nChannels );

    pthread_mutex_lock( &transform->lock );
    /* Anything already converted is in the OLD format; the caller is asking
     * for a different one, so it cannot be delivered. */
    swr_free( &transform->swr );
    transform->pcm_pos = transform->pcm_len = 0;
    av_channel_layout_uninit( &transform->out_layout );
    transform->out_layout = layout;
    transform->out_sample_fmt = sample_fmt;
    transform->out_channels = out->nChannels;
    transform->out_frame_size = out->nChannels * (out->wBitsPerSample / 8);
    free( transform->out_format );
    transform->out_format = copy;
    transform->out_format_size = type->format_size;
    pthread_mutex_unlock( &transform->lock );

    WMA_LOG( "output type set to %s %uHz %uch %ubit (transform %p)\n",
             sample_fmt == AV_SAMPLE_FMT_FLT ? "float32" : "s16",
             (UINT)out->nSamplesPerSec, (UINT)out->nChannels, (UINT)out->wBitsPerSample,
             transform );
    return STATUS_SUCCESS;
}

/***********************************************************************
 *           the unix call entries
 */
static NTSTATUS wma_init( void *args )
{
    struct wg_init_gstreamer_params *params = args;

    /* Benign success: main.c's init_gstreamer_proc() fails the whole DLL if
     * this fails, and everything this port implements is below it. */
    (void)params;
    return STATUS_SUCCESS;
}

static NTSTATUS wma_not_implemented( void *args )
{
    (void)args;
    return STATUS_NOT_IMPLEMENTED;
}

static NTSTATUS wma_transform_create( void *args )
{
    return transform_create( args );
}

static NTSTATUS wma_transform_destroy( void *args )
{
    return transform_destroy( *(wg_transform_t *)args );
}

static NTSTATUS wma_transform_get_output_type( void *args )
{
    struct wg_transform_get_output_type_params *params = args;
    return transform_get_output_type( params->transform, &params->media_type );
}

static NTSTATUS wma_transform_set_output_type( void *args )
{
    struct wg_transform_set_output_type_params *params = args;
    return transform_set_output_type( params->transform, &params->media_type );
}

static NTSTATUS wma_transform_push_data( void *args )
{
    struct wg_transform_push_data_params *params = args;
    struct wg_sample *sample = params->sample;

    if (!sample) return STATUS_INVALID_PARAMETER;
    return transform_push_data( params->transform, sample,
                                (const void *)(UINT_PTR)sample->data, &params->result );
}

static NTSTATUS wma_transform_read_data( void *args )
{
    struct wg_transform_read_data_params *params = args;
    struct wg_sample *sample = params->sample;

    if (!sample) return STATUS_INVALID_PARAMETER;
    return transform_read_data( params->transform, sample,
                                (void *)(UINT_PTR)sample->data, &params->result );
}

static NTSTATUS wma_transform_get_status( void *args )
{
    struct wg_transform_get_status_params *params = args;
    struct wma_transform *transform = get_transform( params->transform );

    if (!transform) return STATUS_INVALID_HANDLE;
    pthread_mutex_lock( &transform->lock );
    params->accepts_input = (transform->pcm_len == transform->pcm_pos);
    pthread_mutex_unlock( &transform->lock );
    return STATUS_SUCCESS;
}

static NTSTATUS wma_transform_drain( void *args )
{
    struct wma_transform *transform = get_transform( *(wg_transform_t *)args );
    NTSTATUS status;

    if (!transform) return STATUS_INVALID_HANDLE;
    pthread_mutex_lock( &transform->lock );
    transform->draining = TRUE;
    status = decode_staged( transform, TRUE );
    if (!status && transform->avctx)
    {
        /* Flush the decoder's own lookahead, then the converter's. */
        int err;
        avcodec_send_packet( transform->avctx, NULL );
        for (;;)
        {
            err = avcodec_receive_frame( transform->avctx, transform->frame );
            if (err < 0) break;
            status = append_frame( transform, transform->frame );
            av_frame_unref( transform->frame );
            if (status) break;
        }
        avcodec_flush_buffers( transform->avctx );
    }
    report_failures( transform );
    pthread_mutex_unlock( &transform->lock );
    return status;
}

static NTSTATUS wma_transform_flush( void *args )
{
    struct wma_transform *transform = get_transform( *(wg_transform_t *)args );

    if (!transform) return STATUS_INVALID_HANDLE;
    pthread_mutex_lock( &transform->lock );
    report_failures( transform );
    transform->in_len = 0;
    transform->pcm_pos = transform->pcm_len = 0;
    transform->have_pts = FALSE;
    transform->pts = 0;
    transform->draining = FALSE;
    transform->discontinuity = TRUE;
    if (transform->avctx) avcodec_flush_buffers( transform->avctx );
    swr_free( &transform->swr );
    pthread_mutex_unlock( &transform->lock );
    return STATUS_SUCCESS;
}

static NTSTATUS wma_transform_notify_qos( void *args )
{
    /* Quality-of-service hints only change which frames a GStreamer pipeline
     * bothers to decode; an audio decoder with no frame dropping has nothing
     * to do with them, and the caller ignores the status. */
    (void)args;
    return STATUS_SUCCESS;
}

/* The index layout below is dlls/winegstreamer/unixlib.h `enum unix_funcs`,
 * entry for entry.  Do not reorder; add new entries only where the header
 * adds them. */
const unixlib_entry_t __wine_unix_call_funcs[] =
{
    wma_init,                           /* unix_wg_init_gstreamer */

    wma_not_implemented,                /* unix_wg_parser_create */
    wma_not_implemented,                /* unix_wg_parser_destroy */

    wma_not_implemented,                /* unix_wg_parser_connect */
    wma_not_implemented,                /* unix_wg_parser_disconnect */

    wma_not_implemented,                /* unix_wg_parser_get_next_read_offset */
    wma_not_implemented,                /* unix_wg_parser_push_data */

    wma_not_implemented,                /* unix_wg_parser_get_stream_count */
    wma_not_implemented,                /* unix_wg_parser_get_stream */

    wma_not_implemented,                /* unix_wg_parser_stream_get_current_format */
    wma_not_implemented,                /* unix_wg_parser_stream_get_codec_format */
    wma_not_implemented,                /* unix_wg_parser_stream_enable */
    wma_not_implemented,                /* unix_wg_parser_stream_disable */

    wma_not_implemented,                /* unix_wg_parser_stream_get_buffer */
    wma_not_implemented,                /* unix_wg_parser_stream_copy_buffer */
    wma_not_implemented,                /* unix_wg_parser_stream_release_buffer */
    wma_not_implemented,                /* unix_wg_parser_stream_notify_qos */

    wma_not_implemented,                /* unix_wg_parser_stream_get_duration */
    wma_not_implemented,                /* unix_wg_parser_stream_get_tag */
    wma_not_implemented,                /* unix_wg_parser_stream_seek */

    wma_transform_create,               /* unix_wg_transform_create */
    wma_transform_destroy,              /* unix_wg_transform_destroy */
    wma_transform_get_output_type,      /* unix_wg_transform_get_output_type */
    wma_transform_set_output_type,      /* unix_wg_transform_set_output_type */

    wma_transform_push_data,            /* unix_wg_transform_push_data */
    wma_transform_read_data,            /* unix_wg_transform_read_data */
    wma_transform_get_status,           /* unix_wg_transform_get_status */
    wma_transform_drain,                /* unix_wg_transform_drain */
    wma_transform_flush,                /* unix_wg_transform_flush */
    wma_transform_notify_qos,           /* unix_wg_transform_notify_qos */

    wma_not_implemented,                /* unix_wg_muxer_create */
    wma_not_implemented,                /* unix_wg_muxer_destroy */
    wma_not_implemented,                /* unix_wg_muxer_add_stream */
    wma_not_implemented,                /* unix_wg_muxer_start */
    wma_not_implemented,                /* unix_wg_muxer_push_sample */
    wma_not_implemented,                /* unix_wg_muxer_read_data */
    wma_not_implemented,                /* unix_wg_muxer_finalize */
};

C_ASSERT( ARRAY_SIZE(__wine_unix_call_funcs) == unix_wg_funcs_count );

/***********************************************************************
 *           the wow64 table   (WOW64_DESIGN.md §3 invariant 2, §7.10 item 1)
 *
 * dlls/winegstreamer/unixlib.h has NO `#ifdef _WIN64` 32-bit param structs --
 * upstream's unixlib is only ever entered from a matching-bitness PE because
 * wow64.dll thunks winegstreamer through its own table.  So the 32-bit layouts
 * are written out here, the way nsi_unixlib_ios.c writes struct
 * nsi_enumerate_all_ex32.
 *
 * Only three shapes actually differ:
 *
 *   struct wg_media_type   the union is a POINTER, so it sits at +20 with the
 *                          struct 24 bytes long, against +24 / 32 bytes here.
 *   ..._push/read_data     `struct wg_sample *sample` is 4 bytes, moving
 *                          `result` from +16 to +12.
 *   struct wg_sample       identical in both builds -- every member is
 *                          fixed-width and i386 aligns INT64/UINT64 to 8 like
 *                          the host -- but its `data` member holds a GUEST
 *                          address, so only that VALUE is converted.
 *
 * Everything else in the table takes either a bare wg_transform_t (a UINT64,
 * same in both) or a block of fixed-width scalars at identical offsets, so
 * those entries are shared with the 64-bit table rather than re-thunked: a
 * thunk that only copies fields is a second place for the layout to drift.
 */
typedef ULONG PTR32;

struct wg_media_type32
{
    GUID  major;
    UINT32 format_size;
    PTR32 format;
};
C_ASSERT( sizeof(struct wg_media_type32) == 24 );

struct wg_transform_create_params32
{
    wg_transform_t transform;
    struct wg_media_type32 input_type;
    struct wg_media_type32 output_type;
    struct wg_transform_attrs attrs;
};

struct wg_transform_sample_params32
{
    wg_transform_t transform;
    PTR32 sample;
    HRESULT result;
};

struct wg_transform_output_type_params32
{
    wg_transform_t transform;
    struct wg_media_type32 media_type;
};

static void media_type_from32( struct wg_media_type *type, const struct wg_media_type32 *type32 )
{
    type->major = type32->major;
    type->format_size = type32->format_size;
    type->u.format = ios_wow_host_ptr( type32->format );
}

static NTSTATUS wow64_wma_transform_create( void *args )
{
    struct wg_transform_create_params32 *params32 = args;
    struct wg_transform_create_params params;
    NTSTATUS status;

    if (!params32) return STATUS_INVALID_PARAMETER;

    memset( &params, 0, sizeof(params) );
    media_type_from32( &params.input_type, &params32->input_type );
    media_type_from32( &params.output_type, &params32->output_type );
    params.attrs = params32->attrs;

    status = transform_create( &params );
    params32->transform = params.transform;
    return status;
}

/* `sample` is a guest pointer; the struct it points at has the same layout in
 * both builds, so it is used in place and only sample->data is converted. */
static NTSTATUS wow64_wma_transform_push_data( void *args )
{
    struct wg_transform_sample_params32 *params32 = args;
    struct wg_sample *sample;

    if (!params32) return STATUS_INVALID_PARAMETER;
    if (!(sample = ios_wow_host_ptr( params32->sample ))) return STATUS_INVALID_PARAMETER;
    return transform_push_data( params32->transform, sample,
                                ios_wow_host_ptr( (ULONG)sample->data ), &params32->result );
}

static NTSTATUS wow64_wma_transform_read_data( void *args )
{
    struct wg_transform_sample_params32 *params32 = args;
    struct wg_sample *sample;

    if (!params32) return STATUS_INVALID_PARAMETER;
    if (!(sample = ios_wow_host_ptr( params32->sample ))) return STATUS_INVALID_PARAMETER;
    return transform_read_data( params32->transform, sample,
                                ios_wow_host_ptr( (ULONG)sample->data ), &params32->result );
}

static NTSTATUS wow64_wma_transform_get_output_type( void *args )
{
    struct wg_transform_output_type_params32 *params32 = args;
    struct wg_media_type type;
    NTSTATUS status;

    if (!params32) return STATUS_INVALID_PARAMETER;
    media_type_from32( &type, &params32->media_type );
    status = transform_get_output_type( params32->transform, &type );
    /* OUT: the major type and the size the PE side must allocate.  The format
     * pointer itself is the caller's and is never written back. */
    params32->media_type.major = type.major;
    params32->media_type.format_size = type.format_size;
    return status;
}

static NTSTATUS wow64_wma_transform_set_output_type( void *args )
{
    struct wg_transform_output_type_params32 *params32 = args;
    struct wg_media_type type;

    if (!params32) return STATUS_INVALID_PARAMETER;
    media_type_from32( &type, &params32->media_type );
    return transform_set_output_type( params32->transform, &type );
}

const unixlib_entry_t __wine_unix_call_wow64_funcs[] =
{
    wma_init,                             /* unix_wg_init_gstreamer */

    wma_not_implemented,                  /* unix_wg_parser_create */
    wma_not_implemented,                  /* unix_wg_parser_destroy */

    wma_not_implemented,                  /* unix_wg_parser_connect */
    wma_not_implemented,                  /* unix_wg_parser_disconnect */

    wma_not_implemented,                  /* unix_wg_parser_get_next_read_offset */
    wma_not_implemented,                  /* unix_wg_parser_push_data */

    wma_not_implemented,                  /* unix_wg_parser_get_stream_count */
    wma_not_implemented,                  /* unix_wg_parser_get_stream */

    wma_not_implemented,                  /* unix_wg_parser_stream_get_current_format */
    wma_not_implemented,                  /* unix_wg_parser_stream_get_codec_format */
    wma_not_implemented,                  /* unix_wg_parser_stream_enable */
    wma_not_implemented,                  /* unix_wg_parser_stream_disable */

    wma_not_implemented,                  /* unix_wg_parser_stream_get_buffer */
    wma_not_implemented,                  /* unix_wg_parser_stream_copy_buffer */
    wma_not_implemented,                  /* unix_wg_parser_stream_release_buffer */
    wma_not_implemented,                  /* unix_wg_parser_stream_notify_qos */

    wma_not_implemented,                  /* unix_wg_parser_stream_get_duration */
    wma_not_implemented,                  /* unix_wg_parser_stream_get_tag */
    wma_not_implemented,                  /* unix_wg_parser_stream_seek */

    wow64_wma_transform_create,           /* unix_wg_transform_create */
    wma_transform_destroy,                /* unix_wg_transform_destroy */
    wow64_wma_transform_get_output_type,  /* unix_wg_transform_get_output_type */
    wow64_wma_transform_set_output_type,  /* unix_wg_transform_set_output_type */

    wow64_wma_transform_push_data,        /* unix_wg_transform_push_data */
    wow64_wma_transform_read_data,        /* unix_wg_transform_read_data */
    wma_transform_get_status,             /* unix_wg_transform_get_status */
    wma_transform_drain,                  /* unix_wg_transform_drain */
    wma_transform_flush,                  /* unix_wg_transform_flush */
    wma_transform_notify_qos,             /* unix_wg_transform_notify_qos */

    wma_not_implemented,                  /* unix_wg_muxer_create */
    wma_not_implemented,                  /* unix_wg_muxer_destroy */
    wma_not_implemented,                  /* unix_wg_muxer_add_stream */
    wma_not_implemented,                  /* unix_wg_muxer_start */
    wma_not_implemented,                  /* unix_wg_muxer_push_sample */
    wma_not_implemented,                  /* unix_wg_muxer_read_data */
    wma_not_implemented,                  /* unix_wg_muxer_finalize */
};

C_ASSERT( ARRAY_SIZE(__wine_unix_call_wow64_funcs) == unix_wg_funcs_count );
