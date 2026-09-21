/* MADEIRA-TEMP: sysprobe-x86.exe — print, once, EVERY environment value a
 * Windows program can use to decide "is this machine real / is this install
 * valid", so that ONE device run answers what this port returns where Windows
 * returns something else.
 *
 * WHY IT EXISTS
 * -------------
 * A 32-bit engine can refuse to start with nothing in the log but a message
 * box: no file open fails, no DLL is missing, no API returns an error that
 * anybody logs.  The decision is made from ANSWERS, not from failures, and an
 * answer that is merely wrong is invisible.  Guessing which answer is wrong
 * costs one device round trip per guess; this costs one round trip for all of
 * them, and the output is diffable against the same program run on Windows.
 *
 * WHAT IT PRINTS
 * --------------
 *   [drive]   GetLogicalDrives, and per drive: GetDriveType, the full
 *             GetVolumeInformation tuple (label / serial / max component /
 *             flags / filesystem name) WITH its error code,
 *             GetDiskFreeSpace(Ex), QueryDosDevice.
 *   [path]    the well-known directories, the module path, and whether each
 *             SHGetFolderPath answer actually EXISTS on disk (shell32 only
 *             answers a per-user known folder whose directory exists).
 *   [sys]     GetVersionEx, GetSystemInfo, GlobalMemoryStatusEx,
 *             IsWow64Process, computer/user name, GetSystemMetrics.
 *   [locale]  ACP / OEMCP / system, user and thread language ids, country.
 *   [disp]    EnumDisplaySettings(ENUM_CURRENT_SETTINGS): bpp, size, refresh.
 *   [reg]     the keys an installer-era engine reads to identify Windows and
 *             the CPU, including the ones this port synthesises.
 *   [env]     the environment variables those lookups are built on.
 *
 * Every line goes to BOTH OutputDebugStringA and stderr, so it lands in the
 * exported log whichever way the runtime is capturing output.
 *
 * WHAT IT DOES NOT DO
 * -------------------
 * It asserts nothing and it can only fail by crashing: a probe that decides
 * what "correct" looks like would have to encode the very expectations that
 * are in question.  Read the output against a Windows box.  It exits 63.
 *
 * WMI is deliberately not probed here.  Reaching Win32_OperatingSystem means
 * CoInitializeEx + IWbemLocator + a BSTR/VARIANT dance, which is several
 * hundred lines of raw vtable calls in a no-CRT binary — far more risk than
 * the rest of the file put together — and the WMI traffic this port answers is
 * already visible in the log through wbemprox's own FIXMEs.
 *
 * Imports: kernel32, advapi32, shell32, user32.  No CRT (this file supplies
 * `start` plus memset/memcpy and links -nostdlib).
 *
 * Run it through the Custom path popup as
 *   C:\windows\syswow64\sysprobe-x86.exe
 * Expected: a block of [drive]/[path]/[sys]/[locale]/[disp]/[reg]/[env] lines
 * and then "MADEIRA-EXIT: sysprobe-x86.exe status=63".
 */

#include <windows.h>
#include <winreg.h>
#include <shlobj.h>

/* -nostdlib: clang may still lower a struct initialisation to memset/memcpy. */
void *memset( void *dst, int c, size_t n )
{
    unsigned char *d = dst;
    while (n--) *d++ = (unsigned char)c;
    return dst;
}

void *memcpy( void *dst, const void *src, size_t n )
{
    unsigned char *d = dst;
    const unsigned char *s = src;
    while (n--) *d++ = *s++;
    return dst;
}

/* ------------------------------------------------------------------ output */

static void out_str( const char *s )
{
    DWORD written = 0;
    const char *e = s;

    while (*e) e++;
    OutputDebugStringA( s );
    WriteFile( GetStdHandle( STD_ERROR_HANDLE ), s, (DWORD)(e - s), &written, NULL );
}

static char *put_str( char *p, const char *s )
{
    while (*s) *p++ = *s++;
    *p = 0;
    return p;
}

static char *put_uint( char *p, unsigned int v )
{
    char tmp[16];
    int n = 0;

    if (!v) { *p++ = '0'; *p = 0; return p; }
    while (v) { tmp[n++] = (char)('0' + v % 10); v /= 10; }
    while (n--) *p++ = tmp[n];
    *p = 0;
    return p;
}

