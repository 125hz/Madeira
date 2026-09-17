/* MADEIRA-TEMP: the self-test for the D3D9 adapter's CAPABILITY and FORMAT
 * answers -- what CheckDeviceType / CheckDeviceFormat / CheckDepthStencilMatch
 * / CheckDeviceMultiSampleType / CheckDeviceFormatConversion / GetDeviceCaps /
 * GetAdapterIdentifier tell an application before it creates anything.
 *
 * WHY THIS TEST EXISTS
 * --------------------
 * d3d9modes-x86.exe proves the adapter's MODE TABLE is real and that a
 * fullscreen device can be created from it. It says nothing about the far
 * larger surface a title of the 2000-2010 era actually gates on, which is the
 * capability matrix. Those titles do not fail loudly: they probe, take a
 * silent fallback, and either render nothing, refuse with a dialog the port
 * does not draw, or hand themselves a null. A single wrong D3DERR_NOTAVAILABLE
 * in the format table is enough, and nothing in a device log distinguishes it
 * from twenty other causes.
 *
 * So this walks the matrix a period title walks, asserts the answers a period
 * title requires, and prints every one of them either way. The [d3d9-caps]
 * trace inside the frontend prints the same queries from the other side; the
 * two together mean a failing title can be compared against a known-good run.
 *
 * WHAT IT CHECKS (each REQUIRED item fails the run; each INFO item is printed
 * and not asserted, because a period title falls back cleanly on it)
 * ----------------------------------------------------------------------
 *  1. Direct3DCreate9, GetAdapterCount >= 1.
 *  2. GetAdapterIdentifier: VendorId and DeviceId both NON-ZERO, and Driver
 *     and Description both non-empty. A vendor or device id of 0 is what an
 *     application's GPU table reads as "no adapter"; that is the single most
 *     common way a legacy title decides it is running on nothing.
 *  3. GetDeviceCaps: vs >= 3.0, ps >= 3.0, MaxSimultaneousTextures >= 8,
 *     MaxTextureBlendStages >= 8, MaxTextureWidth/Height >= 2048,
 *     MaxPrimitiveCount >= 0xFFFFF, MaxVertexShaderConst >= 256,
 *     NumSimultaneousRTs >= 1, MaxStreams >= 8, MaxActiveLights >= 8,
 *     DevCaps carries HWTRANSFORMANDLIGHT and PUREDEVICE, StencilCaps carries
 *     the eight stencil ops, DeclTypes carries the packed vertex types, and
 *     TextureCaps is sane about power-of-two (either no POW2 at all, which
 *     means unconditional support, or POW2 together with NONPOW2CONDITIONAL;
 *     POW2 alone is a texture engine no period title expects to meet).
 *  4. CheckDeviceType for every (display, backbuffer) pair a period title
 *     tries, WINDOWED and FULLSCREEN: X8R8G8B8 with X8R8G8B8 and A8R8G8B8,
 *     R5G6B5 with R5G6B5, X1R5G5B5 with X1R5G5B5 and A1R5G5B5.
 *  5. CheckDeviceFormat, the texture set: DXT1/DXT2/DXT3/DXT4/DXT5, the
 *     16-bit colour formats (R5G6B5, X1R5G5B5, A1R5G5B5, A4R4G4B4), the
 *     luminance/alpha set (L8, A8, A8L8, L16) and the bump set (V8U8,
 *     Q8W8V8U8).
 *  6. CheckDeviceFormat, the render-target set: X8R8G8B8, A8R8G8B8, R5G6B5,
 *     X1R5G5B5, A1R5G5B5.
 *  7. CheckDeviceFormat, the depth-stencil set: D16, D24S8, D24X8. (D32 and
 *     D16_LOCKABLE are INFO: no shipping driver exposes plain D32 and
 *     D16_LOCKABLE is vendor-specific, so wined3d and DXVK both refuse them
 *     and every period title falls back to D24X8/D16.)
 *  8. CheckDepthStencilMatch: {X8R8G8B8, A8R8G8B8, R5G6B5} x {D16, D24S8,
 *     D24X8}, all nine required. A title picks its depth format by walking
 *     exactly this cross product.
 *  9. The usage queries: DYNAMIC on a texture, AUTOGENMIPMAP on a
 *     colour-renderable texture (D3D_OK) and on DXT1 (must SUCCEED, as
 *     D3DOK_NOAUTOGEN -- the success-with-caveat code, which a title reads as
 *     "usable, build the mips yourself"; a FAILED answer there sends it down
 *     a no-mipmaps path instead), QUERY_FILTER, QUERY_SRGBREAD,
 *     QUERY_POSTPIXELSHADER_BLENDING and QUERY_WRAPANDMIP.
 * 10. CheckDeviceMultiSampleType: NONE must be available for X8R8G8B8 and
 *     D24S8 (a device that cannot do "no multisampling" is not a device), and
 *     the quality-level out-parameter must be written.
 * 11. CheckDeviceFormatConversion: A8R8G8B8 -> X8R8G8B8 and R5G6B5 ->
 *     X8R8G8B8, the two a windowed present performs.
 * 12. The two probes agree with each other where they must: every format
 *     CheckDeviceType accepts as a fullscreen backbuffer is also a format
 *     CheckDeviceFormat reports RENDERTARGET-capable at that display format.
 *     A split between the two is the defect class this file was written for.
 *
 * Deliberate restrictions, the same ones the other tests in this directory
 * work under: no CRT (this file supplies `start' and is linked -nostdlib, so
 * its only imports are kernel32 and d3d9), no 64-bit division, no
 * int-to-double conversion. No window is created: not one of these calls
 * needs one, which is also the point -- a title probes all of this before it
 * has a renderer.
 *
 * Exit status (the runtime reports it as "MADEIRA-EXIT: ... status=<n>"):
 *   56  every REQUIRED expectation met
 *   60  Direct3DCreate9 returned NULL
 *   61  GetAdapterCount reported 0 adapters
 *   62  GetAdapterIdentifier failed, or returned a zero vendor/device id or
 *       an empty driver/description string
 *   63  GetDeviceCaps failed
 *   64  a D3DCAPS9 field is below what a period title requires
 *   65  CheckDeviceType refused a pair a period title requires
 *   66  CheckDeviceFormat refused a texture format a period title requires
 *   67  CheckDeviceFormat refused a render-target format
 *   68  CheckDeviceFormat refused a depth-stencil format
 *   69  CheckDepthStencilMatch refused a required (rt, ds) pair
 *   70  a usage query was refused
 *   71  CheckDeviceMultiSampleType refused D3DMULTISAMPLE_NONE
 *   72  CheckDeviceFormatConversion refused a windowed present conversion
 *   73  CheckDeviceType and CheckDeviceFormat disagree about a backbuffer
 */
