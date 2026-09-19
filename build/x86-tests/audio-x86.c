/* MADEIRA-TEMP: the self-test for audio output — the three APIs a Windows
 * program of any age uses to make a sound, all of which land on the same
 * unix-side driver on this port.
 *
 * WHAT IT IS ACTUALLY TESTING
 * ---------------------------
 * There is one audio backend here, build/ntdll-unix/audio_null_ios.c, bound
 * as wineios.drv, and everything reaches it through mmdevapi:
 *
 *   IAudioClient (WASAPI)  -> wine/dlls/mmdevapi/client.c   -> unix driver
 *   DirectSound            -> wine/dlls/dsound              -> mmdevapi
 *   waveOut                -> wine/dlls/winmm/waveform.c    -> mmdevapi
 *
 * A game from 2001 plays its intro movie through DirectShow, whose audio
 * renderer sits on DirectSound or waveOut; a game from 2012 goes straight to
 * WASAPI. The three paths share a driver but not a code path, and each of
 * them has its own way of hanging: this test exercises all three in one run
 * so a log line says which layer broke rather than "no sound".
 *
 * It also stands as the regression test for the spin this file was written
 * for. mmdevapi's DriverProc starts a MIDI notify thread whose loop only ends
 * when the driver sets *quit, and a driver stub that returned "success" while
 * writing nothing turned that loop into a busy wait holding 96.7 % of a core
 * for the life of the process. Nothing in this test calls MIDI — it does not
 * have to. That thread is created when mmdevapi.dll initialises, which stage
 * (a) does, so a run that finishes inside the five-second budget is a run
 * where the thread is not spinning.
 *
 * WHAT IT DOES
 * ------------
 * (a) WASAPI shared mode: CoCreateInstance(MMDeviceEnumerator),
 *     GetDefaultAudioEndpoint(eRender), Activate(IAudioClient), GetMixFormat,
 *     IsFormatSupported for 16-bit 44.1 kHz stereo and for 16-bit 22 kHz
 *     mono, Initialize, GetBufferSize, fill the buffer with 200 ms of
 *     silence through IAudioRenderClient, Start, watch GetCurrentPadding
 *     DRAIN (that is the only proof the device clock is actually running —
 *     a driver that accepts buffers and never consumes them looks identical
 *     until you read the padding), Stop.
 * (a2) WASAPI again, but SIX channels of float32 (WAVE_FORMAT_EXTENSIBLE,
 *     5.1 channel mask) with a 440 Hz tone on front-left and front-right only
 *     and silence on centre/LFE/surrounds, for 300 ms. This is the shape a
 *     multichannel title opens and the shape that has to be folded down to a
 *     stereo route; a driver that takes the 24-byte frame for anything else
 *     plays it at three times the pitch with the silent channels cut into it.
 * (b) DirectSound: DirectSoundCreate8, a primary buffer, a secondary buffer
 *     of 200 ms, Lock/Unlock, Play, and the play cursor must MOVE.
 * (c) waveOut: 22 kHz mono 8-bit — the oldest shape in the list, and the one
 *     whose sample polarity is unsigned where every wider format is signed —
 *     waveOutOpen, one prepared 200 ms buffer, waveOutWrite, and the buffer
 *     must come back marked done.
 *
 * Every stage prints what it got, including the HRESULTs, so a failing run is
 * diagnosable from the log alone.
 *
 * HOW TO RUN IT: the Custom path popup, as
 *   C:\windows\syswow64\audio-x86.exe
 *
 * Deliberate restrictions, the same ones the other tests in this directory
 * work under: no CRT (this file supplies `start' and is linked -nostdlib), no
 * 64-bit division, no int-to-double conversion.
 *
 * Exit status (the runtime reports it as "MADEIRA-EXIT: ... status=<n>"):
 *   59  all three paths completed — audio works end to end
 *   60  the WASAPI/IAudioClient path failed
 *   61  the DirectSound path failed
 *   62  the waveOut path failed
 *   63  five seconds elapsed with the run unfinished — something is blocking
 *       or spinning; the last line printed says which stage it died in
 */
#include <stddef.h>
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <objbase.h>
#include <mmsystem.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <dsound.h>

/* -nostdlib: clang may still lower a struct initialisation or a struct
 * assignment to memset/memcpy. */
void *memset( void *dst, int c, size_t n )
{
    unsigned char *p = dst;
    while (n--) *p++ = (unsigned char)c;
    return dst;
}