static char *put_u64( char *p, unsigned __int64 v )
{
    char tmp[24];
    int n = 0;

    if (!v) { *p++ = '0'; *p = 0; return p; }
    while (v) { tmp[n++] = (char)('0' + (unsigned)(v % 10)); v /= 10; }
    while (n--) *p++ = tmp[n];
    *p = 0;
    return p;
}

static char *put_hex( char *p, unsigned int v, int digits )
{
    static const char hx[] = "0123456789abcdef";
    int i;

    *p++ = '0'; *p++ = 'x';
    for (i = digits - 1; i >= 0; i--) *p++ = hx[(v >> (i * 4)) & 0xf];
    *p = 0;
    return p;
}

/* A wide string is printed as its low bytes, with anything outside printable
 * ASCII shown as \xNN — the point is to make an empty or mojibake answer
 * unmistakable in the log, not to render Japanese. */
static char *put_wstr( char *p, const WCHAR *w )
{
    static const char hx[] = "0123456789abcdef";

    if (!w) return put_str( p, "(null)" );
    for (; *w; w++)
    {
        if (*w >= 0x20 && *w < 0x7f) *p++ = (char)*w;
        else
        {
            *p++ = '\\'; *p++ = 'x';
            *p++ = hx[(*w >> 12) & 0xf]; *p++ = hx[(*w >> 8) & 0xf];
            *p++ = hx[(*w >> 4) & 0xf];  *p++ = hx[*w & 0xf];
        }
    }
    *p = 0;
    return p;
}

static char line[4096];

static void emit( char *end )
{
    *end++ = '\n';
    *end = 0;
    out_str( line );
}

/* ------------------------------------------------------------------ drives */

static const char *drive_type_name( UINT t )
{
    switch (t)
    {
    case DRIVE_UNKNOWN:     return "UNKNOWN";
    case DRIVE_NO_ROOT_DIR: return "NO_ROOT_DIR";
    case DRIVE_REMOVABLE:   return "REMOVABLE";
    case DRIVE_FIXED:       return "FIXED";
    case DRIVE_REMOTE:      return "REMOTE";
    case DRIVE_CDROM:       return "CDROM";
    case DRIVE_RAMDISK:     return "RAMDISK";
    default:                return "?";
    }
}

