/* MADEIRA-TEMP: the 32-bit D3D9 PARTIAL-SURFACE-UPDATE self-test.
 *
 * WHY THIS TEST EXISTS
 * --------------------
 * A class of 2D title builds one texture incrementally: it locks a SMALL
 * SUB-RECT of a surface, writes a few texels, unlocks, draws, presents, and
 * repeats -- hundreds of such locks per frame, each one a fragment of the
 * image that is already on screen. Every frame the user sees is therefore the
 * SUM of all the sub-rect updates issued so far, not the last one.
 *
 * Everything in that sentence is a place a translation layer can go wrong:
 *
 *   - the pointer LockRect hands back for a sub-rect must address the rect's
 *     own corner, and the Pitch must be the FULL row stride of the level;
 *   - the Unlock upload must read from that same corner, carry that many
 *     bytes per row, and land at that origin in the destination;
 *   - an update must MERGE with what is already in the texture, not replace
 *     the level from a staging buffer that was never seeded with the current
 *     contents;
 *   - several locks of the same surface inside one frame must all survive --
 *     coalescing that keeps only the LAST rect instead of their union loses
 *     all but one fragment;
 *   - the upload must be ordered BEFORE the draw that is supposed to see it
 *     and AFTER the draw that is not;
 *   - a format whose texel is not four bytes must get the same treatment with
 *     the right stride and column step;
 *   - a MANAGED texture's dirty region must survive from Unlock to the draw
 *     that flushes it, including across a D3DLOCK_NO_DIRTY_UPDATE lock plus an
 *     explicit AddDirtyRect;
 *   - UpdateSurface must honour both its source RECT and its destination
 *     POINT, which are different corners;
 *   - a GDI DC taken on a surface must paint into the very bytes the upload
 *     later reads, and an X8 surface must still sample as opaque.
 *
 * A screenshot cannot separate these. "Half the glyphs are missing" is equally
 * consistent with a lost dirty rect, a staging buffer that wipes the level, a
 * wrong source offset, a mis-ordered blit and a sampler problem. This test
 * separates them: it builds a KNOWN image out of many small sub-rect updates
 * spread over several frames, draws it 1:1 with a point sampler into an
 * offscreen A8R8G8B8 render target, reads that back with GetRenderTargetData
 * and compares EVERY pixel with the CPU-side expected image -- after every
 * frame, not only at the end, so a case that is correct at the end but wrong
 * in the middle (the visible symptom) still fails.
 *
 * Reference behaviour is real Windows D3D9. This file is written so that the
 * stock runtime passes it; anything it reports on another implementation is a
 * divergence from that runtime.
 *
 * WHAT A FAILURE MEANS
 * --------------------
 * Each case prints one line naming the first bad pixel, what was read, what
 * was expected, and how many pixels were wrong in total.
 *   - a bad count equal to the area of all-but-the-last update, with the LAST
 *     rect correct, is a level-replacing staging buffer or a last-rect-wins
 *     coalesce;
 *   - a bad region displaced by a constant offset is a source-offset or
 *     destination-origin error;
 *   - rows correct near the left and wrong further right is a bytes-per-row /
 *     column-step error (watch the sub-4-byte formats);
 *   - the FINAL frame correct while an earlier one is wrong is an ordering
 *     problem between the upload and the draw.
 *
 * Deliberate restrictions: same as the other tests here. No CRT (own `start`,
 * own memset/memcpy, -nostdlib), imports limited to kernel32/user32/gdi32/d3d9
 * (gdi32 only for the GetDC case). Output goes to the standard ERROR handle,
 * like every sibling test here, because that is the handle the device capture
 * records; redirect 2>&1 when running it on a desktop.
 *
 * CASES AND EXIT STATUS (reported as "MADEIRA-EXIT: ... status=<n>")
 * ------------------------------------------------------------------
 * The process exits with the code of the FIRST case that failed, so a single
 * number identifies the earliest defect; every case still runs and prints.
 *
 *   57  every case that ran passed            (the pass code; 0 is reserved)
 *   20  Direct3DCreate9 returned NULL
 *   21  CreateDevice failed
 *   25  window creation failed
 *   59  a core resource create/lock failed (setup problem, not a result)
 *
 *   61  managed.argb8       MANAGED A8R8G8B8, progressive sub-rect LockRects
 *   62  dynamic.argb8       DEFAULT+DYNAMIC A8R8G8B8, plain sub-rect locks
 *   63  dynamic.discard     DEFAULT+DYNAMIC, DISCARD first then NOOVERWRITE
 *   64  updatesurface       SYSTEMMEM -> DEFAULT, sub-RECT + dest POINT
 *   65  updatetexture       AddDirtyRect after NO_DIRTY_UPDATE locks
 *   66  managed.a8          MANAGED A8        (alpha channel only)
 *   67  managed.l8          MANAGED L8
 *   68  managed.a8l8        MANAGED A8L8
 *   69  managed.argb4444    MANAGED A4R4G4B4
 *   70  managed.rgb565      MANAGED R5G6B5
 *   71  managed.argb1555    MANAGED A1R5G5B5
 *   72  managed.xrgb8       MANAGED X8R8G8B8  (X must sample as opaque)
 *   73  readonly.relock     re-lock READONLY sees the earlier contents
 *   74  getdc.xrgb8         GetDC + FillRect + TextOutA + ReleaseDC
 *   75  colorfill.rect      ColorFill with a sub-rect
 *   76  stretchrect.sub     StretchRect sub-rect texture -> render target
 *
 * A format or flag the device refuses is SKIPped, not failed; the line says so
 * and the case cannot become the exit code.
 *
 * Run it from the Custom path popup as
 *   C:\windows\syswow64\d3d9lock-x86.exe
 */
#include <stddef.h>
#include <windows.h>
#include <d3d9.h>

/* The texture, the render target and the expected image are all the same
 * extent and are compared 1:1, so a texel index IS a pixel index and a
 * displaced region reports as a clean constant offset. */
#define TEX_W 64
#define TEX_H 64
#define RT_W  TEX_W
#define RT_H  TEX_H

#define NGLYPH          24
#define GLYPH_PER_FRAME 6
#define NFRAME          (NGLYPH / GLYPH_PER_FRAME)

/* Background written once over the whole level before the progressive updates
 * start. Deliberately neither 0 nor 0xff in any channel: an upload that was
 * dropped (zero fill) and one that never happened (undefined memory) are both
 * distinguishable from it. */
#define BG_ARGB 0x40103050u

#define PASS_CODE 57

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

static char *put_uint( char *p, unsigned int v )
{
    char tmp[16];
    int n = 0;
    if (!v) { *p++ = '0'; return p; }
    while (v) { tmp[n++] = (char)('0' + v % 10); v /= 10; }
    while (n--) *p++ = tmp[n];
    return p;
}

static char *put_hex8( char *p, unsigned int v )
{
    static const char digits[] = "0123456789abcdef";
    int i;
    *p++ = '0'; *p++ = 'x';
    for (i = 28; i >= 0; i -= 4) *p++ = digits[(v >> i) & 0xf];
    return p;
}

static char *put_str( char *p, const char *s )
{
    while (*s) *p++ = *s++;
    return p;
}

#define TAG "MADEIRA-D9LOCK: "