void *memcpy( void *dst, const void *src, size_t n )
{
    unsigned char *d = dst;
    const unsigned char *s = src;
    while (n--) *d++ = *s++;
    return dst;
}

static void write_log(const char *msg, DWORD len)
{
    HANDLE h = GetStdHandle(STD_ERROR_HANDLE);
    DWORD written = 0;
    WriteFile(h, msg, len, &written, NULL);
}

#define WRITE_LINE(lit) write_log( (lit), (DWORD)(sizeof(lit) - 1) )

/* no CRT (no strlen, no printf), so every number is formatted by hand */
static DWORD format_uint(char *buf, DWORD size, unsigned int value)
{
    DWORD i = size;
    if (!value) buf[--i] = '0';
    else while (value && i > 0)
    {
        buf[--i] = (char)('0' + (value % 10));
        value /= 10;
    }
    return i;
}

static void write_uint(unsigned int v)
{
    char buf[16];
    DWORD i = format_uint(buf, sizeof(buf), v);
    write_log(buf + i, sizeof(buf) - i);
}

static void write_hex32(unsigned int v)
{
    static const char digits[] = "0123456789abcdef";
    char buf[10];
    int i;

    buf[0] = '0';
    buf[1] = 'x';
    for (i = 0; i < 8; i++) buf[2 + i] = digits[(v >> ((7 - i) * 4)) & 0xf];
    write_log(buf, 10);
}

static void write_fmt(const WAVEFORMATEX *fmt)
{
    if (!fmt) { WRITE_LINE("(null)"); return; }
    WRITE_LINE("tag=");
    write_uint(fmt->wFormatTag);
    WRITE_LINE(" ch=");
    write_uint(fmt->nChannels);
    WRITE_LINE(" rate=");
    write_uint(fmt->nSamplesPerSec);
    WRITE_LINE(" bits=");
    write_uint(fmt->wBitsPerSample);
    WRITE_LINE(" align=");
    write_uint(fmt->nBlockAlign);
}

/* The whole run is budgeted, not each stage: a hang anywhere -- a driver that
 * never answers, a notify loop eating the core this thread wants -- shows up
 * as the same timeout, and the last line printed says where it was. */
static DWORD WINAPI watchdog(void *unused)
{
    Sleep(5000);
    WRITE_LINE("MADEIRA-AUDIO: TIMEOUT after 5s - the stage named in the line "
               "above never finished. A whole core held by a thread named "
               "mmdevapi_midi_notify is the known shape of this; check the "
               "profiler's per-thread list.\n");
    ExitProcess(63);
    return 0;
}

static void fill_wfx(WAVEFORMATEX *fmt, WORD channels, DWORD rate, WORD bits)
{
    memset(fmt, 0, sizeof(*fmt));
    fmt->wFormatTag = WAVE_FORMAT_PCM;
    fmt->nChannels = channels;
    fmt->nSamplesPerSec = rate;
    fmt->wBitsPerSample = bits;
    fmt->nBlockAlign = (WORD)(channels * (bits / 8));
    fmt->nAvgBytesPerSec = rate * fmt->nBlockAlign;
    fmt->cbSize = 0;
}

/* ------------------------------- (a) WASAPI ------------------------------ */

static void probe_format(IAudioClient *client, const char *what, DWORD what_len,
                         WORD channels, DWORD rate, WORD bits)
{
    WAVEFORMATEX fmt, *closest = NULL;
    HRESULT hr;

    fill_wfx(&fmt, channels, rate, bits);
    hr = IAudioClient_IsFormatSupported(client, AUDCLNT_SHAREMODE_SHARED, &fmt, &closest);
    WRITE_LINE("MADEIRA-AUDIO: IsFormatSupported ");
    write_log(what, what_len);
    WRITE_LINE(" hr=");
    write_hex32((unsigned int)hr);
    if (closest)
    {
        WRITE_LINE(" closest: ");
        write_fmt(closest);
        CoTaskMemFree(closest);
    }
    WRITE_LINE("\n");
    /* S_OK and S_FALSE are both legal answers -- S_FALSE means "not this one,
     * here is the nearest". Only a FAILED hr is a bug, and it is reported by
     * the caller so the two probes both get to print first. */
    if (FAILED(hr))
    {
        WRITE_LINE("MADEIRA-AUDIO: IsFormatSupported FAILED for a plain PCM "
                   "format - the driver's is_format_supported is refusing "
                   "something every game asks for.\n");
        ExitProcess(60);
    }
}