static void probe_drives(void)
{
    DWORD mask = GetLogicalDrives();
    char root[4] = { 'A', ':', '\\', 0 };
    int i;
    char *p;

    p = put_str( line, "[drive] GetLogicalDrives=" );
    p = put_hex( p, mask, 8 );
    p = put_str( p, " letters=" );
    for (i = 0; i < 26; i++) if (mask & (1u << i)) *p++ = (char)('A' + i);
    *p = 0;
    emit( p );

    for (i = 0; i < 26; i++)
    {
        char label[MAX_PATH + 1], fsname[MAX_PATH + 1], target[512];
        DWORD serial = 0xdeadbeef, maxcomp = 0, flags = 0, err, tlen;
        ULARGE_INTEGER avail, total, freebytes;
        DWORD spc = 0, bps = 0, freecl = 0, totcl = 0;
        UINT type;
        BOOL ok;

        if (!(mask & (1u << i))) continue;
        root[0] = (char)('A' + i);

        type = GetDriveTypeA( root );

        label[0] = fsname[0] = 0;
        SetLastError( 0 );
        ok = GetVolumeInformationA( root, label, MAX_PATH, &serial, &maxcomp, &flags,
                                    fsname, MAX_PATH );
        err = GetLastError();

        p = put_str( line, "[drive] " );
        p = put_str( p, root );
        p = put_str( p, " type=" );
        p = put_uint( p, type );
        p = put_str( p, "(" );
        p = put_str( p, drive_type_name( type ) );
        p = put_str( p, ") volinfo=" );
        p = put_uint( p, (unsigned)ok );
        p = put_str( p, " err=" );
        p = put_uint( p, err );
        p = put_str( p, " serial=" );
        p = put_hex( p, serial, 8 );
        p = put_str( p, " label='" );
        p = put_str( p, label );
        p = put_str( p, "' fs='" );
        p = put_str( p, fsname );
        p = put_str( p, "' maxcomp=" );
        p = put_uint( p, maxcomp );
        p = put_str( p, " flags=" );
        p = put_hex( p, flags, 8 );
        emit( p );

        avail.QuadPart = total.QuadPart = freebytes.QuadPart = 0;
        SetLastError( 0 );
        ok = GetDiskFreeSpaceExA( root, &avail, &total, &freebytes );
        err = GetLastError();
        p = put_str( line, "[drive] " );
        p = put_str( p, root );
        p = put_str( p, " freeEx=" );
        p = put_uint( p, (unsigned)ok );
        p = put_str( p, " err=" );
        p = put_uint( p, err );
        p = put_str( p, " availMB=" );
        p = put_u64( p, avail.QuadPart >> 20 );
        p = put_str( p, " totalMB=" );
        p = put_u64( p, total.QuadPart >> 20 );
        p = put_str( p, " freeMB=" );
        p = put_u64( p, freebytes.QuadPart >> 20 );
        emit( p );

        SetLastError( 0 );
        ok = GetDiskFreeSpaceA( root, &spc, &bps, &freecl, &totcl );
        err = GetLastError();
        p = put_str( line, "[drive] " );
        p = put_str( p, root );
        p = put_str( p, " free=" );
        p = put_uint( p, (unsigned)ok );
        p = put_str( p, " err=" );
        p = put_uint( p, err );
        p = put_str( p, " sectorsPerCluster=" );
        p = put_uint( p, spc );
        p = put_str( p, " bytesPerSector=" );
        p = put_uint( p, bps );
        p = put_str( p, " freeClusters=" );
        p = put_uint( p, freecl );
        p = put_str( p, " totalClusters=" );
        p = put_uint( p, totcl );
        emit( p );

        root[2] = 0;   /* "C:" — QueryDosDevice wants no trailing slash */
        target[0] = 0;
        SetLastError( 0 );
        tlen = QueryDosDeviceA( root, target, sizeof(target) - 2 );
        err = GetLastError();
        /* the result is a NUL-separated list; show the first entry only */
        p = put_str( line, "[drive] " );
        p = put_str( p, root );
        p = put_str( p, " QueryDosDevice len=" );
        p = put_uint( p, tlen );
        p = put_str( p, " err=" );
        p = put_uint( p, err );
        p = put_str( p, " target='" );
        p = put_str( p, tlen ? target : "" );
        p = put_str( p, "'" );
        emit( p );
        root[2] = '\\';
    }
}

/* ------------------------------------------------------------------- paths */

static void show_path( const char *tag, const char *path )
{
    DWORD attr = GetFileAttributesA( path );
    char *p;

    p = put_str( line, "[path] " );
    p = put_str( p, tag );
    p = put_str( p, "='" );
    p = put_str( p, path );
    p = put_str( p, "' attr=" );
    if (attr == INVALID_FILE_ATTRIBUTES) p = put_str( p, "MISSING" );
    else p = put_hex( p, attr, 8 );
    emit( p );
}

static void show_csidl( const char *tag, int csidl )
{
    char buf[MAX_PATH + 1];
    HRESULT hr;
    char *p;

    buf[0] = 0;
    hr = SHGetFolderPathA( NULL, csidl, NULL, 0 /* SHGFP_TYPE_CURRENT */, buf );
    p = put_str( line, "[path] CSIDL " );
    p = put_str( p, tag );
    p = put_str( p, " hr=" );
    p = put_hex( p, (unsigned)hr, 8 );
    p = put_str( p, " '" );
    p = put_str( p, buf );
    p = put_str( p, "'" );
    if (buf[0])
    {
        DWORD attr = GetFileAttributesA( buf );
        p = put_str( p, attr == INVALID_FILE_ATTRIBUTES ? " MISSING" : " exists" );
    }
    emit( p );
}