#include <stddef.h>
#include <windows.h>
#include <d3d9.h>

/* -nostdlib: clang may still lower a struct initialisation to a memset or
 * memcpy call, so provide them rather than hoping it does not. */
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

/* ---------------------------------------------------------------- logging */

static void out_str( const char *s )
{
    DWORD written = 0;
    const char *e = s;
    while (*e) e++;
    WriteFile( GetStdHandle( STD_ERROR_HANDLE ), s, (DWORD)(e - s), &written, NULL );
}

static char *put_str( char *p, const char *s )
{
    while (*s) *p++ = *s++;
    return p;
}

static char *put_uint( char *p, unsigned int v )
{
    char tmp[16];
    int n = 0;
    if (!v) { *p++ = '0'; return p; }
    while (v) { tmp[n++] = (char)('0' + v % 10); v /= 10; }
    while (n--) *p++ = tmp[n];
    return p;
}

static char *put_hex( char *p, unsigned int v )
{
    static const char digits[] = "0123456789abcdef";
    int i;
    *p++ = '0'; *p++ = 'x';
    for (i = 28; i >= 0; i -= 4) *p++ = digits[(v >> i) & 0xf];
    return p;
}

#define TAG "MADEIRA-D3D9CAPS: "

static void log_line( const char *s )
{
    char buf[256], *p = buf;
    p = put_str( p, TAG );
    p = put_str( p, s );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

static void log_val( const char *label, unsigned int v )
{
    char buf[256], *p = buf;
    p = put_str( p, TAG );
    p = put_str( p, label );
    *p++ = '=';
    p = put_uint( p, v );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

static void log_valx( const char *label, unsigned int v )
{
    char buf[256], *p = buf;
    p = put_str( p, TAG );
    p = put_str( p, label );
    *p++ = '=';
    p = put_hex( p, v );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

/* ------------------------------------------------------- format printing */

/* A FOURCC prints as its four characters and everything else as a number, so
 * a log line names DXT1 as DXT1 rather than as 827611204. The D3DFMT_ enum
 * values below 256 get a short name from the table; the rest are rare enough
 * in this test that the number is fine. */
static char *put_fmt( char *p, D3DFORMAT f )
{
    unsigned int v = (unsigned int)f;
    unsigned int i;
    static const struct { unsigned int v; const char *name; } known[] = {
        { D3DFMT_UNKNOWN,       "UNKNOWN"      },
        { D3DFMT_A8R8G8B8,      "A8R8G8B8"     },
        { D3DFMT_X8R8G8B8,      "X8R8G8B8"     },
        { D3DFMT_R5G6B5,        "R5G6B5"       },
        { D3DFMT_X1R5G5B5,      "X1R5G5B5"     },
        { D3DFMT_A1R5G5B5,      "A1R5G5B5"     },
        { D3DFMT_A4R4G4B4,      "A4R4G4B4"     },
        { D3DFMT_X4R4G4B4,      "X4R4G4B4"     },
        { D3DFMT_A2R10G10B10,   "A2R10G10B10"  },
        { D3DFMT_A8,            "A8"           },
        { D3DFMT_L8,            "L8"           },
        { D3DFMT_A8L8,          "A8L8"         },
        { D3DFMT_L16,           "L16"          },
        { D3DFMT_V8U8,          "V8U8"         },
        { D3DFMT_Q8W8V8U8,      "Q8W8V8U8"     },
        { D3DFMT_V16U16,        "V16U16"       },
        { D3DFMT_D16,           "D16"          },
        { D3DFMT_D16_LOCKABLE,  "D16_LOCKABLE" },
        { D3DFMT_D24S8,         "D24S8"        },
        { D3DFMT_D24X8,         "D24X8"        },
        { D3DFMT_D32,           "D32"          },
        { D3DFMT_D24X4S4,       "D24X4S4"      },
        { D3DFMT_D15S1,         "D15S1"        },
        { D3DFMT_R16F,          "R16F"         },
        { D3DFMT_A16B16G16R16F, "A16B16G16R16F"},
    };

    for (i = 0; i < sizeof(known) / sizeof(known[0]); i++)
        if (known[i].v == v) return put_str( p, known[i].name );

    /* FOURCC: four printable bytes. */
    {
        char c0 = (char)(v & 0xff), c1 = (char)((v >> 8) & 0xff);
        char c2 = (char)((v >> 16) & 0xff), c3 = (char)((v >> 24) & 0xff);
        if (c0 >= 0x20 && c0 < 0x7f && c1 >= 0x20 && c1 < 0x7f &&
            c2 >= 0x20 && c2 < 0x7f && c3 >= 0x20 && c3 < 0x7f)
        {
            *p++ = '\''; *p++ = c0; *p++ = c1; *p++ = c2; *p++ = c3; *p++ = '\'';
            return p;
        }
    }
    return put_hex( p, v );
}

/* One "<what> <detail> -> hr" line. `required` selects the REQ/info marker so
 * a reader can tell an assertion from an observation without the source. */
static void log_probe( const char *what, const char *detail, HRESULT hr, int required, int ok )
{
    char buf[256], *p = buf;
    p = put_str( p, TAG );
    p = put_str( p, required ? (ok ? "[ok  ] " : "[FAIL] ") : "[info] " );
    p = put_str( p, what );
    *p++ = ' ';
    p = put_str( p, detail );
    p = put_str( p, " -> hr " );
    p = put_hex( p, (unsigned int)hr );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

static void log_fmt_probe( const char *what, D3DFORMAT a, D3DFORMAT b, HRESULT hr, int required, int ok )
{
    char detail[64], *p = detail;
    p = put_fmt( p, a );
    if (b != D3DFMT_UNKNOWN || a == D3DFMT_UNKNOWN)
    {
        *p++ = '/';
        p = put_fmt( p, b );
    }
    *p = 0;
    log_probe( what, detail, hr, required, ok );
}

/* ------------------------------------------------------------------ checks */

static int failures;          /* how many REQUIRED expectations were missed */
static int first_fail_code;   /* the exit status of the first one */

static void fail( int code )
{
    failures++;
    if (!first_fail_code) first_fail_code = code;
}

/* CheckDeviceFormat, asserted. */
static void need_format( IDirect3D9 *d3d, const char *what, D3DFORMAT adapter_fmt, DWORD usage,
                         D3DRESOURCETYPE rtype, D3DFORMAT fmt, int code )
{
    HRESULT hr = IDirect3D9_CheckDeviceFormat( d3d, 0, D3DDEVTYPE_HAL, adapter_fmt, usage, rtype, fmt );
    int ok = SUCCEEDED(hr);
    log_fmt_probe( what, fmt, D3DFMT_UNKNOWN, hr, 1, ok );
    if (!ok) fail( code );
}

/* CheckDeviceFormat, printed but not asserted. */
static void info_format( IDirect3D9 *d3d, const char *what, D3DFORMAT adapter_fmt, DWORD usage,
                         D3DRESOURCETYPE rtype, D3DFORMAT fmt )
{
    HRESULT hr = IDirect3D9_CheckDeviceFormat( d3d, 0, D3DDEVTYPE_HAL, adapter_fmt, usage, rtype, fmt );
    log_fmt_probe( what, fmt, D3DFMT_UNKNOWN, hr, 0, 0 );
}

static void need_devtype( IDirect3D9 *d3d, D3DFORMAT display, D3DFORMAT backbuffer, BOOL windowed )
{
    HRESULT hr = IDirect3D9_CheckDeviceType( d3d, 0, D3DDEVTYPE_HAL, display, backbuffer, windowed );
    int ok = SUCCEEDED(hr);
    log_fmt_probe( windowed ? "CheckDeviceType windowed" : "CheckDeviceType fullscreen",
                   display, backbuffer, hr, 1, ok );
    if (!ok) fail( 65 );

    /* Check 12: the two probes must agree. A backbuffer CheckDeviceType
     * accepts has to be RENDERTARGET-capable at that display format, because
     * that is what the device create will go on to ask for. */
    if (ok)
    {
        HRESULT hr2 = IDirect3D9_CheckDeviceFormat( d3d, 0, D3DDEVTYPE_HAL, display,
                                                    D3DUSAGE_RENDERTARGET, D3DRTYPE_SURFACE, backbuffer );
        if (FAILED(hr2))
        {
            log_fmt_probe( "DISAGREE: CheckDeviceType accepted but RT probe refused",
                           display, backbuffer, hr2, 1, 0 );
            fail( 73 );
        }
    }
}

static void need_ds_match( IDirect3D9 *d3d, D3DFORMAT adapter_fmt, D3DFORMAT rt, D3DFORMAT ds )
{
    HRESULT hr = IDirect3D9_CheckDepthStencilMatch( d3d, 0, D3DDEVTYPE_HAL, adapter_fmt, rt, ds );
    int ok = SUCCEEDED(hr);
    log_fmt_probe( "CheckDepthStencilMatch", rt, ds, hr, 1, ok );
    if (!ok) fail( 69 );
}

static void need_caps( const char *label, unsigned int have, unsigned int want )
{
    char buf[256], *p = buf;
    int ok = have >= want;
    p = put_str( p, TAG );
    p = put_str( p, ok ? "[ok  ] " : "[FAIL] " );
    p = put_str( p, label );
    *p++ = '=';
    p = put_uint( p, have );
    p = put_str( p, " (need >= " );
    p = put_uint( p, want );
    *p++ = ')';
    *p++ = '\n';
    *p = 0;
    out_str( buf );
    if (!ok) fail( 64 );
}

static void need_bits( const char *label, DWORD have, DWORD want )
{
    char buf[256], *p = buf;
    int ok = (have & want) == want;
    p = put_str( p, TAG );
    p = put_str( p, ok ? "[ok  ] " : "[FAIL] " );
    p = put_str( p, label );
    *p++ = '=';
    p = put_hex( p, (unsigned int)have );
    p = put_str( p, " (need bits " );
    p = put_hex( p, (unsigned int)want );
    p = put_str( p, " -- missing " );
    p = put_hex( p, (unsigned int)(want & ~have) );
    *p++ = ')';
    *p++ = '\n';
    *p = 0;
    out_str( buf );
    if (!ok) fail( 64 );
}

/* --------------------------------------------------------------- the test */

void start( void )
{
    IDirect3D9 *d3d;
    D3DADAPTER_IDENTIFIER9 id;
    D3DCAPS9 caps;
    D3DDISPLAYMODE mode;
    HRESULT hr;
    DWORD quality;
    unsigned int i;

    static const D3DFORMAT tex_formats[] = {
        D3DFMT_DXT1, D3DFMT_DXT2, D3DFMT_DXT3, D3DFMT_DXT4, D3DFMT_DXT5,
        D3DFMT_R5G6B5, D3DFMT_X1R5G5B5, D3DFMT_A1R5G5B5, D3DFMT_A4R4G4B4,
        D3DFMT_X8R8G8B8, D3DFMT_A8R8G8B8,
        D3DFMT_L8, D3DFMT_A8, D3DFMT_A8L8, D3DFMT_L16,
        D3DFMT_V8U8, D3DFMT_Q8W8V8U8,
    };
    static const D3DFORMAT rt_formats[] = {
        D3DFMT_X8R8G8B8, D3DFMT_A8R8G8B8, D3DFMT_R5G6B5, D3DFMT_X1R5G5B5, D3DFMT_A1R5G5B5,
    };
    static const D3DFORMAT ds_formats[] = { D3DFMT_D16, D3DFMT_D24S8, D3DFMT_D24X8 };
    static const D3DFORMAT ds_info_formats[] = { D3DFMT_D32, D3DFMT_D16_LOCKABLE, D3DFMT_D24X4S4, D3DFMT_D15S1 };
    static const D3DFORMAT ds_rt_formats[] = { D3DFMT_X8R8G8B8, D3DFMT_A8R8G8B8, D3DFMT_R5G6B5 };
    /* The INFO texture set: formats wined3d or DXVK expose that this adapter
     * may not. None of them ends a period title on its own -- every one has a
     * documented fallback -- but a run that starts answering NOTAVAILABLE to
     * a format it used to accept is a regression worth seeing in the log. */
    static const D3DFORMAT tex_info_formats[] = {
        D3DFMT_X4R4G4B4, D3DFMT_V16U16, D3DFMT_Q16W16V16U16, D3DFMT_A2R10G10B10,
        D3DFMT_A16B16G16R16F, D3DFMT_R16F, D3DFMT_R32F, D3DFMT_G16R16,
        D3DFMT_X8L8V8U8, D3DFMT_L6V5U5, D3DFMT_A2W10V10U10, D3DFMT_P8, D3DFMT_R8G8B8,
    };

    log_line( "start" );

    /* --- 1: the interface ------------------------------------------------ */

    d3d = Direct3DCreate9( D3D_SDK_VERSION );
    if (!d3d)
    {
        log_line( "Direct3DCreate9 returned NULL" );
        ExitProcess( 60 );
    }
    log_val( "adapters", IDirect3D9_GetAdapterCount( d3d ) );
    if (IDirect3D9_GetAdapterCount( d3d ) < 1)
        ExitProcess( 61 );

    /* --- 2: the adapter's identity --------------------------------------- */

    memset( &id, 0, sizeof(id) );
    hr = IDirect3D9_GetAdapterIdentifier( d3d, 0, 0, &id );
    if (FAILED(hr))
    {
        log_probe( "GetAdapterIdentifier", "adapter 0", hr, 1, 0 );
        ExitProcess( 62 );
    }
    log_valx( "VendorId", (unsigned int)id.VendorId );
    log_valx( "DeviceId", (unsigned int)id.DeviceId );
    {
        char buf[512], *p = buf;
        p = put_str( p, TAG "Driver=\"" );
        p = put_str( p, id.Driver );
        p = put_str( p, "\" Description=\"" );
        p = put_str( p, id.Description );
        p = put_str( p, "\" DeviceName=\"" );
        p = put_str( p, id.DeviceName );
        p = put_str( p, "\"\n" );
        *p = 0;
        out_str( buf );
    }
    /* Vendor 0 and device 0 are the values a legacy GPU table reads as "no
     * adapter", which is the whole reason this check exists. */
    if (!id.VendorId || !id.DeviceId || !id.Driver[0] || !id.Description[0])
    {
        log_line( "[FAIL] adapter identity has a zero id or an empty string" );
        ExitProcess( 62 );
    }
    log_line( "[ok  ] adapter identity is non-degenerate" );

    memset( &mode, 0, sizeof(mode) );
    hr = IDirect3D9_GetAdapterDisplayMode( d3d, 0, &mode );
    log_probe( "GetAdapterDisplayMode", "adapter 0", hr, 1, SUCCEEDED(hr) );
    if (SUCCEEDED(hr))
    {
        log_val( "display.width", mode.Width );
        log_val( "display.height", mode.Height );
        log_val( "display.refresh", mode.RefreshRate );
    }

    /* --- 3: D3DCAPS9 ------------------------------------------------------ */

    memset( &caps, 0, sizeof(caps) );
    hr = IDirect3D9_GetDeviceCaps( d3d, 0, D3DDEVTYPE_HAL, &caps );
    if (FAILED(hr))
    {
        log_probe( "GetDeviceCaps", "HAL", hr, 1, 0 );
        ExitProcess( 63 );
    }

    log_valx( "VertexShaderVersion", (unsigned int)caps.VertexShaderVersion );
    log_valx( "PixelShaderVersion", (unsigned int)caps.PixelShaderVersion );
    log_valx( "Caps", (unsigned int)caps.Caps );
    log_valx( "Caps2", (unsigned int)caps.Caps2 );
    log_valx( "Caps3", (unsigned int)caps.Caps3 );
    log_valx( "DevCaps", (unsigned int)caps.DevCaps );
    log_valx( "DevCaps2", (unsigned int)caps.DevCaps2 );
    log_valx( "TextureCaps", (unsigned int)caps.TextureCaps );
    log_valx( "RasterCaps", (unsigned int)caps.RasterCaps );
    log_valx( "PrimitiveMiscCaps", (unsigned int)caps.PrimitiveMiscCaps );
    log_valx( "StencilCaps", (unsigned int)caps.StencilCaps );
    log_valx( "DeclTypes", (unsigned int)caps.DeclTypes );
    log_valx( "TextureOpCaps", (unsigned int)caps.TextureOpCaps );
    log_valx( "TextureFilterCaps", (unsigned int)caps.TextureFilterCaps );
    log_valx( "TextureAddressCaps", (unsigned int)caps.TextureAddressCaps );
    log_valx( "SrcBlendCaps", (unsigned int)caps.SrcBlendCaps );
    log_valx( "MaxPrimitiveCount", (unsigned int)caps.MaxPrimitiveCount );
    log_valx( "MaxVertexIndex", (unsigned int)caps.MaxVertexIndex );

    /* D3DVS_VERSION(3,0) == 0xfffe0300, D3DPS_VERSION(3,0) == 0xffff0300. The
     * comparison is on the low 16 bits so the token prefix does not have to be
     * assumed. */
    need_caps( "vs major", (caps.VertexShaderVersion >> 8) & 0xff, 3 );
    need_caps( "ps major", (caps.PixelShaderVersion >> 8) & 0xff, 3 );
    need_caps( "MaxSimultaneousTextures", caps.MaxSimultaneousTextures, 8 );
    need_caps( "MaxTextureBlendStages", caps.MaxTextureBlendStages, 8 );
    need_caps( "MaxTextureWidth", caps.MaxTextureWidth, 2048 );
    need_caps( "MaxTextureHeight", caps.MaxTextureHeight, 2048 );
    need_caps( "MaxPrimitiveCount", caps.MaxPrimitiveCount, 0xFFFFF );
    need_caps( "MaxVertexShaderConst", caps.MaxVertexShaderConst, 256 );
    need_caps( "NumSimultaneousRTs", caps.NumSimultaneousRTs, 1 );
    need_caps( "MaxStreams", caps.MaxStreams, 8 );
    need_caps( "MaxActiveLights", caps.MaxActiveLights, 8 );
    need_caps( "MaxUserClipPlanes", caps.MaxUserClipPlanes, 6 );
    need_caps( "MaxAnisotropy", caps.MaxAnisotropy, 2 );
    need_caps( "MaxVertexShader30InstructionSlots", caps.MaxVertexShader30InstructionSlots, 512 );
    need_caps( "MaxPixelShader30InstructionSlots", caps.MaxPixelShader30InstructionSlots, 512 );

    need_bits( "DevCaps", caps.DevCaps, D3DDEVCAPS_HWTRANSFORMANDLIGHT | D3DDEVCAPS_PUREDEVICE
                                        | D3DDEVCAPS_HWRASTERIZATION | D3DDEVCAPS_DRAWPRIMITIVES2EX );
    need_bits( "Caps2", caps.Caps2, D3DCAPS2_DYNAMICTEXTURES | D3DCAPS2_CANAUTOGENMIPMAP | D3DCAPS2_FULLSCREENGAMMA );
    need_bits( "TextureCaps", caps.TextureCaps, D3DPTEXTURECAPS_PERSPECTIVE | D3DPTEXTURECAPS_ALPHA
                                                | D3DPTEXTURECAPS_MIPMAP | D3DPTEXTURECAPS_CUBEMAP
                                                | D3DPTEXTURECAPS_VOLUMEMAP | D3DPTEXTURECAPS_PROJECTED );
    need_bits( "RasterCaps", caps.RasterCaps, D3DPRASTERCAPS_ZTEST | D3DPRASTERCAPS_DITHER
                                              | D3DPRASTERCAPS_FOGVERTEX | D3DPRASTERCAPS_FOGTABLE
                                              | D3DPRASTERCAPS_SCISSORTEST | D3DPRASTERCAPS_DEPTHBIAS
                                              | D3DPRASTERCAPS_SLOPESCALEDEPTHBIAS | D3DPRASTERCAPS_ANISOTROPY );
    need_bits( "PrimitiveMiscCaps", caps.PrimitiveMiscCaps, D3DPMISCCAPS_MASKZ | D3DPMISCCAPS_CULLNONE
                                                            | D3DPMISCCAPS_CULLCW | D3DPMISCCAPS_CULLCCW
                                                            | D3DPMISCCAPS_COLORWRITEENABLE
                                                            | D3DPMISCCAPS_BLENDOP
                                                            | D3DPMISCCAPS_SEPARATEALPHABLEND );
    need_bits( "StencilCaps", caps.StencilCaps, D3DSTENCILCAPS_KEEP | D3DSTENCILCAPS_ZERO | D3DSTENCILCAPS_REPLACE
                                                | D3DSTENCILCAPS_INCRSAT | D3DSTENCILCAPS_DECRSAT
                                                | D3DSTENCILCAPS_INVERT | D3DSTENCILCAPS_INCR
                                                | D3DSTENCILCAPS_DECR | D3DSTENCILCAPS_TWOSIDED );
    need_bits( "DeclTypes", caps.DeclTypes, D3DDTCAPS_UBYTE4 | D3DDTCAPS_UBYTE4N | D3DDTCAPS_SHORT2N
                                            | D3DDTCAPS_SHORT4N | D3DDTCAPS_USHORT2N | D3DDTCAPS_USHORT4N
                                            | D3DDTCAPS_FLOAT16_2 | D3DDTCAPS_FLOAT16_4 );
    need_bits( "TextureAddressCaps", caps.TextureAddressCaps, D3DPTADDRESSCAPS_WRAP | D3DPTADDRESSCAPS_MIRROR
                                                              | D3DPTADDRESSCAPS_CLAMP | D3DPTADDRESSCAPS_BORDER
                                                              | D3DPTADDRESSCAPS_INDEPENDENTUV );
    need_bits( "TextureOpCaps", caps.TextureOpCaps, D3DTEXOPCAPS_DISABLE | D3DTEXOPCAPS_SELECTARG1
                                                    | D3DTEXOPCAPS_SELECTARG2 | D3DTEXOPCAPS_MODULATE
                                                    | D3DTEXOPCAPS_MODULATE2X | D3DTEXOPCAPS_ADD
                                                    | D3DTEXOPCAPS_BLENDTEXTUREALPHA | D3DTEXOPCAPS_DOTPRODUCT3
                                                    | D3DTEXOPCAPS_BUMPENVMAP );

    /* Power-of-two sanity. No POW2 bit means unconditional non-power-of-two
     * support, which is what modern hardware reports and what every period
     * title copes with. POW2 on its own -- without NONPOW2CONDITIONAL -- is a
     * texture engine that only takes power-of-two sizes, and a title that has
     * a non-power-of-two UI atlas has nowhere to go. */
    if (caps.TextureCaps & D3DPTEXTURECAPS_POW2)
    {
        if (caps.TextureCaps & D3DPTEXTURECAPS_NONPOW2CONDITIONAL)
            log_line( "[ok  ] TextureCaps POW2 with NONPOW2CONDITIONAL (conditional non-pow2)" );
        else
        {
            log_line( "[FAIL] TextureCaps has POW2 without NONPOW2CONDITIONAL" );
            fail( 64 );
        }
    }
    else
        log_line( "[ok  ] TextureCaps has no POW2 (unconditional non-pow2)" );

    if (caps.TextureCaps & D3DPTEXTURECAPS_SQUAREONLY)
    {
        log_line( "[FAIL] TextureCaps has SQUAREONLY" );
        fail( 64 );
    }

    /* --- 4: CheckDeviceType, windowed and fullscreen ---------------------- */

    need_devtype( d3d, D3DFMT_X8R8G8B8, D3DFMT_X8R8G8B8, TRUE );
    need_devtype( d3d, D3DFMT_X8R8G8B8, D3DFMT_A8R8G8B8, TRUE );
    need_devtype( d3d, D3DFMT_X8R8G8B8, D3DFMT_R5G6B5,   TRUE );
    need_devtype( d3d, D3DFMT_R5G6B5,   D3DFMT_R5G6B5,   TRUE );
    need_devtype( d3d, D3DFMT_X1R5G5B5, D3DFMT_X1R5G5B5, TRUE );

    need_devtype( d3d, D3DFMT_X8R8G8B8, D3DFMT_X8R8G8B8, FALSE );
    need_devtype( d3d, D3DFMT_X8R8G8B8, D3DFMT_A8R8G8B8, FALSE );
    need_devtype( d3d, D3DFMT_R5G6B5,   D3DFMT_R5G6B5,   FALSE );
    need_devtype( d3d, D3DFMT_X1R5G5B5, D3DFMT_X1R5G5B5, FALSE );
    need_devtype( d3d, D3DFMT_X1R5G5B5, D3DFMT_A1R5G5B5, FALSE );

    /* --- 5: textures ------------------------------------------------------ */

    for (i = 0; i < sizeof(tex_formats) / sizeof(tex_formats[0]); i++)
        need_format( d3d, "CheckDeviceFormat TEXTURE", D3DFMT_X8R8G8B8, 0, D3DRTYPE_TEXTURE,
                     tex_formats[i], 66 );
    for (i = 0; i < sizeof(tex_info_formats) / sizeof(tex_info_formats[0]); i++)
        info_format( d3d, "CheckDeviceFormat TEXTURE", D3DFMT_X8R8G8B8, 0, D3DRTYPE_TEXTURE,
                     tex_info_formats[i] );

    /* DXT on a cube map: the shape a period title uses for a compressed
     * skybox, and a different arm of the probe from the 2D one above. */
    need_format( d3d, "CheckDeviceFormat CUBETEXTURE", D3DFMT_X8R8G8B8, 0, D3DRTYPE_CUBETEXTURE,
                 D3DFMT_DXT1, 66 );
    need_format( d3d, "CheckDeviceFormat CUBETEXTURE", D3DFMT_X8R8G8B8, 0, D3DRTYPE_CUBETEXTURE,
                 D3DFMT_X8R8G8B8, 66 );
    need_format( d3d, "CheckDeviceFormat VOLUMETEXTURE", D3DFMT_X8R8G8B8, 0, D3DRTYPE_VOLUMETEXTURE,
                 D3DFMT_X8R8G8B8, 66 );

    /* --- 6: render targets ------------------------------------------------ */

    for (i = 0; i < sizeof(rt_formats) / sizeof(rt_formats[0]); i++)
    {
        need_format( d3d, "CheckDeviceFormat RT SURFACE", D3DFMT_X8R8G8B8, D3DUSAGE_RENDERTARGET,
                     D3DRTYPE_SURFACE, rt_formats[i], 67 );
        need_format( d3d, "CheckDeviceFormat RT TEXTURE", D3DFMT_X8R8G8B8, D3DUSAGE_RENDERTARGET,
                     D3DRTYPE_TEXTURE, rt_formats[i], 67 );
    }
    /* A4R4G4B4 as a render target is not required: neither DXVK nor this
     * adapter advertises it, and a period title uses it as a texture. */
    info_format( d3d, "CheckDeviceFormat RT SURFACE", D3DFMT_X8R8G8B8, D3DUSAGE_RENDERTARGET,
                 D3DRTYPE_SURFACE, D3DFMT_A4R4G4B4 );

    /* --- 7: depth-stencil -------------------------------------------------- */

    for (i = 0; i < sizeof(ds_formats) / sizeof(ds_formats[0]); i++)
        need_format( d3d, "CheckDeviceFormat DS SURFACE", D3DFMT_X8R8G8B8, D3DUSAGE_DEPTHSTENCIL,
                     D3DRTYPE_SURFACE, ds_formats[i], 68 );
    for (i = 0; i < sizeof(ds_info_formats) / sizeof(ds_info_formats[0]); i++)
        info_format( d3d, "CheckDeviceFormat DS SURFACE", D3DFMT_X8R8G8B8, D3DUSAGE_DEPTHSTENCIL,
                     D3DRTYPE_SURFACE, ds_info_formats[i] );
    /* The hardware-shadow-map probe: a depth format as a sampleable texture.
     * INTZ is the FOURCC every SM3 title of the era uses for it. */
    info_format( d3d, "CheckDeviceFormat DS TEXTURE", D3DFMT_X8R8G8B8, D3DUSAGE_DEPTHSTENCIL,
                 D3DRTYPE_TEXTURE, D3DFMT_D24S8 );
    info_format( d3d, "CheckDeviceFormat DS TEXTURE", D3DFMT_X8R8G8B8, D3DUSAGE_DEPTHSTENCIL,
                 D3DRTYPE_TEXTURE, (D3DFORMAT)MAKEFOURCC('I','N','T','Z') );

    /* --- 8: the depth/backbuffer cross product ---------------------------- */

    for (i = 0; i < sizeof(ds_rt_formats) / sizeof(ds_rt_formats[0]); i++)
    {
        unsigned int j;
        for (j = 0; j < sizeof(ds_formats) / sizeof(ds_formats[0]); j++)
            need_ds_match( d3d, D3DFMT_X8R8G8B8, ds_rt_formats[i], ds_formats[j] );
    }

    /* --- 9: the usage queries --------------------------------------------- */

    need_format( d3d, "usage DYNAMIC", D3DFMT_X8R8G8B8, D3DUSAGE_DYNAMIC, D3DRTYPE_TEXTURE,
                 D3DFMT_X8R8G8B8, 70 );
    need_format( d3d, "usage DYNAMIC", D3DFMT_X8R8G8B8, D3DUSAGE_DYNAMIC, D3DRTYPE_TEXTURE,
                 D3DFMT_A8R8G8B8, 70 );
    need_format( d3d, "usage AUTOGENMIPMAP", D3DFMT_X8R8G8B8, D3DUSAGE_AUTOGENMIPMAP, D3DRTYPE_TEXTURE,
                 D3DFMT_X8R8G8B8, 70 );
    /* D3DOK_NOAUTOGEN is a SUCCESS code, and that distinction is the whole
     * point: a title reads it as "the texture is fine, generate the mips
     * yourself", while a FAILED answer sends it down a no-mipmaps path. */
    need_format( d3d, "usage AUTOGENMIPMAP", D3DFMT_X8R8G8B8, D3DUSAGE_AUTOGENMIPMAP, D3DRTYPE_TEXTURE,
                 D3DFMT_DXT1, 70 );
    need_format( d3d, "usage QUERY_FILTER", D3DFMT_X8R8G8B8, D3DUSAGE_QUERY_FILTER, D3DRTYPE_TEXTURE,
                 D3DFMT_X8R8G8B8, 70 );
    need_format( d3d, "usage QUERY_SRGBREAD", D3DFMT_X8R8G8B8, D3DUSAGE_QUERY_SRGBREAD, D3DRTYPE_TEXTURE,
                 D3DFMT_X8R8G8B8, 70 );
    need_format( d3d, "usage QUERY_SRGBREAD", D3DFMT_X8R8G8B8, D3DUSAGE_QUERY_SRGBREAD, D3DRTYPE_TEXTURE,
                 D3DFMT_DXT1, 70 );
    need_format( d3d, "usage QUERY_POSTPSBLEND", D3DFMT_X8R8G8B8,
                 D3DUSAGE_RENDERTARGET | D3DUSAGE_QUERY_POSTPIXELSHADER_BLENDING, D3DRTYPE_SURFACE,
                 D3DFMT_X8R8G8B8, 70 );
    need_format( d3d, "usage QUERY_WRAPANDMIP", D3DFMT_X8R8G8B8, D3DUSAGE_QUERY_WRAPANDMIP, D3DRTYPE_TEXTURE,
                 D3DFMT_X8R8G8B8, 70 );
    info_format( d3d, "usage QUERY_VERTEXTEXTURE", D3DFMT_X8R8G8B8, D3DUSAGE_QUERY_VERTEXTEXTURE,
                 D3DRTYPE_TEXTURE, D3DFMT_A32B32G32R32F );
    info_format( d3d, "usage QUERY_LEGACYBUMPMAP", D3DFMT_X8R8G8B8, D3DUSAGE_QUERY_LEGACYBUMPMAP,
                 D3DRTYPE_TEXTURE, D3DFMT_V8U8 );

    /* --- 10: multisample --------------------------------------------------- */

    quality = 0xdeadbeef;
    hr = IDirect3D9_CheckDeviceMultiSampleType( d3d, 0, D3DDEVTYPE_HAL, D3DFMT_X8R8G8B8, FALSE,
                                                D3DMULTISAMPLE_NONE, &quality );
    log_probe( "CheckDeviceMultiSampleType", "X8R8G8B8 NONE", hr, 1, SUCCEEDED(hr) );
    if (FAILED(hr) || quality == 0xdeadbeef) fail( 71 );
    else log_val( "multisample NONE quality levels", quality );

    quality = 0xdeadbeef;
    hr = IDirect3D9_CheckDeviceMultiSampleType( d3d, 0, D3DDEVTYPE_HAL, D3DFMT_D24S8, FALSE,
                                                D3DMULTISAMPLE_NONE, &quality );
    log_probe( "CheckDeviceMultiSampleType", "D24S8 NONE", hr, 1, SUCCEEDED(hr) );
    if (FAILED(hr) || quality == 0xdeadbeef) fail( 71 );

    quality = 0;
    hr = IDirect3D9_CheckDeviceMultiSampleType( d3d, 0, D3DDEVTYPE_HAL, D3DFMT_X8R8G8B8, FALSE,
                                                D3DMULTISAMPLE_NONMASKABLE, &quality );
    log_probe( "CheckDeviceMultiSampleType", "X8R8G8B8 NONMASKABLE", hr, 0, 0 );
    if (SUCCEEDED(hr)) log_val( "NONMASKABLE quality levels", quality );

    quality = 0;
    hr = IDirect3D9_CheckDeviceMultiSampleType( d3d, 0, D3DDEVTYPE_HAL, D3DFMT_X8R8G8B8, FALSE,
                                                D3DMULTISAMPLE_4_SAMPLES, &quality );
    log_probe( "CheckDeviceMultiSampleType", "X8R8G8B8 4x", hr, 0, 0 );

    /* --- 11: the windowed-present conversions ------------------------------ */

    hr = IDirect3D9_CheckDeviceFormatConversion( d3d, 0, D3DDEVTYPE_HAL, D3DFMT_A8R8G8B8, D3DFMT_X8R8G8B8 );
    log_fmt_probe( "CheckDeviceFormatConversion", D3DFMT_A8R8G8B8, D3DFMT_X8R8G8B8, hr, 1, SUCCEEDED(hr) );
    if (FAILED(hr)) fail( 72 );

    hr = IDirect3D9_CheckDeviceFormatConversion( d3d, 0, D3DDEVTYPE_HAL, D3DFMT_R5G6B5, D3DFMT_X8R8G8B8 );
    log_fmt_probe( "CheckDeviceFormatConversion", D3DFMT_R5G6B5, D3DFMT_X8R8G8B8, hr, 1, SUCCEEDED(hr) );
    if (FAILED(hr)) fail( 72 );

    hr = IDirect3D9_CheckDeviceFormatConversion( d3d, 0, D3DDEVTYPE_HAL, D3DFMT_X8R8G8B8, D3DFMT_X8R8G8B8 );
    log_fmt_probe( "CheckDeviceFormatConversion", D3DFMT_X8R8G8B8, D3DFMT_X8R8G8B8, hr, 1, SUCCEEDED(hr) );
    if (FAILED(hr)) fail( 72 );

    /* --- done -------------------------------------------------------------- */

    IDirect3D9_Release( d3d );

    if (failures)
    {
        log_val( "FAILED expectations", (unsigned int)failures );
        log_val( "first failure exit code", (unsigned int)first_fail_code );
        ExitProcess( (UINT)first_fail_code );
    }

    log_line( "PASS" );
    ExitProcess( 56 );
}