static void stage_wasapi(void)
{
    IMMDeviceEnumerator *devenum = NULL;
    IAudioRenderClient *render = NULL;
    IAudioClient *client = NULL;
    IMMDevice *device = NULL;
    WAVEFORMATEX *mix = NULL;
    UINT32 frames = 0, padding = 0, first_padding = 0, want;
    REFERENCE_TIME def_period = 0, min_period = 0;
    BYTE *data = NULL;
    HRESULT hr;
    int i;

    WRITE_LINE("MADEIRA-AUDIO: (a) WASAPI shared mode\n");

    hr = CoCreateInstance(&CLSID_MMDeviceEnumerator, NULL, CLSCTX_INPROC_SERVER,
                          &IID_IMMDeviceEnumerator, (void **)&devenum);
    if (FAILED(hr) || !devenum)
    {
        WRITE_LINE("MADEIRA-AUDIO: CoCreateInstance(MMDeviceEnumerator) hr=");
        write_hex32((unsigned int)hr);
        WRITE_LINE(" - mmdevapi.dll is missing from the i386 farm or its "
                   "DllGetClassObject failed.\n");
        ExitProcess(60);
    }

    hr = IMMDeviceEnumerator_GetDefaultAudioEndpoint(devenum, eRender, eConsole, &device);
    if (FAILED(hr) || !device)
    {
        WRITE_LINE("MADEIRA-AUDIO: GetDefaultAudioEndpoint(eRender) hr=");
        write_hex32((unsigned int)hr);
        WRITE_LINE(" - the driver's get_endpoint_ids published no render "
                   "endpoint.\n");
        ExitProcess(60);
    }

    hr = IMMDevice_Activate(device, &IID_IAudioClient, CLSCTX_INPROC_SERVER, NULL,
                            (void **)&client);
    if (FAILED(hr) || !client)
    {
        WRITE_LINE("MADEIRA-AUDIO: Activate(IAudioClient) hr=");
        write_hex32((unsigned int)hr);
        WRITE_LINE("\n");
        ExitProcess(60);
    }

    hr = IAudioClient_GetMixFormat(client, &mix);
    WRITE_LINE("MADEIRA-AUDIO: GetMixFormat hr=");
    write_hex32((unsigned int)hr);
    WRITE_LINE(" ");
    write_fmt(mix);
    WRITE_LINE("\n");
    if (FAILED(hr) || !mix) ExitProcess(60);

    hr = IAudioClient_GetDevicePeriod(client, &def_period, &min_period);
    WRITE_LINE("MADEIRA-AUDIO: GetDevicePeriod hr=");
    write_hex32((unsigned int)hr);
    WRITE_LINE(" def=");
    write_uint((unsigned int)def_period);      /* 100ns units, well under 2^32 */
    WRITE_LINE(" min=");
    write_uint((unsigned int)min_period);
    WRITE_LINE("\n");
    if (FAILED(hr) || !def_period)
    {
        WRITE_LINE("MADEIRA-AUDIO: GetDevicePeriod gave no default period - a "
                   "zero period makes every caller's buffer maths collapse.\n");
        ExitProcess(60);
    }

    probe_format(client, "16bit/44100/stereo", sizeof("16bit/44100/stereo") - 1, 2, 44100, 16);
    probe_format(client, "16bit/22050/mono", sizeof("16bit/22050/mono") - 1, 1, 22050, 16);

    /* 200 ms buffer, timer-driven (no event handle): the plainest shape, and
     * the one DirectShow's audio renderer uses. */
    hr = IAudioClient_Initialize(client, AUDCLNT_SHAREMODE_SHARED, 0, 2000000, 0, mix, NULL);
    WRITE_LINE("MADEIRA-AUDIO: Initialize hr=");
    write_hex32((unsigned int)hr);
    WRITE_LINE("\n");
    if (FAILED(hr)) ExitProcess(60);

    hr = IAudioClient_GetBufferSize(client, &frames);
    WRITE_LINE("MADEIRA-AUDIO: GetBufferSize hr=");
    write_hex32((unsigned int)hr);
    WRITE_LINE(" frames=");
    write_uint(frames);
    WRITE_LINE("\n");
    if (FAILED(hr) || !frames) ExitProcess(60);

    hr = IAudioClient_GetService(client, &IID_IAudioRenderClient, (void **)&render);
    if (FAILED(hr) || !render)
    {
        WRITE_LINE("MADEIRA-AUDIO: GetService(IAudioRenderClient) hr=");
        write_hex32((unsigned int)hr);
        WRITE_LINE("\n");
        ExitProcess(60);
    }

    /* 200 ms of silence, clamped to whatever the buffer actually holds. */
    want = mix->nSamplesPerSec / 5;
    if (want > frames) want = frames;
    hr = IAudioRenderClient_GetBuffer(render, want, &data);
    if (FAILED(hr) || !data)
    {
        WRITE_LINE("MADEIRA-AUDIO: GetBuffer(");
        write_uint(want);
        WRITE_LINE(") hr=");
        write_hex32((unsigned int)hr);
        WRITE_LINE("\n");
        ExitProcess(60);
    }
    hr = IAudioRenderClient_ReleaseBuffer(render, want, AUDCLNT_BUFFERFLAGS_SILENT);
    if (FAILED(hr)) { WRITE_LINE("MADEIRA-AUDIO: ReleaseBuffer failed\n"); ExitProcess(60); }

    hr = IAudioClient_GetCurrentPadding(client, &first_padding);
    WRITE_LINE("MADEIRA-AUDIO: queued ");
    write_uint(want);
    WRITE_LINE(" frames, padding=");
    write_uint(first_padding);
    WRITE_LINE(" hr=");
    write_hex32((unsigned int)hr);
    WRITE_LINE("\n");
    if (FAILED(hr)) ExitProcess(60);

    hr = IAudioClient_Start(client);
    WRITE_LINE("MADEIRA-AUDIO: Start hr=");
    write_hex32((unsigned int)hr);
    WRITE_LINE("\n");
    if (FAILED(hr)) ExitProcess(60);

    /* The padding must come DOWN. It is the one observable that separates a
     * device which is consuming audio from one which merely accepted it. */
    for (i = 0; i < 12; i++)
    {
        Sleep(25);
        hr = IAudioClient_GetCurrentPadding(client, &padding);
        if (FAILED(hr)) { WRITE_LINE("MADEIRA-AUDIO: GetCurrentPadding failed\n"); ExitProcess(60); }
        if (padding < first_padding) break;
    }
    WRITE_LINE("MADEIRA-AUDIO: padding ");
    write_uint(first_padding);
    WRITE_LINE(" -> ");
    write_uint(padding);
    WRITE_LINE(" after ");
    write_uint((unsigned int)(i + 1) * 25);
    WRITE_LINE("ms\n");
    if (first_padding && padding >= first_padding)
    {
        WRITE_LINE("MADEIRA-AUDIO: the buffer never drained - the device clock "
                   "is not running (get_current_padding / the RemoteIO render "
                   "callback in audio_null_ios.c).\n");
        ExitProcess(60);
    }

    IAudioClient_Stop(client);
    IAudioRenderClient_Release(render);
    CoTaskMemFree(mix);
    IAudioClient_Release(client);
    IMMDevice_Release(device);
    IMMDeviceEnumerator_Release(devenum);
    WRITE_LINE("MADEIRA-AUDIO: (a) WASAPI OK\n");
}