static void probe_paths(void)
{
    char buf[MAX_PATH + 1];

    buf[0] = 0; GetModuleFileNameA( NULL, buf, MAX_PATH );      show_path( "module", buf );
    buf[0] = 0; GetCurrentDirectoryA( MAX_PATH, buf );          show_path( "cwd", buf );
    buf[0] = 0; GetWindowsDirectoryA( buf, MAX_PATH );          show_path( "windows", buf );
    buf[0] = 0; GetSystemDirectoryA( buf, MAX_PATH );           show_path( "system", buf );
    buf[0] = 0; GetTempPathA( MAX_PATH, buf );                  show_path( "temp", buf );

    show_csidl( "PERSONAL",        CSIDL_PERSONAL );
    show_csidl( "APPDATA",         CSIDL_APPDATA );
    show_csidl( "LOCAL_APPDATA",   CSIDL_LOCAL_APPDATA );
    show_csidl( "COMMON_APPDATA",  CSIDL_COMMON_APPDATA );
    show_csidl( "PROGRAM_FILES",   CSIDL_PROGRAM_FILES );
    show_csidl( "WINDOWS",         CSIDL_WINDOWS );
    show_csidl( "SYSTEM",          CSIDL_SYSTEM );
    show_csidl( "DESKTOPDIRECTORY",CSIDL_DESKTOPDIRECTORY );
    show_csidl( "STARTMENU",       CSIDL_STARTMENU );
    show_csidl( "PROFILE",         CSIDL_PROFILE );
}

/* ------------------------------------------------------------------ system */

static void probe_system(void)
{
    OSVERSIONINFOEXA osx;
    SYSTEM_INFO si, nsi;
    MEMORYSTATUSEX ms;
    char buf[512];
    DWORD len;
    BOOL wow = FALSE;
    char *p;
    BOOL (WINAPI *pIsWow64Process)( HANDLE, PBOOL );

    memset( &osx, 0, sizeof(osx) );
    osx.dwOSVersionInfoSize = sizeof(osx);
    GetVersionExA( (OSVERSIONINFOA *)&osx );
    p = put_str( line, "[sys] version " );
    p = put_uint( p, osx.dwMajorVersion );
    *p++ = '.';
    p = put_uint( p, osx.dwMinorVersion );
    p = put_str( p, " build=" );
    p = put_uint( p, osx.dwBuildNumber );
    p = put_str( p, " platform=" );
    p = put_uint( p, osx.dwPlatformId );
    p = put_str( p, " sp='" );
    p = put_str( p, osx.szCSDVersion );
    p = put_str( p, "' spmaj=" );
    p = put_uint( p, osx.wServicePackMajor );
    p = put_str( p, " suite=" );
    p = put_hex( p, osx.wSuiteMask, 4 );
    p = put_str( p, " producttype=" );
    p = put_uint( p, osx.wProductType );
    emit( p );

    memset( &si, 0, sizeof(si) );
    GetSystemInfo( &si );
    memset( &nsi, 0, sizeof(nsi) );
    GetNativeSystemInfo( &nsi );
    p = put_str( line, "[sys] GetSystemInfo arch=" );
    p = put_uint( p, si.wProcessorArchitecture );
    p = put_str( p, " native_arch=" );
    p = put_uint( p, nsi.wProcessorArchitecture );
    p = put_str( p, " cpus=" );
    p = put_uint( p, si.dwNumberOfProcessors );
    p = put_str( p, " pagesize=" );
    p = put_hex( p, si.dwPageSize, 8 );
    p = put_str( p, " gran=" );
    p = put_hex( p, si.dwAllocationGranularity, 8 );
    p = put_str( p, " minAppAddr=" );
    p = put_hex( p, (unsigned)(ULONG_PTR)si.lpMinimumApplicationAddress, 8 );
    p = put_str( p, " maxAppAddr=" );
    p = put_hex( p, (unsigned)(ULONG_PTR)si.lpMaximumApplicationAddress, 8 );
    p = put_str( p, " type=" );
    p = put_uint( p, si.dwProcessorType );
    p = put_str( p, " level=" );
    p = put_uint( p, si.wProcessorLevel );
    p = put_str( p, " rev=" );
    p = put_hex( p, si.wProcessorRevision, 4 );
    emit( p );

    memset( &ms, 0, sizeof(ms) );
    ms.dwLength = sizeof(ms);
    GlobalMemoryStatusEx( &ms );
    p = put_str( line, "[sys] memory load=" );
    p = put_uint( p, ms.dwMemoryLoad );
    p = put_str( p, " totalPhysMB=" );
    p = put_u64( p, ms.ullTotalPhys >> 20 );
    p = put_str( p, " availPhysMB=" );
    p = put_u64( p, ms.ullAvailPhys >> 20 );
    p = put_str( p, " totalVirtMB=" );
    p = put_u64( p, ms.ullTotalVirtual >> 20 );
    p = put_str( p, " availVirtMB=" );
    p = put_u64( p, ms.ullAvailVirtual >> 20 );
    p = put_str( p, " totalPageMB=" );
    p = put_u64( p, ms.ullTotalPageFile >> 20 );
    emit( p );

    pIsWow64Process = (void *)GetProcAddress( GetModuleHandleA( "kernel32.dll" ), "IsWow64Process" );
    if (pIsWow64Process) pIsWow64Process( GetCurrentProcess(), &wow );
    p = put_str( line, "[sys] IsWow64Process present=" );
    p = put_uint( p, (unsigned)(pIsWow64Process != NULL) );
    p = put_str( p, " wow64=" );
    p = put_uint( p, (unsigned)wow );
    p = put_str( p, " tickCount=" );
    p = put_uint( p, GetTickCount() );
    emit( p );

    buf[0] = 0; len = sizeof(buf); GetComputerNameA( buf, &len );
    p = put_str( line, "[sys] computer='" );
    p = put_str( p, buf );
    buf[0] = 0; len = sizeof(buf); GetUserNameA( buf, &len );
    p = put_str( p, "' user='" );
    p = put_str( p, buf );
    p = put_str( p, "'" );
    emit( p );

    p = put_str( line, "[sys] metrics cx=" );
    p = put_uint( p, (unsigned)GetSystemMetrics( SM_CXSCREEN ) );
    p = put_str( p, " cy=" );
    p = put_uint( p, (unsigned)GetSystemMetrics( SM_CYSCREEN ) );
    p = put_str( p, " monitors=" );
    p = put_uint( p, (unsigned)GetSystemMetrics( SM_CMONITORS ) );
    p = put_str( p, " remote=" );
    p = put_uint( p, (unsigned)GetSystemMetrics( SM_REMOTESESSION ) );
    p = put_str( p, " mousepresent=" );
    p = put_uint( p, (unsigned)GetSystemMetrics( SM_MOUSEPRESENT ) );
    p = put_str( p, " debug=" );
    p = put_uint( p, (unsigned)GetSystemMetrics( SM_DEBUG ) );
    emit( p );
}