static void log_line( const char *s )
{
    char buf[320];
    char *p = put_str( buf, TAG );
    p = put_str( p, s );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

static void log_hr( const char *what, HRESULT hr )
{
    char buf[320];
    char *p = put_str( buf, TAG );
    p = put_str( p, what );
    p = put_str( p, " hr=" );
    p = put_hex8( p, (unsigned int)hr );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

/* ------------------------------------------------------------ case result */

struct caseres
{
    const char  *name;
    int          code;        /* exit code if this case is the first failure */
    int          started;
    int          skipped;
    unsigned int bad;         /* total mismatching pixels across all frames  */
    unsigned int frame;       /* frame of the first mismatch                 */
    unsigned int x, y;        /* position of the first mismatch              */
    unsigned int got, want;
};

static struct caseres g_case;
static int            g_first_fail_code;
static unsigned int   g_cases_run, g_cases_failed, g_cases_skipped;

static void case_begin( const char *name, int code )
{
    memset( &g_case, 0, sizeof(g_case) );
    g_case.name    = name;
    g_case.code    = code;
    g_case.started = 1;
}

static void case_skip( const char *why )
{
    char buf[320];
    char *p = put_str( buf, TAG );
    p = put_str( p, g_case.name );
    p = put_str( p, " SKIP (" );
    p = put_str( p, why );
    p = put_str( p, ")\n" );
    *p = 0;
    out_str( buf );
    g_case.skipped = 1;
    ++g_cases_skipped;
}

static void case_end( void )
{
    char buf[400];
    char *p;
    if (!g_case.started || g_case.skipped) { g_case.started = 0; return; }
    ++g_cases_run;
    p = put_str( buf, TAG );
    p = put_str( p, g_case.name );
    if (!g_case.bad)
    {
        p = put_str( p, " OK\n" );
        *p = 0;
        out_str( buf );
        g_case.started = 0;
        return;
    }
    ++g_cases_failed;
    if (!g_first_fail_code) g_first_fail_code = g_case.code;
    p = put_str( p, " FAIL (frame " );
    p = put_uint( p, g_case.frame );
    p = put_str( p, ", first bad pixel " );
    p = put_uint( p, g_case.x );
    *p++ = ',';
    p = put_uint( p, g_case.y );
    p = put_str( p, " got=" );
    p = put_hex8( p, g_case.got );
    p = put_str( p, " expected=" );
    p = put_hex8( p, g_case.want );
    p = put_str( p, ", count=" );
    p = put_uint( p, g_case.bad );
    p = put_str( p, ")\n" );
    *p = 0;
    out_str( buf );
    g_case.started = 0;
}

/* One texel comparison, +/-1 per selected channel.
 *
 * The values travel 8-bit -> normalised float -> sampler -> render target ->
 * 8-bit, and a single ulp of rounding anywhere on that path must not be read
 * as a defect. Every defect this file exists to catch is gross: a missing
 * fragment reads as the background or as zero, a displaced one reads as a
 * neighbouring texel's value, and both differ by tens. */
static int texel_ok( unsigned int got, unsigned int want, unsigned int mask )
{
    int shift;
    for (shift = 0; shift < 32; shift += 8)
    {
        int g, w, d;
        if (((mask >> shift) & 0xff) == 0) continue;
        g = (int)((got  >> shift) & 0xff);
        w = (int)((want >> shift) & 0xff);
        d = g - w;
        if (d < -1 || d > 1) return 0;
    }
    return 1;
}

static void case_compare( const unsigned int *got, const unsigned int *want,
                          unsigned int mask, unsigned int frame )
{
    unsigned int y, x;
    for (y = 0; y < TEX_H; y++)
        for (x = 0; x < TEX_W; x++)
        {
            unsigned int i = y * TEX_W + x;
            if (texel_ok( got[i], want[i], mask )) continue;
            if (!g_case.bad)
            {
                g_case.frame = frame;
                g_case.x = x; g_case.y = y;
                g_case.got = got[i]; g_case.want = want[i];
            }
            ++g_case.bad;
        }
}

/* ------------------------------------------------------------ format math */

static unsigned int bytes_per_texel( D3DFORMAT fmt )
{
    switch (fmt)
    {
    case D3DFMT_A8R8G8B8:
    case D3DFMT_X8R8G8B8: return 4;
    case D3DFMT_A8:
    case D3DFMT_L8:       return 1;
    default:              return 2;   /* A8L8, A4R4G4B4, R5G6B5, A1R5G5B5 */
    }
}

/* Store one canonical ARGB texel in the surface's own layout. The X byte of
 * X8R8G8B8 is deliberately written as 0: a correct sampler forces alpha to
 * 1.0 for an X format, and one that leaks the stored byte through instead
 * reads back transparent. */
static void put_texel( D3DFORMAT fmt, unsigned char *p, unsigned int argb )
{
    unsigned int a = (argb >> 24) & 0xff, r = (argb >> 16) & 0xff;
    unsigned int g = (argb >> 8) & 0xff,  b = argb & 0xff;
    unsigned int v;
    switch (fmt)
    {
    case D3DFMT_A8R8G8B8: p[0] = (unsigned char)b; p[1] = (unsigned char)g;
                          p[2] = (unsigned char)r; p[3] = (unsigned char)a; break;
    case D3DFMT_X8R8G8B8: p[0] = (unsigned char)b; p[1] = (unsigned char)g;
                          p[2] = (unsigned char)r; p[3] = 0; break;
    case D3DFMT_A8:       p[0] = (unsigned char)a; break;
    case D3DFMT_L8:       p[0] = (unsigned char)r; break;   /* luminance in red */
    case D3DFMT_A8L8:     p[0] = (unsigned char)r; p[1] = (unsigned char)a; break;
    case D3DFMT_A4R4G4B4: v = ((a >> 4) << 12) | ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4);
                          p[0] = (unsigned char)(v & 0xff); p[1] = (unsigned char)(v >> 8); break;
    case D3DFMT_R5G6B5:   v = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
                          p[0] = (unsigned char)(v & 0xff); p[1] = (unsigned char)(v >> 8); break;
    case D3DFMT_A1R5G5B5: v = ((a >= 0x80 ? 1u : 0u) << 15) | ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3);
                          p[0] = (unsigned char)(v & 0xff); p[1] = (unsigned char)(v >> 8); break;
    default: break;
    }
}

/* What the render target must hold after a texel stored by put_texel is
 * sampled 1:1: the same value put through the format's quantisation and the
 * D3D9 channel-expansion rules (missing colour channels read 0, a missing
 * alpha channel reads 1.0, luminance replicates into RGB). */
static unsigned int sampled_argb( D3DFORMAT fmt, unsigned int argb )
{
    unsigned int a = (argb >> 24) & 0xff, r = (argb >> 16) & 0xff;
    unsigned int g = (argb >> 8) & 0xff,  b = argb & 0xff;
    unsigned int l;
    switch (fmt)
    {
    case D3DFMT_A8R8G8B8: return argb;
    case D3DFMT_X8R8G8B8: return 0xff000000u | (argb & 0x00ffffffu);
    case D3DFMT_A8:       return a << 24;            /* RGB is masked off */
    case D3DFMT_L8:       l = r; return 0xff000000u | (l << 16) | (l << 8) | l;
    case D3DFMT_A8L8:     l = r; return (a << 24) | (l << 16) | (l << 8) | l;
    case D3DFMT_A4R4G4B4:
        a >>= 4; r >>= 4; g >>= 4; b >>= 4;
        a |= a << 4; r |= r << 4; g |= g << 4; b |= b << 4;
        return (a << 24) | (r << 16) | (g << 8) | b;
    case D3DFMT_R5G6B5:
        r >>= 3; g >>= 2; b >>= 3;
        r = (r << 3) | (r >> 2); g = (g << 2) | (g >> 4); b = (b << 3) | (b >> 2);
        return 0xff000000u | (r << 16) | (g << 8) | b;
    case D3DFMT_A1R5G5B5:
        a = (a >= 0x80) ? 0xff : 0x00;
        r >>= 3; g >>= 3; b >>= 3;
        r = (r << 3) | (r >> 2); g = (g << 3) | (g >> 2); b = (b << 3) | (b >> 2);
        return (a << 24) | (r << 16) | (g << 8) | b;
    default: return argb;
    }
}

static unsigned int format_mask( D3DFORMAT fmt )
{
    /* D3DFMT_A8 carries no colour; what a sampler returns in RGB for it is not
     * worth asserting and differs between implementations. Compare alpha. */
    return (fmt == D3DFMT_A8) ? 0xff000000u : 0xffffffffu;
}

/* -------------------------------------------------------- the glyph model */

/* Per-texel content. Every channel varies with the ABSOLUTE texel position,
 * so a fragment that lands one row or one column off reads as a different
 * value rather than as a plausible one, and the low bits are non-zero so a
 * channel that was zero-filled is distinguishable from a channel that was
 * written with a small value. */