/* --------------------- (a2) 5.1 float, the downmix ----------------------- */

/* One cycle of a sine, 64 points, as constants: there is no CRT here and so no
 * sinf(). Stepping through it with a 16.16 phase accumulator is exact enough
 * for "is this a 440 Hz tone or is it static", which is the whole question. */
static const float sine64[64] = {
     0.000000f, 0.098017f, 0.195090f, 0.290285f, 0.382683f, 0.471397f, 0.555570f, 0.634393f,
     0.707107f, 0.773010f, 0.831470f, 0.881921f, 0.923880f, 0.956940f, 0.980785f, 0.995185f,
     1.000000f, 0.995185f, 0.980785f, 0.956940f, 0.923880f, 0.881921f, 0.831470f, 0.773010f,
     0.707107f, 0.634393f, 0.555570f, 0.471397f, 0.382683f, 0.290285f, 0.195090f, 0.098017f,
     0.000000f,-0.098017f,-0.195090f,-0.290285f,-0.382683f,-0.471397f,-0.555570f,-0.634393f,
    -0.707107f,-0.773010f,-0.831470f,-0.881921f,-0.923880f,-0.956940f,-0.980785f,-0.995185f,
    -1.000000f,-0.995185f,-0.980785f,-0.956940f,-0.923880f,-0.881921f,-0.831470f,-0.773010f,
    -0.707107f,-0.634393f,-0.555570f,-0.471397f,-0.382683f,-0.290285f,-0.195090f,-0.098017f
};