/* ------------------------------------------------------------------ locale */

static void show_locale_info( const char *tag, LCID lcid, LCTYPE type )
{
    char buf[256];
    char *p;

    buf[0] = 0;
    GetLocaleInfoA( lcid, type, buf, sizeof(buf) );
    p = put_str( line, "[locale] " );
    p = put_str( p, tag );
    p = put_str( p, "='" );
    p = put_str( p, buf );
    p = put_str( p, "'" );
    emit( p );
}

static void probe_locale(void)
{
    char *p;

    p = put_str( line, "[locale] ACP=" );
    p = put_uint( p, GetACP() );
    p = put_str( p, " OEMCP=" );
    p = put_uint( p, GetOEMCP() );
    p = put_str( p, " sysLangID=" );
    p = put_hex( p, GetSystemDefaultLangID(), 4 );
    p = put_str( p, " userLangID=" );
    p = put_hex( p, GetUserDefaultLangID(), 4 );
    p = put_str( p, " sysLCID=" );
    p = put_hex( p, GetSystemDefaultLCID(), 8 );
    p = put_str( p, " userLCID=" );
    p = put_hex( p, GetUserDefaultLCID(), 8 );
    p = put_str( p, " threadLocale=" );
    p = put_hex( p, GetThreadLocale(), 8 );
    emit( p );

    show_locale_info( "SENGCOUNTRY",         LOCALE_USER_DEFAULT, LOCALE_SENGCOUNTRY );
    show_locale_info( "SENGLANGUAGE",        LOCALE_USER_DEFAULT, LOCALE_SENGLANGUAGE );
    show_locale_info( "IDEFAULTANSICODEPAGE",LOCALE_USER_DEFAULT, LOCALE_IDEFAULTANSICODEPAGE );
    show_locale_info( "IDEFAULTCODEPAGE",    LOCALE_USER_DEFAULT, LOCALE_IDEFAULTCODEPAGE );
    show_locale_info( "SDECIMAL",            LOCALE_USER_DEFAULT, LOCALE_SDECIMAL );
    show_locale_info( "SSHORTDATE",          LOCALE_USER_DEFAULT, LOCALE_SSHORTDATE );
}