static unsigned int glyph_argb( unsigned int i, unsigned int x, unsigned int y )
{
    unsigned int a = (((x * 5u + y * 3u + i * 11u) & 0x3fu) << 2) | 3u;
    unsigned int r = ((x & 0x3fu) << 2) | 1u;
    unsigned int g = ((y & 0x3fu) << 2) | 2u;
    unsigned int b = ((((x + y) ^ (i * 7u)) & 0x3fu) << 2) | 3u;
    return (a << 24) | (r << 16) | (g << 8) | b;
}

/* The update rectangles, in application order. Chosen so that the set covers
 * every shape that breaks a different piece of the offset arithmetic:
 * odd left edges, 1-texel widths and heights, a full-width single row, rects
 * flush against the right and bottom edges, and a pair that OVERLAP (22 and
 * 23) so last-write-wins ordering is observable. */
static const unsigned short g_glyph[NGLYPH][4] =
{
    {  0,  0,  7, 12 }, {  8,  1, 15, 13 }, { 16,  0, 17, 12 },
    { 18,  2, 29, 14 }, { 30,  0, 45,  9 }, { 46,  3, 64, 14 },

    {  0, 15,  3, 29 }, {  5, 16,  6, 17 }, {  7, 20, 33, 21 },
    { 35, 15, 50, 29 }, { 51, 18, 63, 28 }, {  1, 22,  2, 29 },

    {  0, 30, 64, 31 }, {  3, 32, 19, 46 }, { 21, 33, 22, 46 },
    { 23, 35, 41, 45 }, { 43, 30, 44, 44 }, { 45, 36, 60, 46 },

    {  0, 47, 17, 64 }, { 19, 48, 20, 63 }, { 22, 50, 39, 64 },
    { 41, 47, 42, 48 }, { 43, 52, 63, 63 }, { 60, 58, 64, 64 },
};

static void glyph_rect( unsigned int i, RECT *r )
{
    r->left   = g_glyph[i][0];
    r->top    = g_glyph[i][1];
    r->right  = g_glyph[i][2];
    r->bottom = g_glyph[i][3];
}

/* Write glyph `i` into locked bytes. `bits` addresses the texel whose
 * CONTENT coordinate is (cx, cy) -- for a direct sub-rect lock that is the
 * rect's own corner, and for the UpdateSurface staging path it is the corner
 * the rect will land on in the destination, which is what the content must be
 * authored for. */
static void write_glyph_bits( D3DFORMAT fmt, unsigned char *bits, int pitch,
                              const RECT *r, unsigned int i,
                              unsigned int cx, unsigned int cy )
{
    unsigned int bpt = bytes_per_texel( fmt );
    LONG y, x;
    for (y = r->top; y < r->bottom; y++)
    {
        unsigned char *row = bits + (ptrdiff_t)(y - r->top) * pitch;
        for (x = r->left; x < r->right; x++)
            put_texel( fmt, row + (ptrdiff_t)(x - r->left) * bpt,
                       glyph_argb( i, cx + (unsigned int)(x - r->left),
                                      cy + (unsigned int)(y - r->top) ) );
    }
}

/* Record in the CPU-side expected image what the render target must show
 * after glyph `i` has landed at `r`. */
static void expect_glyph( unsigned int *exp, D3DFORMAT fmt, const RECT *r, unsigned int i )
{
    LONG y, x;
    for (y = r->top; y < r->bottom; y++)
        for (x = r->left; x < r->right; x++)
            exp[y * TEX_W + x] = sampled_argb( fmt, glyph_argb( i, (unsigned int)x, (unsigned int)y ) );
}

static void expect_fill( unsigned int *exp, D3DFORMAT fmt, unsigned int argb )
{
    unsigned int i, v = sampled_argb( fmt, argb );
    for (i = 0; i < TEX_W * TEX_H; i++) exp[i] = v;
}

/* --------------------------------------------------------------- plumbing */

static unsigned int g_exp[TEX_W * TEX_H];     /* what the RT must show        */
static unsigned int g_got[RT_W  * RT_H];      /* what it did show             */
static unsigned int g_src[TEX_W * TEX_H];     /* case 76's source image       */

struct vertex                                 /* D3DFVF_XYZRHW | D3DFVF_TEX1 */
{
    float x, y, z, rhw;
    float u, v;
};

static void pump_messages( void )
{
    MSG msg;
    while (PeekMessageA( &msg, NULL, 0, 0, PM_REMOVE ))
    {
        TranslateMessage( &msg );
        DispatchMessageA( &msg );
    }
}

/* Draw `tex` 1:1 over the render target with a point sampler and read the
 * result back. The -0.5 screen-space offset is D3D9's half-pixel rule, which
 * with a 1:1 mapping and a point filter puts texel (x,y) in pixel (x,y). */
static BOOL render_and_read( IDirect3DDevice9 *dev, IDirect3DSurface9 *rt,
                             IDirect3DSurface9 *sysmem, IDirect3DBaseTexture9 *tex,
                             unsigned int *out )
{
    struct vertex quad[4];
    D3DLOCKED_RECT lr;
    HRESULT hr;
    unsigned int y, i;

    quad[0].x = -0.5f;              quad[0].y = -0.5f;              quad[0].u = 0.0f; quad[0].v = 0.0f;
    quad[1].x = (float)RT_W - 0.5f; quad[1].y = -0.5f;              quad[1].u = 1.0f; quad[1].v = 0.0f;
    quad[2].x = -0.5f;              quad[2].y = (float)RT_H - 0.5f; quad[2].u = 0.0f; quad[2].v = 1.0f;
    quad[3].x = (float)RT_W - 0.5f; quad[3].y = (float)RT_H - 0.5f; quad[3].u = 1.0f; quad[3].v = 1.0f;
    for (i = 0; i < 4; i++) { quad[i].z = 0.0f; quad[i].rhw = 1.0f; }

    hr = IDirect3DDevice9_SetRenderTarget( dev, 0, rt );
    if (FAILED(hr)) { log_hr( "SetRenderTarget", hr ); return FALSE; }

    /* Magenta: an untouched target is obvious rather than looking like a
     * plausible black, and it is not a value any glyph can produce. */
    IDirect3DDevice9_Clear( dev, 0, NULL, D3DCLEAR_TARGET, 0xFFFF00FF, 1.0f, 0 );

    IDirect3DDevice9_SetTexture( dev, 0, tex );
    IDirect3DDevice9_BeginScene( dev );
    hr = IDirect3DDevice9_DrawPrimitiveUP( dev, D3DPT_TRIANGLESTRIP, 2, quad, sizeof(quad[0]) );
    IDirect3DDevice9_EndScene( dev );
    IDirect3DDevice9_SetTexture( dev, 0, NULL );
    if (FAILED(hr)) { log_hr( "DrawPrimitiveUP", hr ); return FALSE; }

    hr = IDirect3DDevice9_GetRenderTargetData( dev, rt, sysmem );
    if (FAILED(hr)) { log_hr( "GetRenderTargetData", hr ); return FALSE; }

    memset( &lr, 0, sizeof(lr) );
    hr = IDirect3DSurface9_LockRect( sysmem, &lr, NULL, D3DLOCK_READONLY );
    if (FAILED(hr) || !lr.pBits) { log_hr( "readback LockRect", hr ); return FALSE; }
    for (y = 0; y < RT_H; y++)
    {
        const unsigned char *base = (const unsigned char *)lr.pBits;
        const unsigned int *row = (const unsigned int *)(base + (ptrdiff_t)y * lr.Pitch);
        for (i = 0; i < RT_W; i++) out[y * RT_W + i] = row[i];
    }
    IDirect3DSurface9_UnlockRect( sysmem );
    return TRUE;
}

/* End the frame the way the application under study does. The backbuffer blit
 * is cosmetic (it makes a device run visible) and its result is deliberately
 * ignored so a StretchRect defect cannot fail an unrelated case. */