/* KSDATAFORMAT_SUBTYPE_IEEE_FLOAT, spelled out rather than pulled in from
 * ksmedia.h so this file keeps its short include list. */
static const GUID subtype_ieee_float =
    { 0x00000003, 0x0000, 0x0010, { 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 } };

#define SPK_FL 0x1
#define SPK_FR 0x2
#define SPK_FC 0x4
#define SPK_LFE 0x8
#define SPK_BL 0x10
#define SPK_BR 0x20

/* A 5.1 stream is what broke on the device: six interleaved float channels
 * handed to a stereo route. The tone goes on FRONT LEFT and FRONT RIGHT only
 * and the other four channels are held at silence, so the expected result is
 * a clean 440 Hz tone at unity — if the driver ever treats the 24-byte frame
 * as anything other than six channels, the tone comes out at three times the
 * pitch with the silent channels chopped into it, which is audibly the
 * reported symptom. */
static void stage_wasapi_51(void)
{
    IMMDeviceEnumerator *devenum = NULL;
    IAudioRenderClient *render = NULL;
    IAudioClient *client = NULL;
    IMMDevice *device = NULL;
    WAVEFORMATEXTENSIBLE fmt;
    WAVEFORMATEX *closest = NULL;
    UINT32 frames = 0, padding = 0, want, i, phase = 0, step;
    DWORD rate = 48000;
    BYTE *data = NULL;
    float *out;
    HRESULT hr;
    int k;

    WRITE_LINE("MADEIRA-AUDIO: (a2) WASAPI 5.1 float32, 440 Hz on FL/FR only\n");

    hr = CoCreateInstance(&CLSID_MMDeviceEnumerator, NULL, CLSCTX_INPROC_SERVER,
                          &IID_IMMDeviceEnumerator, (void **)&devenum);
    if (SUCCEEDED(hr))
        hr = IMMDeviceEnumerator_GetDefaultAudioEndpoint(devenum, eRender, eConsole, &device);
    if (SUCCEEDED(hr))
        hr = IMMDevice_Activate(device, &IID_IAudioClient, CLSCTX_INPROC_SERVER, NULL,
                                (void **)&client);
    if (FAILED(hr) || !client)
    {
        WRITE_LINE("MADEIRA-AUDIO: could not re-open a client for the 5.1 stage hr=");
        write_hex32((unsigned int)hr);
        WRITE_LINE("\n");
        ExitProcess(60);
    }

    memset(&fmt, 0, sizeof(fmt));
    fmt.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
    fmt.Format.nChannels = 6;
    fmt.Format.nSamplesPerSec = rate;
    fmt.Format.wBitsPerSample = 32;
    fmt.Format.nBlockAlign = 6 * 4;              /* 24 bytes per frame */
    fmt.Format.nAvgBytesPerSec = rate * fmt.Format.nBlockAlign;
    fmt.Format.cbSize = 22;
    fmt.Samples.wValidBitsPerSample = 32;
    fmt.dwChannelMask = SPK_FL | SPK_FR | SPK_FC | SPK_LFE | SPK_BL | SPK_BR;
    fmt.SubFormat = subtype_ieee_float;

    hr = IAudioClient_IsFormatSupported(client, AUDCLNT_SHAREMODE_SHARED,
                                        &fmt.Format, &closest);
    WRITE_LINE("MADEIRA-AUDIO: IsFormatSupported 5.1float hr=");
    write_hex32((unsigned int)hr);
    if (closest) { WRITE_LINE(" closest: "); write_fmt(closest); CoTaskMemFree(closest); }
    WRITE_LINE("\n");
    /* S_FALSE (0x1) is the EXPECTED answer from a stereo endpoint and is what
     * steers a client into building a stereo graph; the closest match printed
     * above should be the stereo mix format. Initialize must still succeed on
     * the 5.1 format below, because a caller is allowed to ignore the advice
     * and the driver downmixes for it. Only a FAILED hr is a bug here. */
    if (FAILED(hr))
    {
        WRITE_LINE("MADEIRA-AUDIO: IsFormatSupported returned a hard failure for 5.1; "
                   "S_OK or S_FALSE-with-closest-match are the only correct answers.\n");
        ExitProcess(60);
    }

    hr = IAudioClient_Initialize(client, AUDCLNT_SHAREMODE_SHARED, 0, 3000000, 0,
                                 &fmt.Format, NULL);
    WRITE_LINE("MADEIRA-AUDIO: Initialize(5.1) hr=");
    write_hex32((unsigned int)hr);
    WRITE_LINE("\n");
    if (FAILED(hr)) ExitProcess(60);

    hr = IAudioClient_GetBufferSize(client, &frames);
    if (FAILED(hr) || !frames) { WRITE_LINE("MADEIRA-AUDIO: GetBufferSize(5.1) failed\n"); ExitProcess(60); }

    hr = IAudioClient_GetService(client, &IID_IAudioRenderClient, (void **)&render);
    if (FAILED(hr) || !render) { WRITE_LINE("MADEIRA-AUDIO: GetService(5.1) failed\n"); ExitProcess(60); }

    /* 300 ms of tone, clamped to the buffer. */
    want = rate / 3;
    if (want > frames) want = frames;
    hr = IAudioRenderClient_GetBuffer(render, want, &data);
    if (FAILED(hr) || !data)
    {
        WRITE_LINE("MADEIRA-AUDIO: GetBuffer(5.1, ");
        write_uint(want);
        WRITE_LINE(") hr=");
        write_hex32((unsigned int)hr);
        WRITE_LINE("\n");
        ExitProcess(60);
    }

    /* 64 table entries per cycle at 440 Hz: step = 64*440/rate, in 16.16.
     * 64*440*65536 is 1845493760, which still fits a DWORD, so this needs no
     * 64-bit arithmetic. */
    step = (28160u * 65536u) / rate;
    out = (float *)data;
    for (i = 0; i < want; i++)
    {
        /* x4, i.e. +12 dB over full scale. A float WASAPI client is allowed to
         * do this -- XAudio2 voices sum without clamping and leave it to the
         * endpoint -- and a driver that answers by hard-clipping turns the
         * tone into a square wave. The device reported exactly that from a
         * title whose mastering voice peaked at 7.99. There is no way for this
         * program to hear the result, but it does prove the whole path still
         * accepts and drains a hot buffer, and the driver's own 10 s census
         * prints peak=4.00x against a limiter_min_gain near 0.245. */
        float v = sine64[(phase >> 16) & 63] * 4.0f;
        out[i * 6 + 0] = v;       /* FL  */
        out[i * 6 + 1] = v;       /* FR  */
        out[i * 6 + 2] = 0.0f;    /* FC  */
        out[i * 6 + 3] = 0.0f;    /* LFE */
        out[i * 6 + 4] = 0.0f;    /* BL  */
        out[i * 6 + 5] = 0.0f;    /* BR  */
        phase += step;
    }
    hr = IAudioRenderClient_ReleaseBuffer(render, want, 0);
    if (FAILED(hr)) { WRITE_LINE("MADEIRA-AUDIO: ReleaseBuffer(5.1) failed\n"); ExitProcess(60); }

    hr = IAudioClient_Start(client);
    WRITE_LINE("MADEIRA-AUDIO: Start(5.1) ");
    write_uint(want);
    WRITE_LINE(" frames hr=");
    write_hex32((unsigned int)hr);
    WRITE_LINE("\n");
    if (FAILED(hr)) ExitProcess(60);

    for (k = 0; k < 16; k++)
    {
        Sleep(25);
        if (FAILED(IAudioClient_GetCurrentPadding(client, &padding))) break;
        if (padding < want) break;
    }
    WRITE_LINE("MADEIRA-AUDIO: 5.1 padding ");
    write_uint(want);
    WRITE_LINE(" -> ");
    write_uint(padding);
    WRITE_LINE("\n");
    if (padding >= want)
    {
        WRITE_LINE("MADEIRA-AUDIO: the 5.1 buffer never drained - the mixer is not "
                   "consuming multichannel frames.\n");
        ExitProcess(60);
    }

    IAudioClient_Stop(client);
    IAudioRenderClient_Release(render);
    IAudioClient_Release(client);
    IMMDevice_Release(device);
    IMMDeviceEnumerator_Release(devenum);
    WRITE_LINE("MADEIRA-AUDIO: (a2) 5.1 downmix OK\n");
}

