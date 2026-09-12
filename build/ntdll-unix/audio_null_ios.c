/*
 * audio_null_ios.c — minimal Wine audio "null" driver for iOS Madeira.
 *
 * Wine's mmdevapi loads a `wine<name>.drv` PE plus a unix-side function
 * table (37 entries). On Linux/macOS the unix table is a separate .so.
 * On iOS we statically link the table into Madeira.app — this file is
 * that table for "ios" / "coreaudio".
 *
 * Behaviour: ONE fake render endpoint, accepts buffer submissions and
 * discards, advances IAudioClock at real-time based on
 * mach_absolute_time. Enough to let FMOD's clock-driven timing
 * advance (rhythm games like Thumper gate splash→title on intro
 * music completing — this is what makes that work).
 *
 * 2026-07-05 TIER-2: REAL AUDIO OUTPUT via a RemoteIO AudioUnit.
 * WASAPI render semantics map onto a lock-free ring buffer:
 *   get_render_buffer  -> contiguous scratch pointer
 *   release_render_buffer -> copy scratch into the ring, advance write_pos
 *   RemoteIO render callback (Core Audio real-time thread — touches ONLY
 *   the ring + atomics, never Wine) -> copy ring to hardware, advance
 *   play_pos; underrun plays silence
 *   get_current_padding -> write_pos - play_pos
 *   get_position        -> play_pos (frames actually consumed)
 *   timer_loop          -> Wine thread; signals the client event per period
 * If AudioUnit setup fails (no session, etc.) the driver degrades to the
 * Tier-1 wall-clock null behaviour so game timing never breaks.
 * AVAudioSession activation happens app-side (WineProcessBridge.m).
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <mach/mach_time.h>
#include <unistd.h>
#include <AudioToolbox/AudioToolbox.h>

/* Struct/enum mirrors from wine/dlls/mmdevapi/unixlib.h. Repeating the
 * essential layout here avoids include-path drama with Wine's COM
 * headers, which pull in <objbase.h>/<audioclient.h>. We only need the
 * struct fields the unix-call dispatch touches. */

typedef int NTSTATUS;
typedef uint16_t WCHAR;
typedef int32_t HRESULT;
typedef uint32_t DWORD;
typedef uint32_t UINT32;
typedef uint64_t UINT64;
typedef uint64_t UINT_PTR;
typedef uint32_t UINT;
typedef int BOOL;
typedef uint8_t BYTE;
typedef int64_t REFERENCE_TIME;
typedef void *HANDLE;
typedef uint16_t WORD;
typedef uint64_t stream_handle;
typedef int EDataFlow;

#define STATUS_SUCCESS 0
#define S_OK 0
#define E_OUTOFMEMORY ((HRESULT)0x8007000EL)
#define AUDCLNT_E_NOT_INITIALIZED ((HRESULT)0x88890001L)
#define S_FALSE 1
#define E_FAIL 0x80004005L
#define E_NOTIMPL 0x80004001L
#define AUDCLNT_E_NOT_INITIALIZED 0x88890001L

#define eRender 0
#define eCapture 1

enum driver_priority {
    Priority_Unavailable = 0,
    Priority_Low,
    Priority_Neutral,
    Priority_Preferred
};

struct endpoint {
    unsigned int name;
    unsigned int device;
};

struct main_loop_params { HANDLE event; };

struct get_endpoint_ids_params {
    EDataFlow flow;
    struct endpoint *endpoints;
    unsigned int size;
    HRESULT result;
    unsigned int num;
    unsigned int default_idx;
};

struct WAVEFORMATEX_stub {
    WORD wFormatTag;
    WORD nChannels;
    DWORD nSamplesPerSec;
    DWORD nAvgBytesPerSec;
    WORD nBlockAlign;
    WORD wBitsPerSample;
    WORD cbSize;
};

struct create_stream_params {
    const WCHAR *name;
    const char *device;
    EDataFlow flow;
    int share;
    DWORD flags;
    REFERENCE_TIME duration;
    REFERENCE_TIME period;
    const struct WAVEFORMATEX_stub *fmt;
    HRESULT result;
    UINT32 *channel_count;
    stream_handle *stream;
};

struct stream_handle_params { stream_handle stream; HRESULT result; };
struct timer_loop_params { stream_handle stream; };
struct stream_handle_only { stream_handle stream; };

struct release_stream_params {
    stream_handle stream;
    HANDLE timer_thread;
    HRESULT result;
};

struct get_render_buffer_params {
    stream_handle stream;
    UINT32 frames;
    HRESULT result;
    BYTE **data;
};

struct release_render_buffer_params {
    stream_handle stream;
    UINT32 written_frames;
    UINT flags;
    HRESULT result;
};

struct get_capture_buffer_params {
    stream_handle stream;
    HRESULT result;
    BYTE **data;
    UINT32 *frames;
    UINT *flags;
    UINT64 *devpos;
    UINT64 *qpcpos;
};

struct release_capture_buffer_params {
    stream_handle stream;
    UINT32 done;
    HRESULT result;
};

struct is_format_supported_params {
    const char *device;
    EDataFlow flow;
    int share;
    const struct WAVEFORMATEX_stub *fmt_in;
    HRESULT result;
};

struct get_loopback_capture_device_params {
    const WCHAR *name;
    const char *device;
    char *ret_device;
    UINT32 ret_device_len;
    HRESULT result;
};

struct get_mix_format_params {
    const char *device;
    EDataFlow flow;
    void *fmt;          /* WAVEFORMATEXTENSIBLE */
    HRESULT result;
};

struct get_device_period_params {
    const char *device;
    EDataFlow flow;
    HRESULT result;
    REFERENCE_TIME *def_period;
    REFERENCE_TIME *min_period;
};

struct get_buffer_size_params {
    stream_handle stream;
    HRESULT result;
    UINT32 *frames;
};

struct get_latency_params {
    stream_handle stream;
    HRESULT result;
    REFERENCE_TIME *latency;
};

struct get_current_padding_params {
    stream_handle stream;
    HRESULT result;
    UINT32 *padding;
};

struct get_next_packet_size_params {
    stream_handle stream;
    HRESULT result;
    UINT32 *frames;
};

struct get_frequency_params {
    stream_handle stream;
    HRESULT result;
    UINT64 *freq;
};

struct get_position_params {
    stream_handle stream;
    BOOL device;
    HRESULT result;
    UINT64 *pos;
    UINT64 *qpctime;
};

struct set_volumes_params {
    stream_handle stream;
    float master_volume;
    const float *volumes;
    const float *session_volumes;
};

struct set_event_handle_params {
    stream_handle stream;
    HANDLE event;
    HRESULT result;
};

struct set_sample_rate_params {
    stream_handle stream;
    float rate;
    HRESULT result;
};

struct test_connect_params {
    const WCHAR *name;
    enum driver_priority priority;
};

struct is_started_params {
    stream_handle stream;
    HRESULT result;
};

struct get_prop_value_params {
    const char *device;
    EDataFlow flow;
    const void *guid;
    const void *prop;
    HRESULT result;
    void *value;
    void *buffer;
    unsigned int *buffer_size;
};

/* ------------------- MADEIRA: WoW64 guest window ------------------- */

/* WOW64_DESIGN.md 2 "shifted guest window": a 32-bit pseudo-process owns one
 * reserved host range [B, B+4G) and guest address `a` lives at host B + a.
 * The helpers below are the same ones build/ntdll-unix/ios_wow.h and
 * wine/include/wine/unixlib.h publish; they are respelled here (with matching
 * signatures) because this file deliberately carries no Wine headers -- see
 * the struct-mirror note above.  The guard is the one ios_wow.h uses, so if
 * this file ever does gain those includes the first definition wins. */
extern unsigned long ios_wow_base(void);          /* 0 when not a WoW process */
extern int ios_wow_in_window(const void *addr);