static void end_frame( IDirect3DDevice9 *dev, IDirect3DSurface9 *rt )
{
    IDirect3DSurface9 *back = NULL;
    if (SUCCEEDED(IDirect3DDevice9_GetBackBuffer( dev, 0, 0, D3DBACKBUFFER_TYPE_MONO, &back )) && back)
    {
        IDirect3DDevice9_StretchRect( dev, rt, NULL, back, NULL, D3DTEXF_NONE );
        IDirect3DSurface9_Release( back );
    }
    IDirect3DDevice9_Present( dev, NULL, NULL, NULL, NULL );
    pump_messages();
}

/* ------------------------------------------------- the progressive cases  */

enum update_mode
{
    MODE_LOCK,          /* plain sub-rect LockRect / UnlockRect on the level  */
    MODE_LOCK_NOOVER,   /* DISCARD on the seeding lock, NOOVERWRITE after     */
    MODE_UPDATESURFACE, /* stage in SYSTEMMEM, UpdateSurface(RECT, POINT)     */
    MODE_UPDATETEXTURE  /* NO_DIRTY_UPDATE locks + AddDirtyRect + UpdateTexture */
};

/* Build one texture out of NGLYPH sub-rect updates spread over NFRAME frames,
 * comparing the whole image after the seeding frame and after every frame.
 * Returns FALSE only on a setup failure. */
static BOOL run_progressive( IDirect3DDevice9 *dev, IDirect3DSurface9 *rt, IDirect3DSurface9 *sysmem,
                             D3DFORMAT fmt, D3DPOOL pool, DWORD usage, enum update_mode mode )
{
    IDirect3DTexture9 *tex = NULL;      /* what the draw samples              */
    IDirect3DTexture9 *staging = NULL;  /* SYSTEMMEM source for the two       */
    IDirect3DSurface9 *tex_surf = NULL; /* copy-based modes                   */
    IDirect3DSurface9 *stage_surf = NULL;
    D3DLOCKED_RECT lr;
    unsigned int mask = format_mask( fmt );
    unsigned int f, g, i;
    int noover = 1;                     /* cleared if the runtime refuses it  */
    HRESULT hr;
    BOOL ok = TRUE;

    hr = IDirect3DDevice9_CreateTexture( dev, TEX_W, TEX_H, 1, usage, fmt, pool, &tex, NULL );
    if (FAILED(hr) || !tex) { case_skip( "CreateTexture refused" ); return TRUE; }

    if (mode == MODE_UPDATESURFACE || mode == MODE_UPDATETEXTURE)
    {
        hr = IDirect3DDevice9_CreateTexture( dev, TEX_W, TEX_H, 1, 0, fmt, D3DPOOL_SYSTEMMEM, &staging, NULL );
        if (FAILED(hr) || !staging) { case_skip( "SYSTEMMEM CreateTexture refused" ); goto done; }
        if (FAILED(IDirect3DTexture9_GetSurfaceLevel( tex, 0, &tex_surf )) ||
            FAILED(IDirect3DTexture9_GetSurfaceLevel( staging, 0, &stage_surf )))
        { case_skip( "GetSurfaceLevel refused" ); goto done; }
    }

    /* ---- seeding frame: one full-extent write, then one verified draw ---- */
    {
        IDirect3DTexture9 *seed = (mode == MODE_UPDATESURFACE || mode == MODE_UPDATETEXTURE) ? staging : tex;
        DWORD seed_flags = (mode == MODE_LOCK_NOOVER) ? D3DLOCK_DISCARD : 0;
        unsigned int bpt = bytes_per_texel( fmt );
        LONG y, x;

        memset( &lr, 0, sizeof(lr) );
        hr = IDirect3DTexture9_LockRect( seed, 0, &lr, NULL, seed_flags );
        if (FAILED(hr) || !lr.pBits)
        {
            /* A DISCARD lock the runtime refuses is a flag question, not a
             * pixel result: say so and stop rather than reporting pixels. */
            if (seed_flags) { case_skip( "DISCARD lock refused" ); goto done; }
            log_hr( "seed LockRect", hr ); ok = FALSE; goto done;
        }
        for (y = 0; y < TEX_H; y++)
        {
            unsigned char *row = (unsigned char *)lr.pBits + (ptrdiff_t)y * lr.Pitch;
            for (x = 0; x < TEX_W; x++) put_texel( fmt, row + (ptrdiff_t)x * bpt, BG_ARGB );
        }
        IDirect3DTexture9_UnlockRect( seed, 0 );
        if (mode == MODE_UPDATESURFACE)
        {
            hr = IDirect3DDevice9_UpdateSurface( dev, stage_surf, NULL, tex_surf, NULL );
            if (FAILED(hr)) { case_skip( "UpdateSurface refused" ); goto done; }
        }
        else if (mode == MODE_UPDATETEXTURE)
        {
            hr = IDirect3DDevice9_UpdateTexture( dev, (IDirect3DBaseTexture9 *)staging,
                                                 (IDirect3DBaseTexture9 *)tex );
            if (FAILED(hr)) { case_skip( "UpdateTexture refused" ); goto done; }
        }
        expect_fill( g_exp, fmt, BG_ARGB );
        if (!render_and_read( dev, rt, sysmem, (IDirect3DBaseTexture9 *)tex, g_got )) { ok = FALSE; goto done; }
        case_compare( g_got, g_exp, mask, 0 );
        end_frame( dev, rt );
    }

    /* ---- the progressive frames -------------------------------------- */
    for (f = 0; f < NFRAME; f++)
    {
        for (g = 0; g < GLYPH_PER_FRAME; g++)
        {
            RECT r, src;
            POINT dst;
            i = f * GLYPH_PER_FRAME + g;
            glyph_rect( i, &r );

            if (mode == MODE_LOCK || mode == MODE_LOCK_NOOVER)
            {
                DWORD flags = (mode == MODE_LOCK_NOOVER && noover) ? D3DLOCK_NOOVERWRITE : 0;
                memset( &lr, 0, sizeof(lr) );
                hr = IDirect3DTexture9_LockRect( tex, 0, &lr, &r, flags );
                if ((FAILED(hr) || !lr.pBits) && flags)
                {
                    /* The stock runtime validates D3DLOCK_NOOVERWRITE as a
                     * vertex/index-buffer flag and rejects it on an image. That
                     * is the reference answer, so drop the flag and keep the
                     * case running: what it is really here to prove is that a
                     * DISCARD seeding lock followed by many small sub-rect
                     * locks still accumulates. Said once per run. */
                    log_line( "note: D3DLOCK_NOOVERWRITE refused on an image lock; continuing with plain sub-rect locks" );
                    noover = 0;
                    flags = 0;
                    memset( &lr, 0, sizeof(lr) );
                    hr = IDirect3DTexture9_LockRect( tex, 0, &lr, &r, flags );
                }
                if (FAILED(hr) || !lr.pBits)
                {
                    log_hr( "sub-rect LockRect", hr ); ok = FALSE; goto done;
                }
                write_glyph_bits( fmt, (unsigned char *)lr.pBits, lr.Pitch, &r, i,
                                  (unsigned int)r.left, (unsigned int)r.top );
                hr = IDirect3DTexture9_UnlockRect( tex, 0 );
                if (FAILED(hr)) { log_hr( "sub-rect UnlockRect", hr ); ok = FALSE; goto done; }
            }
            else if (mode == MODE_UPDATESURFACE)
            {
                /* Stage the fragment at a corner that is NOT its destination
                 * corner, alternating between the staging surface's origin and
                 * its far corner, so a copy that ignores either the source RECT
                 * or the destination POINT lands visibly wrong. */
                LONG w = r.right - r.left, h = r.bottom - r.top;
                RECT stage;
                if (i & 1) { stage.left = TEX_W - w; stage.top = TEX_H - h; }
                else       { stage.left = 0;         stage.top = 0;         }
                stage.right  = stage.left + w;
                stage.bottom = stage.top  + h;

                memset( &lr, 0, sizeof(lr) );
                hr = IDirect3DTexture9_LockRect( staging, 0, &lr, &stage, 0 );
                if (FAILED(hr) || !lr.pBits) { log_hr( "staging LockRect", hr ); ok = FALSE; goto done; }
                write_glyph_bits( fmt, (unsigned char *)lr.pBits, lr.Pitch, &stage, i,
                                  (unsigned int)r.left, (unsigned int)r.top );
                IDirect3DTexture9_UnlockRect( staging, 0 );

                src = stage;
                dst.x = r.left; dst.y = r.top;
                hr = IDirect3DDevice9_UpdateSurface( dev, stage_surf, &src, tex_surf, &dst );
                if (FAILED(hr)) { log_hr( "UpdateSurface", hr ); ok = FALSE; goto done; }
            }
            else /* MODE_UPDATETEXTURE */
            {
                /* NO_DIRTY_UPDATE suppresses the implicit dirty record, so the
                 * explicit AddDirtyRect is the ONLY thing that can carry the
                 * fragment into the UpdateTexture below. */
                memset( &lr, 0, sizeof(lr) );
                hr = IDirect3DTexture9_LockRect( staging, 0, &lr, &r, D3DLOCK_NO_DIRTY_UPDATE );
                if (FAILED(hr) || !lr.pBits) { log_hr( "NO_DIRTY_UPDATE LockRect", hr ); ok = FALSE; goto done; }
                write_glyph_bits( fmt, (unsigned char *)lr.pBits, lr.Pitch, &r, i,
                                  (unsigned int)r.left, (unsigned int)r.top );
                IDirect3DTexture9_UnlockRect( staging, 0 );
                hr = IDirect3DTexture9_AddDirtyRect( staging, &r );
                if (FAILED(hr)) { log_hr( "AddDirtyRect", hr ); ok = FALSE; goto done; }
            }
            expect_glyph( g_exp, fmt, &r, i );
        }

        if (mode == MODE_UPDATETEXTURE)
        {
            hr = IDirect3DDevice9_UpdateTexture( dev, (IDirect3DBaseTexture9 *)staging,
                                                 (IDirect3DBaseTexture9 *)tex );
            if (FAILED(hr)) { log_hr( "UpdateTexture", hr ); ok = FALSE; goto done; }
        }

        if (!render_and_read( dev, rt, sysmem, (IDirect3DBaseTexture9 *)tex, g_got )) { ok = FALSE; goto done; }
        case_compare( g_got, g_exp, mask, f + 1 );
        end_frame( dev, rt );
    }

done:
    if (stage_surf) IDirect3DSurface9_Release( stage_surf );
    if (tex_surf)   IDirect3DSurface9_Release( tex_surf );
    if (staging)    IDirect3DTexture9_Release( staging );
    if (tex)        IDirect3DTexture9_Release( tex );
    return ok;
}