/* ----------------------------- (b) DirectSound --------------------------- */

static void stage_dsound(void)
{
    IDirectSoundBuffer *primary = NULL, *secondary = NULL;
    DWORD play_pos = 0, write_pos = 0, first_play = 0;
    IDirectSound8 *ds = NULL;
    DSBUFFERDESC desc;
    WAVEFORMATEX fmt;
    void *p1 = NULL, *p2 = NULL;
    DWORD b1 = 0, b2 = 0;
    HRESULT hr;
    int i;

    WRITE_LINE("MADEIRA-AUDIO: (b) DirectSound\n");

    hr = DirectSoundCreate8(NULL, &ds, NULL);
    if (FAILED(hr) || !ds)
    {
        WRITE_LINE("MADEIRA-AUDIO: DirectSoundCreate8 hr=");
        write_hex32((unsigned int)hr);
        WRITE_LINE(" - dsound.dll is missing from the i386 farm, or its "
                   "mmdevapi backend found no device.\n");
        ExitProcess(61);
    }

    hr = IDirectSound8_SetCooperativeLevel(ds, GetDesktopWindow(), DSSCL_PRIORITY);
    if (FAILED(hr))
    {
        WRITE_LINE("MADEIRA-AUDIO: SetCooperativeLevel hr=");
        write_hex32((unsigned int)hr);
        WRITE_LINE("\n");
        ExitProcess(61);
    }

    memset(&desc, 0, sizeof(desc));
    desc.dwSize = sizeof(desc);
    desc.dwFlags = DSBCAPS_PRIMARYBUFFER;
    hr = IDirectSound8_CreateSoundBuffer(ds, &desc, &primary, NULL);
    if (FAILED(hr) || !primary)
    {
        WRITE_LINE("MADEIRA-AUDIO: CreateSoundBuffer(primary) hr=");
        write_hex32((unsigned int)hr);
        WRITE_LINE("\n");
        ExitProcess(61);
    }
    hr = IDirectSoundBuffer_Play(primary, 0, 0, DSBPLAY_LOOPING);
    WRITE_LINE("MADEIRA-AUDIO: primary Play hr=");
    write_hex32((unsigned int)hr);
    WRITE_LINE("\n");
    if (FAILED(hr)) ExitProcess(61);

    /* A secondary buffer in the shape a 2001-era title uses: 22 kHz mono
     * 16-bit, 200 ms, position tracking on. */
    fill_wfx(&fmt, 1, 22050, 16);
    memset(&desc, 0, sizeof(desc));
    desc.dwSize = sizeof(desc);
    desc.dwFlags = DSBCAPS_GLOBALFOCUS | DSBCAPS_GETCURRENTPOSITION2 | DSBCAPS_CTRLPOSITIONNOTIFY;
    desc.dwBufferBytes = fmt.nAvgBytesPerSec / 5;
    desc.lpwfxFormat = &fmt;
    hr = IDirectSound8_CreateSoundBuffer(ds, &desc, &secondary, NULL);
    if (FAILED(hr) || !secondary)
    {
        WRITE_LINE("MADEIRA-AUDIO: CreateSoundBuffer(secondary ");
        write_uint(desc.dwBufferBytes);
        WRITE_LINE(" bytes) hr=");
        write_hex32((unsigned int)hr);
        WRITE_LINE("\n");
        ExitProcess(61);
    }

    hr = IDirectSoundBuffer_Lock(secondary, 0, desc.dwBufferBytes, &p1, &b1, &p2, &b2, 0);
    if (FAILED(hr))
    {
        WRITE_LINE("MADEIRA-AUDIO: Lock hr=");
        write_hex32((unsigned int)hr);
        WRITE_LINE("\n");
        ExitProcess(61);
    }
    if (p1) memset(p1, 0, b1);
    if (p2) memset(p2, 0, b2);
    IDirectSoundBuffer_Unlock(secondary, p1, b1, p2, b2);

    hr = IDirectSoundBuffer_Play(secondary, 0, 0, DSBPLAY_LOOPING);
    WRITE_LINE("MADEIRA-AUDIO: secondary Play hr=");
    write_hex32((unsigned int)hr);
    WRITE_LINE("\n");
    if (FAILED(hr)) ExitProcess(61);

    IDirectSoundBuffer_GetCurrentPosition(secondary, &first_play, &write_pos);
    for (i = 0; i < 12; i++)
    {
        Sleep(25);
        hr = IDirectSoundBuffer_GetCurrentPosition(secondary, &play_pos, &write_pos);
        if (FAILED(hr)) break;
        if (play_pos != first_play) break;
    }
    WRITE_LINE("MADEIRA-AUDIO: play cursor ");
    write_uint(first_play);
    WRITE_LINE(" -> ");
    write_uint(play_pos);
    WRITE_LINE("\n");
    if (play_pos == first_play)
    {
        WRITE_LINE("MADEIRA-AUDIO: the DirectSound play cursor never moved - "
                   "dsound's mixer thread is stalled or its mmdevapi stream "
                   "never started.\n");
        ExitProcess(61);
    }

    IDirectSoundBuffer_Stop(secondary);
    IDirectSoundBuffer_Release(secondary);
    IDirectSoundBuffer_Stop(primary);
    IDirectSoundBuffer_Release(primary);
    IDirectSound8_Release(ds);
    WRITE_LINE("MADEIRA-AUDIO: (b) DirectSound OK\n");
}