#ifndef __MADEIRA_IOS_WOW_HOST_PTR
#define __MADEIRA_IOS_WOW_HOST_PTR
static inline void *ios_wow_host_ptr(uint32_t addr)
{
    return addr ? (void *)(ios_wow_base() + (uintptr_t)addr) : NULL;
}
static inline uint32_t ios_wow_guest_ptr32(const void *host)
{
    return host ? (uint32_t)((uintptr_t)host - ios_wow_base()) : 0;
}
#endif

/* A 32-bit field holding a guest pointer. */
typedef uint32_t PTR32;

/* Handles are never offset (WOW64_DESIGN.md 3, invariant 4): a 32-bit HANDLE
 * is zero-extended, exactly like upstream's ULongToHandle(). */
#define IOS_WOW_HANDLE(x)  ((HANDLE)(uintptr_t)(uint32_t)(x))

/* Enough of NtAllocateVirtualMemory to put the render scratch inside the
 * guest window.  Both live in the same statically-linked unix ntdll as
 * NtSetEvent above; the signatures match wine/include/winternl.h with
 * ULONG_PTR/SIZE_T spelled as the 64-bit unsigned types they are here. */
extern NTSTATUS NtAllocateVirtualMemory( HANDLE process, void **ret, UINT_PTR zero_bits,
                                         UINT_PTR *size_ptr, DWORD type, DWORD protect );
extern NTSTATUS NtFreeVirtualMemory( HANDLE process, void **addr_ptr,
                                     UINT_PTR *size_ptr, DWORD type );

#define IOS_CURRENT_PROCESS ((HANDLE)(intptr_t)-1)
#define IOS_MEM_COMMIT      0x00001000u
#define IOS_MEM_RESERVE     0x00002000u
#define IOS_MEM_RELEASE     0x00008000u
#define IOS_PAGE_READWRITE  0x00000004u

/* ---------------------------------------------------------------- */

#define IOS_AUDIO_SAMPLE_RATE 48000u
#define IOS_AUDIO_CHANNELS 2u
#define IOS_AUDIO_BITS 16u
#define IOS_AUDIO_FRAME_BYTES ((IOS_AUDIO_CHANNELS * IOS_AUDIO_BITS) / 8u) /* 4 */
#define IOS_AUDIO_BUFFER_FRAMES 1024u  /* ~21 ms at 48 kHz */
#define IOS_AUDIO_BUFFER_BYTES (IOS_AUDIO_BUFFER_FRAMES * IOS_AUDIO_FRAME_BYTES)

/* The "device" Wine probes by name. mmdevapi stores it on the endpoint
 * struct and passes it back as `const char *device` in many calls. */
static const char IOS_DEVICE_NAME[] = "ios-null";

/* One global stream state — single render endpoint, single stream. FMOD
 * typically creates one shared-mode render stream; if a game opens a
 * second concurrent stream we'd need a table. Not worried about that
 * for the Tier-1 silent driver. */
struct ios_stream {
    int valid;
    int started;
    uint64_t start_mach;        /* mach_absolute_time() at start() (null-mode clock) */
    uint64_t accumulated_frames; /* null-mode: frames "played" before last stop */
    UINT32 sample_rate;
    UINT32 channels;
    UINT32 frame_bytes;          /* nBlockAlign of the stream format */
    UINT32 buffer_frames;        /* ring capacity in frames */
    BYTE *render_scratch;        /* contiguous area handed to GetBuffer */
    UINT32 scratch_frames;       /* scratch capacity */
    /* MADEIRA: how render_scratch was obtained.  A 32-bit client can only
     * address memory inside its guest window, so for a WoW process the
     * scratch is an NtAllocateVirtualMemory reservation under a guest
     * ceiling instead of a calloc(); scratch_guest says which free() to
     * use.  See ios_audio_alloc_scratch(). */
    int scratch_guest;
    UINT_PTR scratch_bytes;      /* reservation size (scratch_guest only) */
    UINT32 pending_frames;       /* frames handed out, awaiting release */
    HANDLE event;
    /* Tier-2 real output */
    AudioUnit au;                /* RemoteIO; NULL = null-mode fallback */
    int au_running;
    BYTE *ring;
    _Atomic uint64_t write_pos;  /* frames produced by the game (monotonic) */
    _Atomic uint64_t play_pos;   /* frames consumed by the RT callback */
};

/* ml739: one stream object per client, mirroring Wine's CoreAudio driver.
 *
 * This was a documented singleton -- see the comment on struct ios_stream --
 * and ordinary WASAPI use breaks it: a title that plays a cutscene opens a
 * second concurrent render client (48k/2ch float32) while its main audio
 * client (48k/2ch PCM16) is still live. Both were handed the SAME handle, so
 * creating the second tore down the first's AudioUnit, set_event_handle
 * overwrote the first client's event -- after which it was never signalled
 * again -- and both shared one ring, one padding counter and one play
 * position, with two audio_client_timer threads driving them. The audible
 * result was a silent cutscene; the functional result was a source queue that
 * never drained, so the video never reported completion.
 *
 * The registry exists only for handle validation and process-detach cleanup.
 * It is never touched from the RemoteIO callback, which reaches its stream
 * through inputProcRefCon. */
#define IOS_MAX_STREAMS 16
static struct ios_stream *g_streams[IOS_MAX_STREAMS];
static pthread_mutex_t g_streams_lock;   /* ml739: init at process_attach */

static struct ios_stream *stream_from_handle(stream_handle h)
{
    struct ios_stream *s = (struct ios_stream *)(uintptr_t)h;
    int i, ok = 0;
    if (!s) return NULL;
    pthread_mutex_lock(&g_streams_lock);
    for (i = 0; i < IOS_MAX_STREAMS; i++) if (g_streams[i] == s) { ok = 1; break; }
    pthread_mutex_unlock(&g_streams_lock);
    if (!ok) {
        static int moaned;
        if (moaned++ < 8)
            fprintf(stderr, "[ios-astream] ml739 STALE handle %p -- ignoring\n", (void *)s);
        return NULL;
    }
    return s;
}

static int stream_register(struct ios_stream *s)
{
    int i, n = 0;
    pthread_mutex_lock(&g_streams_lock);
    for (i = 0; i < IOS_MAX_STREAMS; i++) if (g_streams[i]) n++;
    for (i = 0; i < IOS_MAX_STREAMS; i++) if (!g_streams[i]) { g_streams[i] = s; break; }
    pthread_mutex_unlock(&g_streams_lock);
    if (i == IOS_MAX_STREAMS) return -1;
    fprintf(stderr, "[ios-astream] ml739 CREATE stream=%p (%d now live)\n", (void *)s, n + 1);
    return 0;
}

static void stream_unregister(struct ios_stream *s)
{
    int i, n = 0;
    pthread_mutex_lock(&g_streams_lock);
    for (i = 0; i < IOS_MAX_STREAMS; i++) if (g_streams[i] == s) g_streams[i] = NULL;
    for (i = 0; i < IOS_MAX_STREAMS; i++) if (g_streams[i]) n++;
    pthread_mutex_unlock(&g_streams_lock);
    fprintf(stderr, "[ios-astream] ml739 RELEASE stream=%p (%d still live)\n", (void *)s, n);
}

/* ml738: this driver is a documented singleton -- see the comment on
 * struct ios_stream. One title opens TWO concurrent render streams with
 * different formats (48k/2ch PCM16, then 48k/2ch float32), which is exactly
 * the case the comment says needs a table. Every client is handed the SAME
 * handle (&g_stream), so the driver cannot tell them apart: creating the
 * second tears down the first's AudioUnit, set_event_handle overwrites the
 * first client's event, releasing either invalidates both, and they share one
 * ring, one padding counter and one playback position.
 *
 * Instrument before changing behaviour: generation, the handle handed out, the
 * event handle and the calling thread, so the interleaving is visible rather
 * than inferred. */
static unsigned long long ios_current_tid(void)
{
    uint64_t t = 0;
    pthread_threadid_np(NULL, &t);
    return (unsigned long long)t;
}

static unsigned int g_stream_gen;
static unsigned int g_live_streams;
static mach_timebase_info_data_t g_timebase;

