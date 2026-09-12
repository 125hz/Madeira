/* MADEIRA-TEMP: milestone-1 smoke test PE for Madeira's WoW64 (i386) path.
 * See WOW64_DESIGN.md section 5, stage A / milestone 1: "execute a minimal
 * real 32-bit PE (hello-x86.exe, i686 mingw, imports only kernel32:
 * GetStdHandle, WriteFile, ExitProcess); its string reaches the app log
 * through Wine and the iOS runtime; exit code 42 is reported."
 *
 * No CRT: this file supplies its own PE entry point (`start`, which the
 * i386 Windows C ABI mangles to the symbol `_start`) and is linked with
 * -nostdlib, so the ONLY DLL this exe imports is kernel32.dll -- verified
 * with `i686-w64-mingw32-objdump -p hello-x86.exe` (see build.sh). This
 * keeps milestone 1 from depending on wow64's msvcrt/ucrtbase plumbing at
 * all; see hello-x86-crt.c for the milestone-2 variant that does.
 */
#include <windows.h>

void start(void)
{
    HANDLE h = GetStdHandle(STD_ERROR_HANDLE);
    DWORD written = 0;
    static const char msg[] = "MADEIRA-X86-32: hello from a 32-bit PE\n";

    WriteFile(h, msg, sizeof(msg) - 1, &written, NULL);
    ExitProcess(42);
}