/* ----------------------------------------------------------------- display */

static void probe_display(void)
{
    DEVMODEA dm;
    char *p;
    DWORD n;

    memset( &dm, 0, sizeof(dm) );
    dm.dmSize = sizeof(dm);
    if (EnumDisplaySettingsA( NULL, ENUM_CURRENT_SETTINGS, &dm ))
    {
        p = put_str( line, "[disp] current bpp=" );
        p = put_uint( p, dm.dmBitsPerPel );
        p = put_str( p, " w=" );
        p = put_uint( p, dm.dmPelsWidth );
        p = put_str( p, " h=" );
        p = put_uint( p, dm.dmPelsHeight );
        p = put_str( p, " hz=" );
        p = put_uint( p, dm.dmDisplayFrequency );
        p = put_str( p, " fields=" );
        p = put_hex( p, dm.dmFields, 8 );
        emit( p );
    }
    else out_str( "[disp] EnumDisplaySettings(ENUM_CURRENT_SETTINGS) FAILED\n" );

    /* Mode count only: engines that enumerate look for at least one 640x480 or
     * 800x600 entry, and "how many are there" is the first thing to know. */
    for (n = 0; n < 4096; n++)
    {
        memset( &dm, 0, sizeof(dm) );
        dm.dmSize = sizeof(dm);
        if (!EnumDisplaySettingsA( NULL, n, &dm )) break;
    }
    p = put_str( line, "[disp] mode count=" );
    p = put_uint( p, n );
    emit( p );
}

/* ---------------------------------------------------------------- registry */

static void show_reg( HKEY root, const char *rootname, const char *subkey, const char *value )
{
    HKEY key;
    BYTE data[1024];
    DWORD type = 0, size = sizeof(data) - 2;
    LONG rc;
    char *p;

    p = put_str( line, "[reg] " );
    p = put_str( p, rootname );
    *p++ = '\\';
    p = put_str( p, subkey );
    p = put_str( p, " : " );
    p = put_str( p, value );
    p = put_str( p, " = " );

    rc = RegOpenKeyExA( root, subkey, 0, KEY_QUERY_VALUE, &key );
    if (rc)
    {
        p = put_str( p, "<key open failed rc=" );
        p = put_uint( p, (unsigned)rc );
        p = put_str( p, ">" );
        emit( p );
        return;
    }
    memset( data, 0, sizeof(data) );
    rc = RegQueryValueExA( key, value, NULL, &type, data, &size );
    RegCloseKey( key );
    if (rc)
    {
        p = put_str( p, "<query failed rc=" );
        p = put_uint( p, (unsigned)rc );
        p = put_str( p, ">" );
    }
    else if (type == REG_SZ || type == REG_EXPAND_SZ)
    {
        *p++ = '\'';
        p = put_str( p, (const char *)data );
        *p++ = '\'';
        *p = 0;
    }
    else if (type == REG_DWORD)
    {
        p = put_uint( p, *(DWORD *)data );
        p = put_str( p, " (dword)" );
    }
    else
    {
        p = put_str( p, "<type=" );
        p = put_uint( p, type );
        p = put_str( p, " size=" );
        p = put_uint( p, size );
        p = put_str( p, ">" );
    }
    emit( p );
}