/* NtSetEvent lives in the same statically-linked unix ntdll. timer_loop
 * runs on a real Wine thread (mmdevapi spawns it into this unix call),
 * so calling into ntdll here is legal — unlike from the RT callback. */
extern NTSTATUS NtSetEvent( HANDLE handle, void *prev_state );

/* Per-function call counters. Print every 1000 calls so we can confirm
 * FMOD is actually exercising the driver. Cheap atomic increments. */
#include <stdatomic.h>
#define NULL_AUDIO_FN_COUNT 37
static _Atomic uint32_t g_call_counter[NULL_AUDIO_FN_COUNT];
#define LOG_FN_CALL(idx, name) do { \
    uint32_t n = atomic_fetch_add_explicit(&g_call_counter[idx], 1, memory_order_relaxed) + 1; \
    if (n == 1 || (n % 1000) == 0) { \
        char buf[128]; \
        int len = snprintf(buf, sizeof(buf), "[ios_audio] " name " #%u\n", n); \
        if (len > 0) write(STDERR_FILENO, buf, len); \
    } \
} while (0)

static uint64_t mach_to_ns(uint64_t mach) {
    if (!g_timebase.denom) mach_timebase_info(&g_timebase);
    return mach * g_timebase.numer / g_timebase.denom;
}

static uint64_t elapsed_ns_since(uint64_t mach_start) {
    return mach_to_ns(mach_absolute_time() - mach_start);
}

static uint64_t elapsed_frames(const struct ios_stream *s) {
    if (!s->started) return s->accumulated_frames;
    uint64_t ns = elapsed_ns_since(s->start_mach);
    /* frames = ns * rate / 1e9 */
    return s->accumulated_frames + (ns * s->sample_rate / 1000000000ull);
}

/* ------------------- Tier-2: RemoteIO real output ------------------- */

/* Core Audio real-time thread. Ring + atomics ONLY — no Wine calls, no
 * locks, no allocation, no logging. Underrun = silence (WASAPI-correct:
 * padding drains to 0 and the position clock pauses at write_pos). */
static OSStatus ios_audio_render_cb(void *refcon, AudioUnitRenderActionFlags *flags,
                                    const AudioTimeStamp *ts, UInt32 bus,
                                    UInt32 nframes, AudioBufferList *iodata) {
    struct ios_stream *s = refcon;
    BYTE *out = (BYTE *)iodata->mBuffers[0].mData;
    UINT32 fb = s->frame_bytes;
    UINT32 cap = s->buffer_frames;
    uint64_t play = atomic_load_explicit(&s->play_pos, memory_order_relaxed);
    uint64_t wr = atomic_load_explicit(&s->write_pos, memory_order_acquire);
    uint64_t avail = wr - play;
    UInt32 tocopy = avail < nframes ? (UInt32)avail : nframes;
    UInt32 i = 0;
    (void)flags; (void)ts; (void)bus;
    while (i < tocopy) {
        UINT32 idx = (UINT32)((play + i) % cap);
        UINT32 chunk = cap - idx;
        if (chunk > tocopy - i) chunk = tocopy - i;
        memcpy(out + (size_t)i * fb, s->ring + (size_t)idx * fb, (size_t)chunk * fb);
        i += chunk;
    }
    if (tocopy < nframes)
        memset(out + (size_t)tocopy * fb, 0, (size_t)(nframes - tocopy) * fb);
    atomic_store_explicit(&s->play_pos, play + tocopy, memory_order_release);
    return noErr;
}

/* Parse the WASAPI format into "is float?" — tag 3 = IEEE float, tag
 * 0xFFFE = extensible (SubFormat GUID first byte: 1 PCM, 3 float). */
static int ios_fmt_is_float(const struct WAVEFORMATEX_stub *fmt) {
    if (!fmt) return 0;
    if (fmt->wFormatTag == 3) return 1;
    if (fmt->wFormatTag == 0xFFFE && fmt->cbSize >= 22) {
        const uint8_t *sub = (const uint8_t *)fmt + 24;
        return sub[0] == 3;
    }
    return 0;
}

/* Build the RemoteIO unit for the negotiated stream format. Returns 0 on
 * success; any failure leaves s->au NULL (null-mode fallback). */
static int ios_audio_setup_unit(struct ios_stream *s, const struct WAVEFORMATEX_stub *fmt) {
    AudioComponentDescription desc = {0};
    AudioComponent comp;
    AudioStreamBasicDescription asbd = {0};
    AURenderCallbackStruct cb;
    OSStatus err;

    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_RemoteIO;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    comp = AudioComponentFindNext(NULL, &desc);
    if (!comp) { fprintf(stderr, "[ios_audio] RemoteIO component not found\n"); return -1; }
    if ((err = AudioComponentInstanceNew(comp, &s->au))) {
        fprintf(stderr, "[ios_audio] AudioComponentInstanceNew: %d\n", (int)err);
        s->au = NULL; return -1;
    }

    asbd.mSampleRate = s->sample_rate;
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = kAudioFormatFlagIsPacked |
        (ios_fmt_is_float(fmt) ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger);
    asbd.mBytesPerPacket = s->frame_bytes;
    asbd.mFramesPerPacket = 1;
    asbd.mBytesPerFrame = s->frame_bytes;
    asbd.mChannelsPerFrame = s->channels;
    asbd.mBitsPerChannel = (s->frame_bytes / s->channels) * 8;

    err = AudioUnitSetProperty(s->au, kAudioUnitProperty_StreamFormat,
                               kAudioUnitScope_Input, 0, &asbd, sizeof(asbd));
    if (err) {
        fprintf(stderr, "[ios_audio] SetProperty(StreamFormat rate=%u ch=%u fb=%u float=%d): %d\n",
                s->sample_rate, s->channels, s->frame_bytes, ios_fmt_is_float(fmt), (int)err);
        goto fail;
    }

    cb.inputProc = ios_audio_render_cb;
    cb.inputProcRefCon = s;
    err = AudioUnitSetProperty(s->au, kAudioUnitProperty_SetRenderCallback,
                               kAudioUnitScope_Input, 0, &cb, sizeof(cb));
    if (err) { fprintf(stderr, "[ios_audio] SetRenderCallback: %d\n", (int)err); goto fail; }

    if ((err = AudioUnitInitialize(s->au))) {
        fprintf(stderr, "[ios_audio] AudioUnitInitialize: %d\n", (int)err);
        goto fail;
    }
    fprintf(stderr, "[ios_audio] RemoteIO ready: %u Hz, %u ch, %u B/frame, float=%d, ring=%u frames\n",
            s->sample_rate, s->channels, s->frame_bytes, ios_fmt_is_float(fmt), s->buffer_frames);
    return 0;
fail:
    AudioComponentInstanceDispose(s->au);
    s->au = NULL;
    return -1;
}

static void ios_audio_teardown_unit(struct ios_stream *s) {
    if (!s->au) return;
    if (s->au_running) AudioOutputUnitStop(s->au);
    AudioUnitUninitialize(s->au);
    AudioComponentInstanceDispose(s->au);
    s->au = NULL;
    s->au_running = 0;
}

/* ---------------------------------------------------------------- */

/* MADEIRA (WOW64_DESIGN.md 3, invariants 1 and 2): render-buffer ownership.
 *
 * render_scratch is the ONE buffer this driver hands back to its client:
 * get_render_buffer returns it and the application writes its samples
 * straight into it (release_render_buffer then copies it into the ring).
 * Invariant 1 says any pointer guest code can observe is a guest address, so
 * for a 32-bit client that buffer MUST live inside that process's
 * [B, B+4G) window.  A calloc() pointer is ordinary host furniture far above
 * 4 GB: publishing it would truncate to an unrelated low address and the
 * first sample the game wrote would land somewhere random in the window.
 *
 * So when the calling process has a window, reserve the scratch with a GUEST
 * ceiling -- zero_bits = 1 gives limit 0x7fffffff, which virtual_ios.c's
 * ios_wow_translate_limits() turns into [B+floor, B+0x7fffffff] -- and refuse
 * loudly if the result somehow lands outside the window.  With no window
 * (every 64-bit caller) this is byte-for-byte the calloc() path that has
 * always been here.
 *
 * The ring and the AudioUnit are untouched: they are only ever read by the
 * unix side and the Core Audio RT thread, which speak host addresses.
 */
