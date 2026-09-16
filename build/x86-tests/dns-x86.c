/* MADEIRA-TEMP: the 32-bit self-test for dnsapi's unix side.
 *
 * WHAT IT CHECKS, AND WHY
 * -----------------------
 * dnsapi.dll had no unixlib on this port.  Its DllMain called
 * __wine_init_unix_call(), logged "No libresolv support, expect problems" when
 * that failed, and then every DnsQuery_A still expanded RESOLV_CALL() ->
 * WINE_UNIX_CALL() -> __wine_unix_call(handle = 0, code, args).  A zero handle
 * is the unix call TABLE, so the dispatcher's `ldr x16, [x0, x1, lsl #3]` read
 * host address code*8 and the whole pseudo-process died three SEGVs later --
 * for a program whose only sin was to initialise networking at startup.
 *
 * So the subject of this test is not whether DNS resolves.  It is that a
 * 32-bit program can CALL dnsapi and still be running afterwards:
 *
 *  1. DnsQuery_A("localhost", DNS_TYPE_A)          -- a name the resolver may
 *     or may not answer; either way the call must RETURN.
 *  2. DnsQuery_A("madeira-dns-test.invalid", DNS_TYPE_A) -- .invalid is
 *     reserved by RFC 2606 and can never resolve, so this exercises the
 *     failure path through map_h_errno() rather than the success path.
 *  3. DnsQueryConfig(DnsConfigDnsServerList) twice, once to ask the size and
 *     once to fetch -- dnsapi's get_dns_server_list() turns both into the
 *     get_serverlist unix call, whose argument block carries two guest
 *     pointers OUT of 32-bit code (a DNS_ADDR_ARRAY on dnsapi's own stack and
 *     the length beside it).  That is where a missing guest-window conversion
 *     shows up as a wild write rather than as a wrong answer, which is why it
 *     is worth a check of its own even though nobody expects a phone to have
 *     an interesting nameserver list.
 *  4. DnsQuery_A with aipServers = NULL, which is what 1 and 2 already do.
 *     Worth naming because the unix side's set_serverlist takes the caller's
 *     IP4_ARRAY pointer AS its argument block: a 32-bit NULL crosses the
 *     bridge as guest address 0, and the window maps that to its deliberately
 *     unmapped first page.  If the wow64 entry does not turn it back into
 *     NULL, this test faults inside the host on the very first query.
 *
 * ANY status from any of these is a pass.  DNS_ERROR_RCODE_SERVER_FAILURE
 * (9002) is the expected answer on a device whose sandbox gives libresolv no
 * nameservers, and it is a perfectly good one: the call returned.
 *
 * Deliberate restrictions, the same ones the other tests here work under: no
 * CRT (this file supplies `start' plus memset/memcpy and links -nostdlib), no
 * 64-bit division, no int-to-double conversion.  Its imports are dnsapi and
 * kernel32 and nothing else; build-dns-test.sh asserts that.
 *
 * Exit status (the runtime reports it as "MADEIRA-EXIT: ... status=<n>"):
 *   54  every call returned -- the unix side is reachable, or cleanly absent
 *   60  a query reported ERROR_SUCCESS and handed back no record list at all
 *       (the "fake success" shape: a unix side that answers without answering)
 *   61  DnsQueryConfig's size query said ERROR_SUCCESS but asked for a buffer
 *       larger than this test's, i.e. a length that cannot be right
 * No status at all means the process died inside the call, which is the whole
 * bug this test exists for.
 */
#include <stddef.h>
#include <windows.h>
#include <windns.h>

/* -nostdlib: clang may still lower a struct initialisation to memset/memcpy. */
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

/* "MADEIRA-DNS: <what> status=<st> <tail>=<v>\n" -- one shape for every line,
 * so a log can be grepped for MADEIRA-DNS and read in order. */
static void dns_line( const char *what, unsigned int status, const char *tail, unsigned int v )
{
    char buf[256], *p = buf;

    p = put_str( p, "MADEIRA-DNS: " );
    p = put_str( p, what );
    p = put_str( p, " status=" );
    p = put_uint( p, status );
    if (tail)
    {
        *p++ = ' ';
        p = put_str( p, tail );
        *p++ = '=';
        p = put_uint( p, v );
    }
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

/* ----------------------------------------------------------------- checks */

static unsigned int count_records( DNS_RECORD *list )
{
    unsigned int n = 0;
    while (list && n < 1000) { n++; list = list->pNext; }
    return n;
}

/* One query.  Returns 0 to carry on, or the exit code of a failure that is
 * about the ANSWER rather than about the call (the call returning at all is
 * what this test is for, and by the time we are here it has). */
static unsigned int query_one( const char *name )
{
    DNS_RECORD *records = NULL;
    DNS_STATUS status;
    unsigned int n;

    /* aipServers = NULL on purpose: see note 4 in the header comment. */
    status = DnsQuery_A( name, DNS_TYPE_A, DNS_QUERY_STANDARD, NULL, &records, NULL );
    n = count_records( records );
    dns_line( name, (unsigned int)status, "records", n );
    if (records) DnsRecordListFree( records, DnsFreeRecordList );

    if (status == ERROR_SUCCESS && !n) return 60;
    return 0;
}

static unsigned int check_server_list(void)
{
    unsigned char buffer[1024];
    DWORD len = 0;
    DNS_STATUS status;

    /* Size query first (pBuffer NULL): get_serverlist's "tell me how much"
     * mode, and the one that proves the OUT length pointer crossed the guest
     * window correctly -- a length written through an unconverted 32-bit
     * pointer lands somewhere else entirely and leaves this zero. */
    status = DnsQueryConfig( DnsConfigDnsServerList, 0, NULL, NULL, NULL, &len );
    dns_line( "DnsQueryConfig(serverlist,size)", (unsigned int)status, "len", (unsigned int)len );
    if (status == ERROR_SUCCESS && len > sizeof(buffer)) return 61;

    len = sizeof(buffer);
    status = DnsQueryConfig( DnsConfigDnsServerList, 0, NULL, NULL, buffer, &len );
    dns_line( "DnsQueryConfig(serverlist,fetch)", (unsigned int)status, "len", (unsigned int)len );
    return 0;
}

static unsigned int run_all(void)
{
    unsigned int rc;

    out_str( "MADEIRA-DNS: start (32-bit; dnsapi unix side)\n" );

    if ((rc = query_one( "localhost" ))) return rc;
    if ((rc = query_one( "madeira-dns-test.invalid" ))) return rc;
    if ((rc = check_server_list())) return rc;

    out_str( "MADEIRA-DNS: every call returned -- no NULL-handle unix call, no host fault\n" );
    return 54;
}

void __cdecl start(void)
{
    ExitProcess( (UINT)run_all() );
}