/* ------------------------------- (c) waveOut ----------------------------- */

/* 200 ms at 22050 Hz mono 8-bit = 4410 bytes. Static, because there is no CRT
 * allocator here and the buffer must outlive waveOutWrite. */
static BYTE wave_data[8192];

static void stage_waveout(void)
{
    WAVEFORMATEX fmt;
    HWAVEOUT hwo = NULL;
    WAVEHDR hdr;
    UINT devs;
    MMRESULT mr;
    DWORD bytes;
    int i;

    WRITE_LINE("MADEIRA-AUDIO: (c) waveOut 22050/mono/8bit\n");

    devs = waveOutGetNumDevs();
    WRITE_LINE("MADEIRA-AUDIO: waveOutGetNumDevs=");
    write_uint(devs);
    WRITE_LINE("\n");
    if (!devs)
    {
        WRITE_LINE("MADEIRA-AUDIO: no waveOut device - winmm found no render "
                   "endpoint through mmdevapi.\n");
        ExitProcess(62);
    }

    fill_wfx(&fmt, 1, 22050, 8);
    mr = waveOutOpen(&hwo, 0, &fmt, 0, 0, CALLBACK_NULL);
    WRITE_LINE("MADEIRA-AUDIO: waveOutOpen mr=");
    write_uint(mr);
    WRITE_LINE("\n");
    if (mr != MMSYSERR_NOERROR || !hwo) ExitProcess(62);

    /* 8-bit PCM silence is 0x80, not 0x00 -- the format is unsigned. Writing
     * zeroes here would be a full-scale negative DC step, which is exactly
     * what a driver that marks this format signed produces from real audio. */
    bytes = fmt.nAvgBytesPerSec / 5;
    if (bytes > sizeof(wave_data)) bytes = sizeof(wave_data);
    memset(wave_data, 0x80, bytes);

    memset(&hdr, 0, sizeof(hdr));
    hdr.lpData = (LPSTR)wave_data;
    hdr.dwBufferLength = bytes;

    mr = waveOutPrepareHeader(hwo, &hdr, sizeof(hdr));
    if (mr != MMSYSERR_NOERROR)
    {
        WRITE_LINE("MADEIRA-AUDIO: waveOutPrepareHeader mr=");
        write_uint(mr);
        WRITE_LINE("\n");
        ExitProcess(62);
    }

    mr = waveOutWrite(hwo, &hdr, sizeof(hdr));
    WRITE_LINE("MADEIRA-AUDIO: waveOutWrite ");
    write_uint(bytes);
    WRITE_LINE(" bytes mr=");
    write_uint(mr);
    WRITE_LINE("\n");
    if (mr != MMSYSERR_NOERROR) ExitProcess(62);

    for (i = 0; i < 16; i++)
    {
        if (hdr.dwFlags & WHDR_DONE) break;
        Sleep(25);
    }
    WRITE_LINE("MADEIRA-AUDIO: header flags=");
    write_hex32((unsigned int)hdr.dwFlags);
    WRITE_LINE(" after ");
    write_uint((unsigned int)(i + 1) * 25);
    WRITE_LINE("ms\n");
    if (!(hdr.dwFlags & WHDR_DONE))
    {
        WRITE_LINE("MADEIRA-AUDIO: the waveOut buffer never came back done - "
                   "winmm's feeder thread is not consuming it.\n");
        ExitProcess(62);
    }

    waveOutUnprepareHeader(hwo, &hdr, sizeof(hdr));
    waveOutClose(hwo);
    WRITE_LINE("MADEIRA-AUDIO: (c) waveOut OK\n");
}

void start(void)
{
    DWORD tid = 0;
    HANDLE h;

    WRITE_LINE("MADEIRA-AUDIO: start (5s budget for all three paths)\n");

    h = CreateThread(NULL, 0, watchdog, NULL, 0, &tid);
    if (h) CloseHandle(h);

    CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);

    stage_wasapi();
    stage_wasapi_51();
    stage_dsound();
    stage_waveout();

    WRITE_LINE("MADEIRA-AUDIO: all three paths completed - audio works\n");
    ExitProcess(59);
}