static BYTE *ios_audio_alloc_scratch(UINT32 frames, UINT32 frame_bytes,
                                     int *is_guest, UINT_PTR *alloc_bytes)
{
    void *addr = NULL;
    UINT_PTR size;
    NTSTATUS st;

    *is_guest = 0;
    *alloc_bytes = 0;
    if (!frames || !frame_bytes) return NULL;

    if (!ios_wow_base())
        return (BYTE *)calloc(frames, frame_bytes);

    size = (UINT_PTR)frames * frame_bytes;
    st = NtAllocateVirtualMemory(IOS_CURRENT_PROCESS, &addr, 1 /* zero_bits */, &size,
                                 IOS_MEM_COMMIT | IOS_MEM_RESERVE, IOS_PAGE_READWRITE);
    if (st || !addr || !ios_wow_in_window(addr)) {
        fprintf(stderr, "[ios_audio] WOW64 render scratch (%u frames x %u B) could not be "
                        "placed in the guest window (status 0x%x, addr %p) -- refusing, "
                        "rather than handing a host-only pointer to 32-bit code\n",
                frames, frame_bytes, (unsigned)st, addr);
        if (!st && addr) {
            UINT_PTR z = 0;
            NtFreeVirtualMemory(IOS_CURRENT_PROCESS, &addr, &z, IOS_MEM_RELEASE);
        }
        return NULL;
    }
    *is_guest = 1;
    *alloc_bytes = size;
    return (BYTE *)addr;
}

static void ios_audio_free_scratch(BYTE *scratch, int is_guest)
{
    if (!scratch) return;
    if (is_guest) {
        void *addr = scratch;
        UINT_PTR z = 0;
        NtFreeVirtualMemory(IOS_CURRENT_PROCESS, &addr, &z, IOS_MEM_RELEASE);
    }
    else free(scratch);
}

static NTSTATUS ios_process_attach(void *args) {
    LOG_FN_CALL(0, "process_attach");
    (void)args;
    pthread_mutex_init(&g_streams_lock, NULL);
    if (!g_timebase.denom) mach_timebase_info(&g_timebase);
    return STATUS_SUCCESS;
}

static NTSTATUS ios_process_detach(void *args) {
    (void)args;
    /* ml739: tear down whatever is still registered. Previously this freed the
     * singleton's scratch buffer only; with a stream per client anything still
     * live at process detach has to be disposed individually. */
    {
        int i;
        for (i = 0; i < IOS_MAX_STREAMS; i++) {
            struct ios_stream *s;
            pthread_mutex_lock(&g_streams_lock);
            s = g_streams[i];
            g_streams[i] = NULL;
            pthread_mutex_unlock(&g_streams_lock);
            if (!s) continue;
            /* Stop the hardware, but do NOT free. release_stream joins a
             * stream's own timer thread before freeing it; here we have no
             * handle to join, and freeing while that thread may still be
             * looping is a use-after-free. The process is going away, so
             * leaving the memory is the safe trade. */
            s->valid = 0;
            s->started = 0;
            ios_audio_teardown_unit(s);
        }
    }
    return STATUS_SUCCESS;
}