/* Run one progressive case end to end, including the case bookkeeping. */
static BOOL do_case( IDirect3DDevice9 *dev, IDirect3DSurface9 *rt, IDirect3DSurface9 *sysmem,
                     const char *name, int code, D3DFORMAT fmt, D3DPOOL pool, DWORD usage,
                     enum update_mode mode )
{
    BOOL ok;
    case_begin( name, code );
    ok = run_progressive( dev, rt, sysmem, fmt, pool, usage, mode );
    case_end();
    return ok;
}

/* --------------------------------- case 73: READONLY re-lock preservation */

/* Compare a locked region's raw bytes against what put_texel would have
 * stored there. Counts into the current case exactly like a pixel compare so
 * one report shape covers both. */
static void check_bytes( D3DFORMAT fmt, const unsigned char *bits, int pitch, const RECT *r,
                         int is_glyph, unsigned int i, unsigned int frame )
{
    unsigned int bpt = bytes_per_texel( fmt );
    unsigned char want[4];
    LONG y, x;
    unsigned int k;
    for (y = r->top; y < r->bottom; y++)
    {
        const unsigned char *row = bits + (ptrdiff_t)(y - r->top) * pitch;
        for (x = r->left; x < r->right; x++)
        {
            const unsigned char *have = row + (ptrdiff_t)(x - r->left) * bpt;
            unsigned int gv = 0, wv = 0;
            memset( want, 0, sizeof(want) );
            put_texel( fmt, want, is_glyph ? glyph_argb( i, (unsigned int)x, (unsigned int)y ) : BG_ARGB );
            for (k = 0; k < bpt; k++) { gv |= (unsigned int)have[k] << (8 * k); wv |= (unsigned int)want[k] << (8 * k); }
            if (gv == wv) continue;
            if (!g_case.bad)
            {
                g_case.frame = frame;
                g_case.x = (unsigned int)x; g_case.y = (unsigned int)y;
                g_case.got = gv; g_case.want = wv;
            }
            ++g_case.bad;
        }
    }
}

static BOOL case_readonly_relock( IDirect3DDevice9 *dev, IDirect3DSurface9 *rt, IDirect3DSurface9 *sysmem )
{
    IDirect3DTexture9 *tex = NULL;
    const D3DFORMAT fmt = D3DFMT_A8R8G8B8;
    D3DLOCKED_RECT lr;
    RECT r0, r1;
    HRESULT hr;
    LONG y, x;
    BOOL ok = TRUE;

    case_begin( "readonly.relock", 73 );
    hr = IDirect3DDevice9_CreateTexture( dev, TEX_W, TEX_H, 1, 0, fmt, D3DPOOL_MANAGED, &tex, NULL );
    if (FAILED(hr) || !tex) { case_skip( "CreateTexture refused" ); case_end(); return TRUE; }

    memset( &lr, 0, sizeof(lr) );
    hr = IDirect3DTexture9_LockRect( tex, 0, &lr, NULL, 0 );
    if (FAILED(hr) || !lr.pBits) { log_hr( "relock seed LockRect", hr ); ok = FALSE; goto done; }
    for (y = 0; y < TEX_H; y++)
    {
        unsigned char *row = (unsigned char *)lr.pBits + (ptrdiff_t)y * lr.Pitch;
        for (x = 0; x < TEX_W; x++) put_texel( fmt, row + (ptrdiff_t)x * 4, BG_ARGB );
    }
    IDirect3DTexture9_UnlockRect( tex, 0 );

    glyph_rect( 3, &r0 );
    glyph_rect( 9, &r1 );
    memset( &lr, 0, sizeof(lr) );
    hr = IDirect3DTexture9_LockRect( tex, 0, &lr, &r0, 0 );
    if (FAILED(hr) || !lr.pBits) { log_hr( "relock write LockRect", hr ); ok = FALSE; goto done; }
    write_glyph_bits( fmt, (unsigned char *)lr.pBits, lr.Pitch, &r0, 3,
                      (unsigned int)r0.left, (unsigned int)r0.top );
    IDirect3DTexture9_UnlockRect( tex, 0 );

    expect_fill( g_exp, fmt, BG_ARGB );
    expect_glyph( g_exp, fmt, &r0, 3 );

    /* A draw + Present between the write and the re-locks, so any deferred
     * upload, mirror eviction or staging recycle has happened by the time the
     * application asks to read its own bytes back. */
    if (!render_and_read( dev, rt, sysmem, (IDirect3DBaseTexture9 *)tex, g_got )) { ok = FALSE; goto done; }
    case_compare( g_got, g_exp, 0xffffffffu, 1 );
    end_frame( dev, rt );

    /* READONLY re-lock of the rect that was written: the bytes must still be
     * there. This is the "lock, read, modify, write back" shape a text engine
     * uses to composite a glyph over what it already drew. */
    memset( &lr, 0, sizeof(lr) );
    hr = IDirect3DTexture9_LockRect( tex, 0, &lr, &r0, D3DLOCK_READONLY );
    if (FAILED(hr) || !lr.pBits) { log_hr( "READONLY LockRect(written)", hr ); ok = FALSE; goto done; }
    check_bytes( fmt, (const unsigned char *)lr.pBits, lr.Pitch, &r0, 1, 3, 2 );
    IDirect3DTexture9_UnlockRect( tex, 0 );

    /* READONLY re-lock of a rect that was NOT written: still the background. */
    memset( &lr, 0, sizeof(lr) );
    hr = IDirect3DTexture9_LockRect( tex, 0, &lr, &r1, D3DLOCK_READONLY );
    if (FAILED(hr) || !lr.pBits) { log_hr( "READONLY LockRect(untouched)", hr ); ok = FALSE; goto done; }
    check_bytes( fmt, (const unsigned char *)lr.pBits, lr.Pitch, &r1, 0, 0, 3 );
    IDirect3DTexture9_UnlockRect( tex, 0 );

    /* Whole-level READONLY lock: the written band must be there when the lock
     * covers the level rather than the rect. */
    memset( &lr, 0, sizeof(lr) );
    hr = IDirect3DTexture9_LockRect( tex, 0, &lr, NULL, D3DLOCK_READONLY );
    if (FAILED(hr) || !lr.pBits) { log_hr( "READONLY LockRect(full)", hr ); ok = FALSE; goto done; }
    {
        RECT band = r0;
        check_bytes( fmt, (const unsigned char *)lr.pBits + (ptrdiff_t)band.top * lr.Pitch + band.left * 4,
                     lr.Pitch, &band, 1, 3, 4 );
    }
    IDirect3DTexture9_UnlockRect( tex, 0 );

    /* And the READONLY locks must not have damaged the texture: draw again. */
    if (!render_and_read( dev, rt, sysmem, (IDirect3DBaseTexture9 *)tex, g_got )) { ok = FALSE; goto done; }
    case_compare( g_got, g_exp, 0xffffffffu, 5 );
    end_frame( dev, rt );

done:
    if (tex) IDirect3DTexture9_Release( tex );
    case_end();
    return ok;
}