static void probe_registry(void)
{
    static const char nt_cv[]  = "SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion";
    static const char cpu0[]   = "HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0";
    static const char sysdesc[]= "HARDWARE\\DESCRIPTION\\System";
    static const char dx[]     = "SOFTWARE\\Microsoft\\DirectX";
    static const char tcpip[]  = "SYSTEM\\CurrentControlSet\\Services\\Tcpip\\Parameters";

    show_reg( HKEY_LOCAL_MACHINE, "HKLM", nt_cv, "ProductName" );
    show_reg( HKEY_LOCAL_MACHINE, "HKLM", nt_cv, "CurrentVersion" );
    show_reg( HKEY_LOCAL_MACHINE, "HKLM", nt_cv, "CurrentBuildNumber" );
    show_reg( HKEY_LOCAL_MACHINE, "HKLM", nt_cv, "CSDVersion" );
    show_reg( HKEY_LOCAL_MACHINE, "HKLM", nt_cv, "InstallDate" );
    show_reg( HKEY_LOCAL_MACHINE, "HKLM", nt_cv, "ProductId" );
    show_reg( HKEY_LOCAL_MACHINE, "HKLM", nt_cv, "RegisteredOwner" );
    show_reg( HKEY_LOCAL_MACHINE, "HKLM", nt_cv, "RegisteredOrganization" );
    show_reg( HKEY_LOCAL_MACHINE, "HKLM", nt_cv, "BuildLab" );
    show_reg( HKEY_LOCAL_MACHINE, "HKLM", nt_cv, "SystemRoot" );

    show_reg( HKEY_LOCAL_MACHINE, "HKLM", cpu0, "ProcessorNameString" );
    show_reg( HKEY_LOCAL_MACHINE, "HKLM", cpu0, "Identifier" );
    show_reg( HKEY_LOCAL_MACHINE, "HKLM", cpu0, "VendorIdentifier" );
    show_reg( HKEY_LOCAL_MACHINE, "HKLM", cpu0, "~MHz" );
    show_reg( HKEY_LOCAL_MACHINE, "HKLM", cpu0, "FeatureSet" );

    show_reg( HKEY_LOCAL_MACHINE, "HKLM", sysdesc, "Identifier" );
    show_reg( HKEY_LOCAL_MACHINE, "HKLM", sysdesc, "SystemBiosVersion" );
    show_reg( HKEY_LOCAL_MACHINE, "HKLM", sysdesc, "VideoBiosVersion" );

    show_reg( HKEY_LOCAL_MACHINE, "HKLM", dx, "Version" );
    show_reg( HKEY_LOCAL_MACHINE, "HKLM", dx, "InstalledVersion" );

    show_reg( HKEY_LOCAL_MACHINE, "HKLM", tcpip, "Hostname" );
    show_reg( HKEY_LOCAL_MACHINE, "HKLM", tcpip, "Domain" );
}

/* --------------------------------------------------------------- environment */

static void show_env( const char *name )
{
    char buf[1024];
    DWORD n;
    char *p;

    buf[0] = 0;
    n = GetEnvironmentVariableA( name, buf, sizeof(buf) - 1 );
    p = put_str( line, "[env] " );
    p = put_str( p, name );
    p = put_str( p, "=" );
    if (!n) p = put_str( p, "<unset>" );
    else
    {
        *p++ = '\'';
        p = put_str( p, buf );
        *p++ = '\'';
        *p = 0;
    }
    emit( p );
}

static void probe_env(void)
{
    show_env( "USERPROFILE" );
    show_env( "APPDATA" );
    show_env( "LOCALAPPDATA" );
    show_env( "TEMP" );
    show_env( "USERNAME" );
    show_env( "COMPUTERNAME" );
    show_env( "SystemRoot" );
    show_env( "SystemDrive" );
    show_env( "PROCESSOR_ARCHITECTURE" );
    show_env( "PROCESSOR_IDENTIFIER" );
    show_env( "NUMBER_OF_PROCESSORS" );
    show_env( "OS" );
}

/* -------------------------------------------------------------------- main */

static int run_all(void)
{
    /* One unmistakable anchor so the block can be found in a 5 MB log. */
    out_str( "MADEIRA-SYSPROBE: begin\n" );

    probe_drives();
    probe_paths();
    probe_system();
    probe_locale();
    probe_display();
    probe_registry();
    probe_env();

    out_str( "MADEIRA-SYSPROBE: end\n" );
    return 63;
}

void __cdecl start(void)
{
    ExitProcess( (UINT)run_all() );
}