static NTSTATUS ios_main_loop(void *args) {
    /* CONTRACT (mmdevapi client.c main_loop_start): the PE side blocks
     * WaitForSingleObject(event, INFINITE) until the driver signals this
     * event. Returning WITHOUT signaling deadlocks whoever triggered
     * driver init — FMOD's IAudioClient path — which held Thumper on the
     * splash screen (2026-07-05; and likely the misread May "FMOD probes
     * then stops" observation). winecoreaudio does exactly this. */
    struct main_loop_params { HANDLE event; } *p = args;
    LOG_FN_CALL(2, "main_loop");
    NtSetEvent(p->event, NULL);
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_endpoint_ids(void *args) {
    LOG_FN_CALL(3, "get_endpoint_ids");
    struct get_endpoint_ids_params *p = args;
    /* Only render endpoints; refuse capture entirely. */
    if (p->flow != eRender) {
        p->num = 0;
        p->default_idx = 0;
        p->result = S_OK;
        return STATUS_SUCCESS;
    }
    /* mmdevapi treats endpoint.name as WCHAR* (wide string, 2 bytes/char)
     * and endpoint.device as char* (single-byte). Both stored as byte
     * offsets from the endpoints buffer base. */
    static const WCHAR dev_name_w[] = { 'i','O','S',' ','N','u','l','l', 0 };
    unsigned int name_bytes = sizeof(dev_name_w);
    unsigned int device_bytes = sizeof(IOS_DEVICE_NAME);
    unsigned int needed = sizeof(struct endpoint) + name_bytes + device_bytes;
    if (p->size < needed) {
        p->num = 1;
        p->default_idx = 0;
        p->result = 0x80070057L; /* E_INVALIDARG style — signal "need more space" */
        return STATUS_SUCCESS;
    }
    /* Layout: [endpoint][wide_name\0\0][device_str\0] */
    unsigned int name_off = sizeof(struct endpoint);
    unsigned int device_off = name_off + name_bytes;
    char *buf = (char *)p->endpoints;
    memcpy(buf + name_off, dev_name_w, name_bytes);
    memcpy(buf + device_off, IOS_DEVICE_NAME, device_bytes);
    p->endpoints[0].name = name_off;
    p->endpoints[0].device = device_off;
    p->num = 1;
    p->default_idx = 0;
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_create_stream(void *args) {
    LOG_FN_CALL(4, "create_stream");
    struct create_stream_params *p = args;
    uint64_t dur_frames;
    /* ml739: a stream per client. */
    struct ios_stream *s = calloc(1, sizeof(*s));
    if (!s) { p->result = E_OUTOFMEMORY; return STATUS_SUCCESS; }
    s->valid = 1;
    s->started = 0;
    s->start_mach = 0;
    s->accumulated_frames = 0;
    s->sample_rate = p->fmt && p->fmt->nSamplesPerSec ? p->fmt->nSamplesPerSec : IOS_AUDIO_SAMPLE_RATE;
    s->channels = p->fmt && p->fmt->nChannels ? p->fmt->nChannels : IOS_AUDIO_CHANNELS;
    s->frame_bytes = p->fmt && p->fmt->nBlockAlign ? p->fmt->nBlockAlign
                          : (s->channels * IOS_AUDIO_BITS) / 8;
    /* Ring capacity: the requested buffer duration (100ns units), floor
     * 100ms so a slow FEX-translated mixer has slack. */
    dur_frames = (uint64_t)(p->duration > 0 ? p->duration : 0) * s->sample_rate / 10000000ull;
    if (dur_frames < s->sample_rate / 10) dur_frames = s->sample_rate / 10;
    if (dur_frames > s->sample_rate * 4) dur_frames = s->sample_rate * 4;
    s->buffer_frames = (UINT32)dur_frames;
    free(s->ring);
    s->ring = (BYTE *)calloc(s->buffer_frames, s->frame_bytes);
    /* MADEIRA: guest-visible for a WoW client, plain calloc otherwise. */
    s->render_scratch = ios_audio_alloc_scratch(s->buffer_frames, s->frame_bytes,
                                                &s->scratch_guest, &s->scratch_bytes);
    s->scratch_frames = s->render_scratch ? s->buffer_frames : 0;
    s->pending_frames = 0;
    atomic_store(&s->write_pos, 0);
    atomic_store(&s->play_pos, 0);

    if (p->flow == eRender && s->ring)
        ios_audio_setup_unit(s, p->fmt);   /* failure -> null-mode */

    if (p->channel_count) *p->channel_count = s->channels;
    if (p->stream) *p->stream = (stream_handle)(uintptr_t)s;
    fprintf(stderr, "[ios-astream] ml738 CREATED gen=%u handle=%p rate=%u ch=%u fb=%u\n",
            g_stream_gen, (void *)s, s->sample_rate, s->channels,
            s->frame_bytes);
    if (stream_register(s)) {
        fprintf(stderr, "[ios-astream] ml739 too many streams -- refusing\n");
        ios_audio_teardown_unit(s);
        ios_audio_free_scratch(s->render_scratch, s->scratch_guest);
        free(s->ring); free(s);
        /* the handle was published above; it now points at freed memory */
        if (p->stream) *p->stream = 0;
        p->result = E_OUTOFMEMORY;
        return STATUS_SUCCESS;
    }
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_release_stream(void *args) {
    struct release_stream_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);

    if (!s) { p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }

    /* Order matters. Mark this stream dead first so its own timer thread
     * leaves its loop, join that thread, and only then dispose the AudioUnit
     * so the render callback cannot still be running against memory we are
     * about to free. Nothing here touches another client's stream. */
    s->valid = 0;
    s->started = 0;
    if (p->timer_thread) {
        NtWaitForSingleObject(p->timer_thread, FALSE, NULL);
        NtClose(p->timer_thread);
    }
    ios_audio_teardown_unit(s);
    stream_unregister(s);
    ios_audio_free_scratch(s->render_scratch, s->scratch_guest);
    free(s->ring);
    free(s);
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_start(void *args) {
    LOG_FN_CALL(6, "start");
    struct stream_handle_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    if (!s->started) {
        if (s->au && !s->au_running) {
            OSStatus err = AudioOutputUnitStart(s->au);
            if (err) {
                fprintf(stderr, "[ios_audio] AudioOutputUnitStart: %d — null-mode\n", (int)err);
                ios_audio_teardown_unit(s);
            } else {
                s->au_running = 1;
            }
        }
        s->start_mach = mach_absolute_time();
        s->started = 1;
    }
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_stop(void *args) {
    struct stream_handle_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    if (s->started) {
        if (s->au && s->au_running) {
            AudioOutputUnitStop(s->au);
            s->au_running = 0;
        }
        s->accumulated_frames = elapsed_frames(s);
        s->started = 0;
    }
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_reset(void *args) {
    struct stream_handle_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    s->started = 0;
    s->accumulated_frames = 0;
    s->start_mach = 0;
    /* Drop queued-but-unplayed audio (only legal while stopped). */
    atomic_store(&s->write_pos, 0);
    atomic_store(&s->play_pos, 0);
    s->pending_frames = 0;
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_timer_loop(void *args) {
    /* Runs on a dedicated Wine thread mmdevapi spawns for event-driven
     * clients. Wake the client every device period so it refills the
     * ring; exit when the stream dies. */
    struct timer_loop_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) return STATUS_SUCCESS;
    LOG_FN_CALL(9, "timer_loop");
    while (s->valid) {
        usleep(10000); /* device period, 10 ms */
        if (s->event && s->started)
            NtSetEvent(s->event, NULL);
    }
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_render_buffer(void *args) {
    LOG_FN_CALL(10, "get_render_buffer");
    struct get_render_buffer_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { if (p->data) *p->data = NULL; p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    if (s->au) {
        uint64_t padding = atomic_load(&s->write_pos) - atomic_load(&s->play_pos);
        if (p->frames + padding > s->buffer_frames) {
            p->result = (HRESULT)0x88890006L; /* AUDCLNT_E_BUFFER_TOO_LARGE */
            if (p->data) *p->data = NULL;
            return STATUS_SUCCESS;
        }
    }
    if (p->frames > s->scratch_frames) {
        /* Client asked for more than the ring — grow scratch; the copy in
         * release clamps to ring capacity anyway.
         *
         * MADEIRA: this used to be a realloc().  A WoW client's scratch is a
         * guest-window reservation, not heap, so the grow is allocate-then-
         * free — new first, so an allocation failure leaves the old buffer
         * intact exactly as realloc() did.  Nothing written into the scratch
         * before this point is live (the client has not called GetBuffer
         * yet), so not preserving the contents is not observable. */
        int guest = 0;
        UINT_PTR bytes = 0;
        BYTE *ns = ios_audio_alloc_scratch(p->frames, s->frame_bytes, &guest, &bytes);
        if (!ns) { if (p->data) *p->data = NULL; p->result = E_FAIL; return STATUS_SUCCESS; }
        ios_audio_free_scratch(s->render_scratch, s->scratch_guest);
        s->render_scratch = ns;
        s->scratch_guest = guest;
        s->scratch_bytes = bytes;
        s->scratch_frames = p->frames;
    }
    if (!s->render_scratch) { if (p->data) *p->data = NULL; p->result = E_FAIL; return STATUS_SUCCESS; }
    s->pending_frames = p->frames;
    if (p->data) *p->data = s->render_scratch;
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_release_render_buffer(void *args) {
    struct release_render_buffer_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    if (s->au && p->written_frames > 0) {
        UINT32 fb = s->frame_bytes;
        UINT32 cap = s->buffer_frames;
        UINT32 n = p->written_frames;
        uint64_t wr = atomic_load_explicit(&s->write_pos, memory_order_relaxed);
        UINT32 i = 0;
        if (n > s->pending_frames) n = s->pending_frames;
        if (p->flags & 0x2 /* AUDCLNT_BUFFERFLAGS_SILENT */)
            memset(s->render_scratch, 0, (size_t)n * fb);
        while (i < n) {
            UINT32 idx = (UINT32)((wr + i) % cap);
            UINT32 chunk = cap - idx;
            if (chunk > n - i) chunk = n - i;
            memcpy(s->ring + (size_t)idx * fb,
                   s->render_scratch + (size_t)i * fb, (size_t)chunk * fb);
            i += chunk;
        }
        /* release-store AFTER the copy so the RT callback never reads
         * frames that aren't fully written */
        atomic_store_explicit(&s->write_pos, wr + n, memory_order_release);
    }
    s->pending_frames = 0;
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_capture_buffer(void *args) {
    struct get_capture_buffer_params *p = args;
    if (p->frames) *p->frames = 0;
    if (p->data) *p->data = NULL;
    if (p->flags) *p->flags = 0;
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_release_capture_buffer(void *args) {
    struct release_capture_buffer_params *p = args;
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_is_format_supported(void *args) {
    struct is_format_supported_params *p = args;
    LOG_FN_CALL(14, "is_format_supported");
    /* Accept anything. */
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_loopback_capture_device(void *args) {
    struct get_loopback_capture_device_params *p = args;
    /* This driver exposes no capture endpoint at all (get_endpoint_ids
     * refuses eCapture), so loopback capture cannot work.  Say so: this used
     * to return STATUS_SUCCESS and leave `result` untouched, which is an
     * uninitialised HRESULT for the caller — harmless only because mmdevapi
     * never reaches this call without a capture endpoint. */
    if (p) p->result = (HRESULT)E_NOTIMPL;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_mix_format(void *args) {
    struct get_mix_format_params *p = args;
    LOG_FN_CALL(16, "get_mix_format");
    /* WAVEFORMATEXTENSIBLE is 40 bytes; first 18 are WAVEFORMATEX */
    if (p->fmt) {
        memset(p->fmt, 0, 40);
        struct WAVEFORMATEX_stub *f = p->fmt;
        f->wFormatTag = 0xFFFE; /* WAVE_FORMAT_EXTENSIBLE */
        f->nChannels = IOS_AUDIO_CHANNELS;
        f->nSamplesPerSec = IOS_AUDIO_SAMPLE_RATE;
        f->wBitsPerSample = IOS_AUDIO_BITS;
        f->nBlockAlign = IOS_AUDIO_FRAME_BYTES;
        f->nAvgBytesPerSec = IOS_AUDIO_SAMPLE_RATE * IOS_AUDIO_FRAME_BYTES;
        f->cbSize = 22; /* extensible body */
        /* Extensible body: Samples (2), ChannelMask (4), SubFormat (16).
         * KSDATAFORMAT_SUBTYPE_PCM = {00000001-0000-0010-8000-00AA00389B71} */
        uint16_t *samples = (uint16_t *)((char *)p->fmt + 18);
        *samples = IOS_AUDIO_BITS;
        uint32_t *mask = (uint32_t *)((char *)p->fmt + 20);
        *mask = 0x3; /* SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT */
        /* SubFormat GUID PCM */
        static const uint8_t pcm_guid[16] = {
            0x01,0x00,0x00,0x00, 0x00,0x00, 0x10,0x00,
            0x80,0x00, 0x00,0xAA, 0x00,0x38,0x9B,0x71
        };
        memcpy((char *)p->fmt + 24, pcm_guid, 16);
    }
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_device_period(void *args) {
    struct get_device_period_params *p = args;
    if (p->def_period) *p->def_period = 100000; /* 10 ms in 100ns units */
    if (p->min_period) *p->min_period = 50000;  /* 5 ms */
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_buffer_size(void *args) {
    struct get_buffer_size_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { if (p->frames) *p->frames = 0; p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    if (p->frames) *p->frames = s->buffer_frames ? s->buffer_frames
                                                       : IOS_AUDIO_BUFFER_FRAMES;
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_latency(void *args) {
    struct get_latency_params *p = args;
    if (p->latency) *p->latency = 100000; /* 10 ms */
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_current_padding(void *args) {
    LOG_FN_CALL(20, "get_current_padding");
    struct get_current_padding_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { if (p->padding) *p->padding = 0; p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    if (p->padding) {
        if (s->au) {
            uint64_t pad = atomic_load(&s->write_pos) - atomic_load(&s->play_pos);
            *p->padding = (UINT32)(pad > s->buffer_frames ? s->buffer_frames : pad);
        } else {
            *p->padding = 0; /* null-mode: always hungry */
        }
    }
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_next_packet_size(void *args) {
    struct get_next_packet_size_params *p = args;
    if (p->frames) *p->frames = 0;
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_frequency(void *args) {
    struct get_frequency_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { if (p->freq) *p->freq = 0; p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    /* Returns the device frequency in Hz — what units IAudioClock uses. */
    if (p->freq) *p->freq = s->sample_rate ? s->sample_rate : IOS_AUDIO_SAMPLE_RATE;
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_position(void *args) {
    LOG_FN_CALL(23, "get_position");
    struct get_position_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { if (p->pos) *p->pos = 0; p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    /* THIS is the function that drives FMOD's clock. Tier-2: frames the
     * RT callback actually consumed — the true hardware clock. Null-mode
     * fallback: wall-clock synthesis as before. */
    if (p->pos) {
        if (s->au)
            *p->pos = atomic_load(&s->play_pos);
        else
            *p->pos = elapsed_frames(s);
    }
    if (p->qpctime) *p->qpctime = mach_to_ns(mach_absolute_time()) / 100; /* 100ns ticks */
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_set_volumes(void *args) {
    (void)args;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_set_event_handle(void *args) {
    struct set_event_handle_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    if (s->event && s->event != p->event)
        fprintf(stderr, "[ios-astream] ml738 EVENT OVERWRITE gen=%u old=%p new=%p tid=%llx "
                        "-- the previous client will never be signalled again\n",
                g_stream_gen, s->event, p->event,
                (unsigned long long)ios_current_tid());
    else
        fprintf(stderr, "[ios-astream] ml738 EVENT set gen=%u handle=%p tid=%llx\n",
                g_stream_gen, p->event, (unsigned long long)ios_current_tid());
    s->event = p->event;
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_set_sample_rate(void *args) {
    struct set_sample_rate_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    if (p->rate > 0) s->sample_rate = (UINT32)p->rate;
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_test_connect(void *args) {
    LOG_FN_CALL(27, "test_connect");
    struct test_connect_params *p = args;
    p->priority = Priority_Preferred;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_is_started(void *args) {
    struct is_started_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    p->result = s->started ? S_OK : S_FALSE;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_prop_value(void *args) {
    struct get_prop_value_params *p = args;
    p->result = E_FAIL; /* property not supported — mmdevapi falls back */
    return STATUS_SUCCESS;
}

static NTSTATUS ios_midi_stub(void *args) {
    (void)args;
    return STATUS_SUCCESS;
}

/* Table indexed by enum unix_funcs in mmdevapi's unixlib.h (37 entries).
 * Order MUST match the enum exactly. */
const void *audio_null_ios_unix_call_funcs[] = {
    ios_process_attach,                /* process_attach */
    ios_process_detach,                /* process_detach */
    ios_main_loop,                     /* main_loop */
    ios_get_endpoint_ids,              /* get_endpoint_ids */
    ios_create_stream,                 /* create_stream */
    ios_release_stream,                /* release_stream */
    ios_start,                         /* start */
    ios_stop,                          /* stop */
    ios_reset,                         /* reset */
    ios_timer_loop,                    /* timer_loop */
    ios_get_render_buffer,             /* get_render_buffer */
    ios_release_render_buffer,         /* release_render_buffer */
    ios_get_capture_buffer,            /* get_capture_buffer */
    ios_release_capture_buffer,        /* release_capture_buffer */
    ios_is_format_supported,           /* is_format_supported */
    ios_get_loopback_capture_device,   /* get_loopback_capture_device */
    ios_get_mix_format,                /* get_mix_format */
    ios_get_device_period,             /* get_device_period */
    ios_get_buffer_size,               /* get_buffer_size */
    ios_get_latency,                   /* get_latency */
    ios_get_current_padding,           /* get_current_padding */
    ios_get_next_packet_size,          /* get_next_packet_size */
    ios_get_frequency,                 /* get_frequency */
    ios_get_position,                  /* get_position */
    ios_set_volumes,                   /* set_volumes */
    ios_set_event_handle,              /* set_event_handle */
    ios_set_sample_rate,               /* set_sample_rate */
    ios_test_connect,                  /* test_connect */
    ios_is_started,                    /* is_started */
    ios_get_prop_value,                /* get_prop_value */
    ios_midi_stub,                     /* midi_get_driver */
    ios_midi_stub,                     /* midi_init */
    ios_midi_stub,                     /* midi_release */
    ios_midi_stub,                     /* midi_out_message */
    ios_midi_stub,                     /* midi_in_message */
    ios_midi_stub,                     /* midi_notify_wait */
    ios_midi_stub,                     /* aux_message */
};

/* ================= MADEIRA: the 32-bit (WoW64) table =================
 *
 * WOW64_DESIGN.md 2/3 (invariant 2) and 7.10 item 1.  A 32-bit mmdevapi.dll
 * builds its argument blocks with 4-byte pointers and 4-byte HANDLEs, so the
 * table above would read every field after the first pointer at the wrong
 * offset.  `args` itself is already a HOST pointer -- the WoW64 module
 * converts that one outer pointer -- but every pointer EMBEDDED in the block
 * is still a GUEST address and needs + B before it is dereferenced, which is
 * what ios_wow_host_ptr() does (NULL-preserving); ios_wow_guest_ptr32()
 * writes one back.  Handles, stream handles, sizes, flags and enums are
 * never offset (invariant 4).
 *
 * Shape mirrors upstream's drivers (dlls/winecoreaudio.drv/coreaudio.c,
 * dlls/winealsa.drv/alsa.c): one thunk per call that carries a pointer, and
 * the 64-bit entry shared directly wherever the two layouts are identical
 * (a stream_handle is UINT64 and 8-byte aligned on i386 too) or the entry
 * ignores `args` entirely.  The ORDER is enum unix_funcs from
 * wine/dlls/mmdevapi/unixlib.h, the same order as the table above.
 *
 * Buffer contract: get_render_buffer is the only call that hands the client a
 * pointer, and its buffer is allocated inside the guest window by
 * ios_audio_alloc_scratch(); the thunk refuses to publish anything that is
 * not in the window.
 */

static NTSTATUS ios_wow64_main_loop(void *args)
{
    struct {
        PTR32 event;
    } *params32 = args;
    struct main_loop_params params = { .event = IOS_WOW_HANDLE(params32->event) };
    return ios_main_loop(&params);
}

static NTSTATUS ios_wow64_get_endpoint_ids(void *args)
{
    struct {
        EDataFlow flow;
        PTR32 endpoints;
        unsigned int size;
        HRESULT result;
        unsigned int num;
        unsigned int default_idx;
    } *params32 = args;
    struct get_endpoint_ids_params params = {
        .flow = params32->flow,
        /* the buffer mmdevapi allocated; endpoint.name/.device inside it are
         * byte OFFSETS, not pointers, so they need no conversion */
        .endpoints = ios_wow_host_ptr(params32->endpoints),
        .size = params32->size,
    };
    NTSTATUS status = ios_get_endpoint_ids(&params);
    params32->size = params.size;
    params32->result = params.result;
    params32->num = params.num;
    params32->default_idx = params.default_idx;
    return status;
}

static NTSTATUS ios_wow64_create_stream(void *args)
{
    struct {
        PTR32 name;
        PTR32 device;
        EDataFlow flow;
        int share;
        DWORD flags;
        REFERENCE_TIME duration;
        REFERENCE_TIME period;
        PTR32 fmt;
        HRESULT result;
        PTR32 channel_count;
        PTR32 stream;
    } *params32 = args;
    struct create_stream_params params = {
        .name = ios_wow_host_ptr(params32->name),
        .device = ios_wow_host_ptr(params32->device),
        .flow = params32->flow,
        .share = params32->share,
        .flags = params32->flags,
        .duration = params32->duration,
        .period = params32->period,
        .fmt = ios_wow_host_ptr(params32->fmt),
        .channel_count = ios_wow_host_ptr(params32->channel_count),
        /* *stream is a stream_handle (UINT64 in BOTH layouts) holding an
         * opaque driver handle -- never offset, never truncated */
        .stream = ios_wow_host_ptr(params32->stream),
    };
    NTSTATUS status = ios_create_stream(&params);
    params32->result = params.result;
    return status;
}

static NTSTATUS ios_wow64_release_stream(void *args)
{
    struct {
        stream_handle stream;
        PTR32 timer_thread;
        HRESULT result;
    } *params32 = args;
    struct release_stream_params params = {
        .stream = params32->stream,
        .timer_thread = IOS_WOW_HANDLE(params32->timer_thread),
    };
    NTSTATUS status = ios_release_stream(&params);
    params32->result = params.result;
    return status;
}

static NTSTATUS ios_wow64_get_render_buffer(void *args)
{
    struct {
        stream_handle stream;
        UINT32 frames;
        HRESULT result;
        PTR32 data;
    } *params32 = args;
    BYTE *data = NULL;
    struct get_render_buffer_params params = {
        .stream = params32->stream,
        .frames = params32->frames,
        .data = &data,
    };
    uint32_t *slot;
    NTSTATUS status = ios_get_render_buffer(&params);

    params32->result = params.result;
    if (!(slot = ios_wow_host_ptr(params32->data))) return status;
    /* WOW64_DESIGN.md 3 invariant 1: the client writes its samples straight
     * into this pointer, so it must be a guest address.  Anything else is a
     * bug in ios_audio_alloc_scratch(), not something to truncate and hope. */
    if (data && !ios_wow_in_window(data)) {
        static int moaned;
        if (moaned++ < 8)
            fprintf(stderr, "[ios_audio] WOW64 get_render_buffer: scratch %p is OUTSIDE the "
                            "guest window [%p, +4G) -- refusing to publish it to 32-bit code\n",
                    (void *)data, (void *)ios_wow_base());
        *slot = 0;
        params32->result = E_FAIL;
        return status;
    }
    *slot = ios_wow_guest_ptr32(data);
    return status;
}

static NTSTATUS ios_wow64_get_capture_buffer(void *args)
{
    struct {
        stream_handle stream;
        HRESULT result;
        PTR32 data;
        PTR32 frames;
        PTR32 flags;
        PTR32 devpos;
        PTR32 qpcpos;
    } *params32 = args;
    BYTE *data = NULL;
    struct get_capture_buffer_params params = {
        .stream = params32->stream,
        .data = &data,
        .frames = ios_wow_host_ptr(params32->frames),
        .flags = ios_wow_host_ptr(params32->flags),
        .devpos = ios_wow_host_ptr(params32->devpos),
        .qpcpos = ios_wow_host_ptr(params32->qpcpos),
    };
    uint32_t *slot;
    NTSTATUS status = ios_get_capture_buffer(&params);

    params32->result = params.result;
    /* this driver has no capture endpoint, so `data` is always NULL and
     * ios_wow_guest_ptr32() keeps it 0; the window check is the same
     * contract get_render_buffer enforces, should that ever change */
    if (!(slot = ios_wow_host_ptr(params32->data))) return status;
    if (data && !ios_wow_in_window(data)) {
        fprintf(stderr, "[ios_audio] WOW64 get_capture_buffer: buffer %p is OUTSIDE the "
                        "guest window -- refusing to publish it to 32-bit code\n", (void *)data);
        *slot = 0;
        params32->result = E_FAIL;
        return status;
    }
    *slot = ios_wow_guest_ptr32(data);
    return status;
}

static NTSTATUS ios_wow64_is_format_supported(void *args)
{
    struct {
        PTR32 device;
        EDataFlow flow;
        int share;
        PTR32 fmt_in;
        HRESULT result;
    } *params32 = args;
    struct is_format_supported_params params = {
        .device = ios_wow_host_ptr(params32->device),
        .flow = params32->flow,
        .share = params32->share,
        .fmt_in = ios_wow_host_ptr(params32->fmt_in),
    };
    NTSTATUS status = ios_is_format_supported(&params);
    params32->result = params.result;
    return status;
}

static NTSTATUS ios_wow64_get_loopback_capture_device(void *args)
{
    struct {
        PTR32 name;
        PTR32 device;
        PTR32 ret_device;
        UINT32 ret_device_len;
        HRESULT result;
    } *params32 = args;
    char *ret_device = ios_wow_host_ptr(params32->ret_device);
    struct get_loopback_capture_device_params params = {
        .name = ios_wow_host_ptr(params32->name),
        .device = ios_wow_host_ptr(params32->device),
        .ret_device = ret_device,
        .ret_device_len = params32->ret_device_len,
    };
    NTSTATUS status = ios_get_loopback_capture_device(&params);
    params32->result = params.result;
    return status;
}

static NTSTATUS ios_wow64_get_mix_format(void *args)
{
    struct {
        PTR32 device;
        EDataFlow flow;
        PTR32 fmt;
        HRESULT result;
    } *params32 = args;
    struct get_mix_format_params params = {
        .device = ios_wow_host_ptr(params32->device),
        .flow = params32->flow,
        /* WAVEFORMATEXTENSIBLE is fixed-width in both layouts */
        .fmt = ios_wow_host_ptr(params32->fmt),
    };
    NTSTATUS status = ios_get_mix_format(&params);
    params32->result = params.result;
    return status;
}

static NTSTATUS ios_wow64_get_device_period(void *args)
{
    struct {
        PTR32 device;
        EDataFlow flow;
        HRESULT result;
        PTR32 def_period;
        PTR32 min_period;
    } *params32 = args;
    struct get_device_period_params params = {
        .device = ios_wow_host_ptr(params32->device),
        .flow = params32->flow,
        .def_period = ios_wow_host_ptr(params32->def_period),
        .min_period = ios_wow_host_ptr(params32->min_period),
    };
    NTSTATUS status = ios_get_device_period(&params);
    params32->result = params.result;
    return status;
}

static NTSTATUS ios_wow64_get_buffer_size(void *args)
{
    struct {
        stream_handle stream;
        HRESULT result;
        PTR32 frames;
    } *params32 = args;
    struct get_buffer_size_params params = {
        .stream = params32->stream,
        .frames = ios_wow_host_ptr(params32->frames),
    };
    NTSTATUS status = ios_get_buffer_size(&params);
    params32->result = params.result;
    return status;
}

static NTSTATUS ios_wow64_get_latency(void *args)
{
    struct {
        stream_handle stream;
        HRESULT result;
        PTR32 latency;
    } *params32 = args;
    struct get_latency_params params = {
        .stream = params32->stream,
        .latency = ios_wow_host_ptr(params32->latency),
    };
    NTSTATUS status = ios_get_latency(&params);
    params32->result = params.result;
    return status;
}

static NTSTATUS ios_wow64_get_current_padding(void *args)
{
    struct {
        stream_handle stream;
        HRESULT result;
        PTR32 padding;
    } *params32 = args;
    struct get_current_padding_params params = {
        .stream = params32->stream,
        .padding = ios_wow_host_ptr(params32->padding),
    };
    NTSTATUS status = ios_get_current_padding(&params);
    params32->result = params.result;
    return status;
}

static NTSTATUS ios_wow64_get_next_packet_size(void *args)
{
    struct {
        stream_handle stream;
        HRESULT result;
        PTR32 frames;
    } *params32 = args;
    struct get_next_packet_size_params params = {
        .stream = params32->stream,
        .frames = ios_wow_host_ptr(params32->frames),
    };
    NTSTATUS status = ios_get_next_packet_size(&params);
    params32->result = params.result;
    return status;
}

static NTSTATUS ios_wow64_get_frequency(void *args)
{
    struct {
        stream_handle stream;
        HRESULT result;
        PTR32 freq;
    } *params32 = args;
    struct get_frequency_params params = {
        .stream = params32->stream,
        .freq = ios_wow_host_ptr(params32->freq),
    };
    NTSTATUS status = ios_get_frequency(&params);
    params32->result = params.result;
    return status;
}

static NTSTATUS ios_wow64_get_position(void *args)
{
    struct {
        stream_handle stream;
        BOOL device;
        HRESULT result;
        PTR32 pos;
        PTR32 qpctime;
    } *params32 = args;
    struct get_position_params params = {
        .stream = params32->stream,
        .device = params32->device,
        .pos = ios_wow_host_ptr(params32->pos),
        .qpctime = ios_wow_host_ptr(params32->qpctime),
    };
    NTSTATUS status = ios_get_position(&params);
    params32->result = params.result;
    return status;
}

static NTSTATUS ios_wow64_set_volumes(void *args)
{
    struct {
        stream_handle stream;
        float master_volume;
        PTR32 volumes;
        PTR32 session_volumes;
    } *params32 = args;
    struct set_volumes_params params = {
        .stream = params32->stream,
        .master_volume = params32->master_volume,
        .volumes = ios_wow_host_ptr(params32->volumes),
        .session_volumes = ios_wow_host_ptr(params32->session_volumes),
    };
    return ios_set_volumes(&params);
}

static NTSTATUS ios_wow64_set_event_handle(void *args)
{
    struct {
        stream_handle stream;
        PTR32 event;
        HRESULT result;
    } *params32 = args;
    struct set_event_handle_params params = {
        .stream = params32->stream,
        .event = IOS_WOW_HANDLE(params32->event),
    };
    NTSTATUS status = ios_set_event_handle(&params);
    params32->result = params.result;
    return status;
}

static NTSTATUS ios_wow64_test_connect(void *args)
{
    struct {
        PTR32 name;
        enum driver_priority priority;
    } *params32 = args;
    struct test_connect_params params = {
        .name = ios_wow_host_ptr(params32->name),
        .priority = params32->priority,
    };
    NTSTATUS status = ios_test_connect(&params);
    params32->priority = params.priority;
    return status;
}

static NTSTATUS ios_wow64_get_prop_value(void *args)
{
    struct {
        PTR32 device;
        EDataFlow flow;
        PTR32 guid;
        PTR32 prop;
        HRESULT result;
        PTR32 value;      /* PROPVARIANT, 32-bit layout */
        PTR32 buffer;
        PTR32 buffer_size;
    } *params32 = args;
    /* `value` is deliberately NOT forwarded: a 64-bit PROPVARIANT written into
     * the 32-bit slot would corrupt it, and this driver's get_prop_value is an
     * unconditional E_FAIL (mmdevapi falls back), so none is ever produced.
     * If that ever changes, say so instead of publishing a wrong struct. */
    struct get_prop_value_params params = {
        .device = ios_wow_host_ptr(params32->device),
        .flow = params32->flow,
        .guid = ios_wow_host_ptr(params32->guid),
        .prop = ios_wow_host_ptr(params32->prop),
        .value = NULL,
        .buffer = ios_wow_host_ptr(params32->buffer),
        .buffer_size = ios_wow_host_ptr(params32->buffer_size),
    };
    NTSTATUS status = ios_get_prop_value(&params);

    if (params.result >= 0) {
        fprintf(stderr, "[ios_audio] WOW64 get_prop_value succeeded but the 32-bit "
                        "PROPVARIANT copy-back is not implemented -- reporting E_FAIL\n");
        params32->result = (HRESULT)E_FAIL;
    }
    else params32->result = params.result;
    return status;
}

/* Table indexed by enum unix_funcs, same 37 slots and same order as
 * audio_null_ios_unix_call_funcs above.  Entries shared with the 64-bit table
 * either ignore `args` entirely or have a struct whose 32-bit and 64-bit
 * layouts are identical (stream_handle is UINT64 and 8-byte aligned in the
 * i386 MS ABI too, so { stream, UINT32..., HRESULT } lays out the same). */
const void *audio_null_ios_unix_call_wow64_funcs[] = {
    ios_process_attach,                /* process_attach  (args == NULL) */
    ios_process_detach,                /* process_detach  (args == NULL) */
    ios_wow64_main_loop,               /* main_loop */
    ios_wow64_get_endpoint_ids,        /* get_endpoint_ids */
    ios_wow64_create_stream,           /* create_stream */
    ios_wow64_release_stream,          /* release_stream */
    ios_start,                         /* start           { stream, result } */
    ios_stop,                          /* stop            { stream, result } */
    ios_reset,                         /* reset           { stream, result } */
    ios_timer_loop,                    /* timer_loop      { stream } */
    ios_wow64_get_render_buffer,       /* get_render_buffer */
    ios_release_render_buffer,         /* release_render_buffer (no pointers) */
    ios_wow64_get_capture_buffer,      /* get_capture_buffer */
    ios_release_capture_buffer,        /* release_capture_buffer (no pointers) */
    ios_wow64_is_format_supported,     /* is_format_supported */
    ios_wow64_get_loopback_capture_device, /* get_loopback_capture_device */
    ios_wow64_get_mix_format,          /* get_mix_format */
    ios_wow64_get_device_period,       /* get_device_period */
    ios_wow64_get_buffer_size,         /* get_buffer_size */
    ios_wow64_get_latency,             /* get_latency */
    ios_wow64_get_current_padding,     /* get_current_padding */
    ios_wow64_get_next_packet_size,    /* get_next_packet_size */
    ios_wow64_get_frequency,           /* get_frequency */
    ios_wow64_get_position,            /* get_position */
    ios_wow64_set_volumes,             /* set_volumes */
    ios_wow64_set_event_handle,        /* set_event_handle */
    ios_set_sample_rate,               /* set_sample_rate { stream, float, result } */
    ios_wow64_test_connect,            /* test_connect */
    ios_is_started,                    /* is_started      { stream, result } */
    ios_wow64_get_prop_value,          /* get_prop_value */
    ios_midi_stub,                     /* midi_get_driver (ignores args) */
    ios_midi_stub,                     /* midi_init */
    ios_midi_stub,                     /* midi_release */
    ios_midi_stub,                     /* midi_out_message */
    ios_midi_stub,                     /* midi_in_message */
    ios_midi_stub,                     /* midi_notify_wait */
    ios_midi_stub,                     /* aux_message */
};