/* ------------------------------------------- case 74: GetDC / ReleaseDC   */

#define DC_C1 0x00204060u      /* whole-surface fill, canonical 0x00RRGGBB  */
#define DC_C2 0x00C08040u      /* sub-rect fill                             */
#define DC_TEXT_TOP    40
#define DC_TEXT_BOTTOM 58

static COLORREF argb_to_colorref( unsigned int rgb )
{
    return RGB( (rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff );
}

static BOOL case_getdc( IDirect3DDevice9 *dev, IDirect3DSurface9 *rt, IDirect3DSurface9 *sysmem )
{
    IDirect3DTexture9 *tex = NULL;
    IDirect3DSurface9 *surf = NULL;
    const D3DFORMAT fmt = D3DFMT_X8R8G8B8;
    HDC hdc = NULL;
    HBRUSH b1 = NULL, b2 = NULL;
    RECT full, sub;
    HRESULT hr;
    LONG y, x;
    unsigned int changed = 0;
    BOOL ok = TRUE;

    case_begin( "getdc.xrgb8", 74 );
    hr = IDirect3DDevice9_CreateTexture( dev, TEX_W, TEX_H, 1, 0, fmt, D3DPOOL_MANAGED, &tex, NULL );
    if (FAILED(hr) || !tex) { case_skip( "CreateTexture X8R8G8B8 refused" ); case_end(); return TRUE; }
    hr = IDirect3DTexture9_GetSurfaceLevel( tex, 0, &surf );
    if (FAILED(hr) || !surf) { case_skip( "GetSurfaceLevel refused" ); goto done; }

    hr = IDirect3DSurface9_GetDC( surf, &hdc );
    if (FAILED(hr) || !hdc) { case_skip( "GetDC refused" ); hdc = NULL; goto done; }

    full.left = 0; full.top = 0; full.right = TEX_W; full.bottom = TEX_H;
    sub.left = 4; sub.top = 4; sub.right = 40; sub.bottom = 30;
    b1 = CreateSolidBrush( argb_to_colorref( DC_C1 ) );
    b2 = CreateSolidBrush( argb_to_colorref( DC_C2 ) );
    if (b1) FillRect( hdc, &full, b1 );
    if (b2) FillRect( hdc, &sub,  b2 );

    /* GDI text: a glyph raster is not reproducible across font sets, so the
     * assertion is only that GDI text REACHED the surface -- the band must
     * stop being a flat fill. The opaque background box makes that true even
     * if the font substitutes. */
    SetBkMode( hdc, OPAQUE );
    SetBkColor( hdc, argb_to_colorref( 0x00FFFFFFu ) );
    SetTextColor( hdc, argb_to_colorref( 0x00000000u ) );
    TextOutA( hdc, 4, DC_TEXT_TOP + 1, "Madeira", 7 );

    hr = IDirect3DSurface9_ReleaseDC( surf, hdc );
    hdc = NULL;
    if (FAILED(hr)) { log_hr( "ReleaseDC", hr ); ok = FALSE; goto done; }

    /* Expected: C1 everywhere, C2 in the sub-rect, and the text band excluded
     * from the exact comparison (checked separately just below). X8R8G8B8
     * must sample opaque even though the stored X byte is whatever GDI left. */
    for (y = 0; y < TEX_H; y++)
        for (x = 0; x < TEX_W; x++)
        {
            unsigned int v = (x >= sub.left && x < sub.right && y >= sub.top && y < sub.bottom) ? DC_C2 : DC_C1;
            if (y >= DC_TEXT_TOP && y < DC_TEXT_BOTTOM) v = 0;   /* masked below */
            g_exp[y * TEX_W + x] = 0xff000000u | v;
        }

    if (!render_and_read( dev, rt, sysmem, (IDirect3DBaseTexture9 *)tex, g_got )) { ok = FALSE; goto done; }
    for (y = 0; y < TEX_H; y++)
    {
        if (y >= DC_TEXT_TOP && y < DC_TEXT_BOTTOM) continue;
        for (x = 0; x < TEX_W; x++)
        {
            unsigned int idx = y * TEX_W + x;
            if (texel_ok( g_got[idx], g_exp[idx], 0xffffffffu )) continue;
            if (!g_case.bad)
            {
                g_case.frame = 1;
                g_case.x = (unsigned int)x; g_case.y = (unsigned int)y;
                g_case.got = g_got[idx]; g_case.want = g_exp[idx];
            }
            ++g_case.bad;
        }
    }
    for (y = DC_TEXT_TOP; y < DC_TEXT_BOTTOM; y++)
        for (x = 0; x < TEX_W; x++)
            if (!texel_ok( g_got[y * TEX_W + x], 0xff000000u | DC_C1, 0xffffffffu )) ++changed;
    if (!changed)
    {
        log_line( "getdc.xrgb8: no pixel in the text band differs from the fill -- GDI text did not reach the surface" );
        if (!g_case.bad)
        {
            g_case.frame = 1; g_case.x = 0; g_case.y = DC_TEXT_TOP;
            g_case.got = g_got[DC_TEXT_TOP * TEX_W]; g_case.want = 0;
        }
        ++g_case.bad;
    }
    end_frame( dev, rt );

done:
    if (hdc) IDirect3DSurface9_ReleaseDC( surf, hdc );
    if (b1) DeleteObject( b1 );
    if (b2) DeleteObject( b2 );
    if (surf) IDirect3DSurface9_Release( surf );
    if (tex) IDirect3DTexture9_Release( tex );
    case_end();
    return ok;
}

/* ----------------------------- cases 75 / 76: ColorFill and StretchRect   */

/* Builds a known image in a DEFAULT render-target texture with sub-rect
 * ColorFills spread over frames, verifies it, and leaves the expected image
 * in g_src for the StretchRect case to reuse. */
static BOOL case_colorfill( IDirect3DDevice9 *dev, IDirect3DSurface9 *rt, IDirect3DSurface9 *sysmem,
                            IDirect3DTexture9 **out_tex )
{
    IDirect3DTexture9 *tex = NULL;
    IDirect3DSurface9 *surf = NULL;
    const D3DFORMAT fmt = D3DFMT_A8R8G8B8;
    unsigned int f, g, i;
    HRESULT hr;
    BOOL ok = TRUE;

    case_begin( "colorfill.rect", 75 );
    hr = IDirect3DDevice9_CreateTexture( dev, TEX_W, TEX_H, 1, D3DUSAGE_RENDERTARGET, fmt,
                                         D3DPOOL_DEFAULT, &tex, NULL );
    if (FAILED(hr) || !tex) { case_skip( "CreateTexture RENDERTARGET refused" ); case_end(); return TRUE; }
    hr = IDirect3DTexture9_GetSurfaceLevel( tex, 0, &surf );
    if (FAILED(hr) || !surf) { case_skip( "GetSurfaceLevel refused" ); goto done; }

    hr = IDirect3DDevice9_ColorFill( dev, surf, NULL, (D3DCOLOR)BG_ARGB );
    if (FAILED(hr)) { case_skip( "ColorFill refused" ); goto done; }
    expect_fill( g_exp, fmt, BG_ARGB );
    if (!render_and_read( dev, rt, sysmem, (IDirect3DBaseTexture9 *)tex, g_got )) { ok = FALSE; goto done; }
    case_compare( g_got, g_exp, 0xffffffffu, 0 );
    end_frame( dev, rt );

    for (f = 0; f < NFRAME; f++)
    {
        for (g = 0; g < GLYPH_PER_FRAME; g++)
        {
            RECT r;
            unsigned int colour;
            LONG y, x;
            i = f * GLYPH_PER_FRAME + g;
            glyph_rect( i, &r );
            colour = glyph_argb( i, i * 3u, i * 5u );
            hr = IDirect3DDevice9_ColorFill( dev, surf, &r, (D3DCOLOR)colour );
            if (FAILED(hr)) { log_hr( "ColorFill sub-rect", hr ); ok = FALSE; goto done; }
            for (y = r.top; y < r.bottom; y++)
                for (x = r.left; x < r.right; x++) g_exp[y * TEX_W + x] = colour;
        }
        if (!render_and_read( dev, rt, sysmem, (IDirect3DBaseTexture9 *)tex, g_got )) { ok = FALSE; goto done; }
        case_compare( g_got, g_exp, 0xffffffffu, f + 1 );
        end_frame( dev, rt );
    }

    for (i = 0; i < TEX_W * TEX_H; i++) g_src[i] = g_exp[i];
    *out_tex = tex;
    tex = NULL;                    /* handed to the caller */

done:
    if (surf) IDirect3DSurface9_Release( surf );
    if (tex) IDirect3DTexture9_Release( tex );
    case_end();
    return ok;
}

static BOOL case_stretchrect( IDirect3DDevice9 *dev, IDirect3DSurface9 *rt, IDirect3DSurface9 *sysmem,
                              IDirect3DTexture9 *srctex )
{
    IDirect3DSurface9 *src = NULL;
    D3DLOCKED_RECT lr;
    RECT s, d;
    HRESULT hr;
    LONG y, x;
    BOOL ok = TRUE;

    case_begin( "stretchrect.sub", 76 );
    if (!srctex) { case_skip( "no source texture (the ColorFill case did not produce one)" ); case_end(); return TRUE; }
    hr = IDirect3DTexture9_GetSurfaceLevel( srctex, 0, &src );
    if (FAILED(hr) || !src) { case_skip( "GetSurfaceLevel refused" ); case_end(); return TRUE; }

    /* 1:1, and deliberately at a different corner in the destination so a copy
     * that ignores either rect lands visibly wrong. */
    s.left = 5;  s.top = 7;  s.right = 37; s.bottom = 31;
    d.left = 20; d.top = 33; d.right = 52; d.bottom = 57;

    hr = IDirect3DDevice9_SetRenderTarget( dev, 0, rt );
    if (FAILED(hr)) { log_hr( "SetRenderTarget", hr ); ok = FALSE; goto done; }
    IDirect3DDevice9_Clear( dev, 0, NULL, D3DCLEAR_TARGET, 0xFFFF00FF, 1.0f, 0 );
    hr = IDirect3DDevice9_StretchRect( dev, src, &s, rt, &d, D3DTEXF_NONE );
    if (FAILED(hr)) { case_skip( "StretchRect refused" ); goto done; }

    for (y = 0; y < RT_H; y++)
        for (x = 0; x < RT_W; x++)
        {
            unsigned int v = 0xFFFF00FFu;
            if (x >= d.left && x < d.right && y >= d.top && y < d.bottom)
                v = g_src[(y - d.top + s.top) * TEX_W + (x - d.left + s.left)];
            g_exp[y * RT_W + x] = v;
        }

    hr = IDirect3DDevice9_GetRenderTargetData( dev, rt, sysmem );
    if (FAILED(hr)) { log_hr( "GetRenderTargetData", hr ); ok = FALSE; goto done; }
    memset( &lr, 0, sizeof(lr) );
    hr = IDirect3DSurface9_LockRect( sysmem, &lr, NULL, D3DLOCK_READONLY );
    if (FAILED(hr) || !lr.pBits) { log_hr( "readback LockRect", hr ); ok = FALSE; goto done; }
    for (y = 0; y < RT_H; y++)
    {
        const unsigned int *row = (const unsigned int *)((const unsigned char *)lr.pBits + (ptrdiff_t)y * lr.Pitch);
        for (x = 0; x < RT_W; x++) g_got[y * RT_W + x] = row[x];
    }
    IDirect3DSurface9_UnlockRect( sysmem );
    case_compare( g_got, g_exp, 0xffffffffu, 1 );
    end_frame( dev, rt );

done:
    if (src) IDirect3DSurface9_Release( src );
    case_end();
    return ok;
}

/* -------------------------------------------------------------------- main */

static LRESULT CALLBACK wnd_proc( HWND h, UINT msg, WPARAM wp, LPARAM lp )
{
    return DefWindowProcA( h, msg, wp, lp );
}

struct fmt_case
{
    const char *name;
    int         code;
    D3DFORMAT   fmt;
};

void start( void )
{
    WNDCLASSEXA wc;
    D3DPRESENT_PARAMETERS pp;
    HWND hwnd;
    HINSTANCE inst = GetModuleHandleA( NULL );
    IDirect3D9 *d3d;
    IDirect3DDevice9 *dev = NULL;
    IDirect3DSurface9 *rt = NULL, *sysmem = NULL;
    IDirect3DTexture9 *fill_tex = NULL;
    HRESULT hr;
    unsigned int i;
    int setup_failed = 0;

    static const struct fmt_case managed_formats[] =
    {
        { "managed.a8",       66, D3DFMT_A8       },
        { "managed.l8",       67, D3DFMT_L8       },
        { "managed.a8l8",     68, D3DFMT_A8L8     },
        { "managed.argb4444", 69, D3DFMT_A4R4G4B4 },
        { "managed.rgb565",   70, D3DFMT_R5G6B5   },
        { "managed.argb1555", 71, D3DFMT_A1R5G5B5 },
        { "managed.xrgb8",    72, D3DFMT_X8R8G8B8 },
    };

    log_line( "32-bit D3D9 partial-surface-update self-test starting" );

    memset( &wc, 0, sizeof(wc) );
    wc.cbSize        = sizeof(wc);
    wc.lpfnWndProc   = wnd_proc;
    wc.hInstance     = inst;
    wc.lpszClassName = "MadeiraD3D9LockX86";
    if (!RegisterClassExA( &wc )) { log_hr( "RegisterClassExA", (HRESULT)GetLastError() ); ExitProcess( 25 ); }
    hwnd = CreateWindowExA( 0, wc.lpszClassName, "Madeira D3D9 partial-update test (32-bit)",
                            WS_OVERLAPPEDWINDOW | WS_VISIBLE, 0, 0, 320, 240, NULL, NULL, inst, NULL );
    if (!hwnd) { log_hr( "CreateWindowExA", (HRESULT)GetLastError() ); ExitProcess( 25 ); }

    d3d = Direct3DCreate9( D3D_SDK_VERSION );
    if (!d3d) { log_line( "Direct3DCreate9 returned NULL" ); ExitProcess( 20 ); }

    memset( &pp, 0, sizeof(pp) );
    pp.Windowed             = TRUE;
    pp.SwapEffect           = D3DSWAPEFFECT_DISCARD;
    pp.BackBufferFormat     = D3DFMT_UNKNOWN;
    pp.BackBufferWidth      = 320;
    pp.BackBufferHeight     = 240;
    pp.hDeviceWindow        = hwnd;
    /* IMMEDIATE: the test must not depend on a vertical blank, on the device
     * or on a desktop. */
    pp.PresentationInterval = D3DPRESENT_INTERVAL_IMMEDIATE;
    hr = IDirect3D9_CreateDevice( d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, hwnd,
                                  D3DCREATE_SOFTWARE_VERTEXPROCESSING, &pp, &dev );
    if (FAILED(hr) || !dev) { log_hr( "CreateDevice", hr ); ExitProcess( 21 ); }

    /* Point sampling and a pass-through stage chain: the render target must
     * receive the texture's own texels, not a filtered or modulated version
     * of them, or the comparison measures the sampler instead. */
    IDirect3DDevice9_SetFVF( dev, D3DFVF_XYZRHW | D3DFVF_TEX1 );
    IDirect3DDevice9_SetSamplerState( dev, 0, D3DSAMP_MAGFILTER, D3DTEXF_POINT );
    IDirect3DDevice9_SetSamplerState( dev, 0, D3DSAMP_MINFILTER, D3DTEXF_POINT );
    IDirect3DDevice9_SetSamplerState( dev, 0, D3DSAMP_MIPFILTER, D3DTEXF_NONE );
    IDirect3DDevice9_SetSamplerState( dev, 0, D3DSAMP_ADDRESSU, D3DTADDRESS_CLAMP );
    IDirect3DDevice9_SetSamplerState( dev, 0, D3DSAMP_ADDRESSV, D3DTADDRESS_CLAMP );
    IDirect3DDevice9_SetSamplerState( dev, 0, D3DSAMP_SRGBTEXTURE, FALSE );
    IDirect3DDevice9_SetTextureStageState( dev, 0, D3DTSS_COLOROP, D3DTOP_SELECTARG1 );
    IDirect3DDevice9_SetTextureStageState( dev, 0, D3DTSS_COLORARG1, D3DTA_TEXTURE );
    IDirect3DDevice9_SetTextureStageState( dev, 0, D3DTSS_ALPHAOP, D3DTOP_SELECTARG1 );
    IDirect3DDevice9_SetTextureStageState( dev, 0, D3DTSS_ALPHAARG1, D3DTA_TEXTURE );
    IDirect3DDevice9_SetTextureStageState( dev, 1, D3DTSS_COLOROP, D3DTOP_DISABLE );
    IDirect3DDevice9_SetRenderState( dev, D3DRS_LIGHTING, FALSE );
    IDirect3DDevice9_SetRenderState( dev, D3DRS_ZENABLE, D3DZB_FALSE );
    IDirect3DDevice9_SetRenderState( dev, D3DRS_CULLMODE, D3DCULL_NONE );
    IDirect3DDevice9_SetRenderState( dev, D3DRS_ALPHABLENDENABLE, FALSE );
    IDirect3DDevice9_SetRenderState( dev, D3DRS_ALPHATESTENABLE, FALSE );
    IDirect3DDevice9_SetRenderState( dev, D3DRS_SRGBWRITEENABLE, FALSE );

    hr = IDirect3DDevice9_CreateRenderTarget( dev, RT_W, RT_H, D3DFMT_A8R8G8B8,
                                              D3DMULTISAMPLE_NONE, 0, FALSE, &rt, NULL );
    if (FAILED(hr) || !rt) { log_hr( "CreateRenderTarget", hr ); ExitProcess( 59 ); }
    hr = IDirect3DDevice9_CreateOffscreenPlainSurface( dev, RT_W, RT_H, D3DFMT_A8R8G8B8,
                                                       D3DPOOL_SYSTEMMEM, &sysmem, NULL );
    if (FAILED(hr) || !sysmem) { log_hr( "CreateOffscreenPlainSurface", hr ); ExitProcess( 59 ); }

    /* 61: the baseline. A MANAGED texture built by many small sub-rect locks,
     *     several of them inside one frame, with a draw and a Present between
     *     the frames. This is the shape the symptom was reported in. */
    if (!do_case( dev, rt, sysmem, "managed.argb8", 61, D3DFMT_A8R8G8B8,
                  D3DPOOL_MANAGED, 0, MODE_LOCK )) setup_failed = 1;

    /* 62 / 63: the same, in DEFAULT+DYNAMIC, where the lock is a streaming
     *     path rather than a sysmem mirror -- once with plain locks, once with
     *     the DISCARD-then-NOOVERWRITE flag pair applications use there. */
    if (!setup_failed && !do_case( dev, rt, sysmem, "dynamic.argb8", 62, D3DFMT_A8R8G8B8,
                                   D3DPOOL_DEFAULT, D3DUSAGE_DYNAMIC, MODE_LOCK )) setup_failed = 1;
    if (!setup_failed && !do_case( dev, rt, sysmem, "dynamic.discard", 63, D3DFMT_A8R8G8B8,
                                   D3DPOOL_DEFAULT, D3DUSAGE_DYNAMIC, MODE_LOCK_NOOVER )) setup_failed = 1;

    /* 64: the copy path. The fragment is staged at a corner that is not its
     *     destination corner, so the source RECT and the destination POINT are
     *     independently observable. */
    if (!setup_failed && !do_case( dev, rt, sysmem, "updatesurface", 64, D3DFMT_A8R8G8B8,
                                   D3DPOOL_DEFAULT, 0, MODE_UPDATESURFACE )) setup_failed = 1;

    /* 65: the dirty-region path. NO_DIRTY_UPDATE suppresses the implicit
     *     record, so only the explicit AddDirtyRect can carry each fragment
     *     into the once-per-frame UpdateTexture. */
    if (!setup_failed && !do_case( dev, rt, sysmem, "updatetexture", 65, D3DFMT_A8R8G8B8,
                                   D3DPOOL_DEFAULT, 0, MODE_UPDATETEXTURE )) setup_failed = 1;

    /* 66..72: the same progressive build in every format whose texel is not
     *     four bytes, where the per-column step and the row stride are easy to
     *     get wrong, plus X8R8G8B8 for the forced-opaque rule. */
    for (i = 0; !setup_failed && i < sizeof(managed_formats) / sizeof(managed_formats[0]); i++)
    {
        case_begin( managed_formats[i].name, managed_formats[i].code );
        hr = IDirect3D9_CheckDeviceFormat( d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL,
                                           D3DFMT_X8R8G8B8, 0, D3DRTYPE_TEXTURE, managed_formats[i].fmt );
        if (FAILED(hr)) { case_skip( "CheckDeviceFormat says the adapter has no such texture format" ); case_end(); continue; }
        if (!run_progressive( dev, rt, sysmem, managed_formats[i].fmt, D3DPOOL_MANAGED, 0, MODE_LOCK ))
            setup_failed = 1;
        case_end();
    }

    if (!setup_failed && !case_readonly_relock( dev, rt, sysmem )) setup_failed = 1;
    if (!setup_failed && !case_getdc( dev, rt, sysmem )) setup_failed = 1;
    if (!setup_failed && !case_colorfill( dev, rt, sysmem, &fill_tex )) setup_failed = 1;
    if (!setup_failed && !case_stretchrect( dev, rt, sysmem, fill_tex )) setup_failed = 1;

    if (fill_tex) IDirect3DTexture9_Release( fill_tex );
    IDirect3DSurface9_Release( sysmem );
    IDirect3DSurface9_Release( rt );
    IDirect3DDevice9_Release( dev );
    IDirect3D9_Release( d3d );
    DestroyWindow( hwnd );

    {
        char buf[256];
        char *p = put_str( buf, TAG );
        p = put_uint( p, g_cases_run );
        p = put_str( p, " cases run, " );
        p = put_uint( p, g_cases_skipped );
        p = put_str( p, " skipped, " );
        p = put_uint( p, g_cases_failed );
        p = put_str( p, " failed -- " );
        p = put_str( p, (setup_failed || g_cases_failed) ? "FAIL" : "PASS" );
        *p++ = '\n'; *p = 0;
        out_str( buf );
    }

    if (setup_failed) ExitProcess( 59 );
    ExitProcess( g_first_fail_code ? (UINT)g_first_fail_code : PASS_CODE );
}
