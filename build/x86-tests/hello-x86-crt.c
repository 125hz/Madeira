/* MADEIRA-TEMP: milestone-2 variant of hello-x86.c that exercises the CRT
 * (printf) instead of a bare kernel32-only entry point. See WOW64_DESIGN.md
 * section 5. Unlike hello-x86.c, this pulls in mingw's normal i386 startup
 * and C runtime import (msvcrt.dll and/or the api-ms-win-crt-*.dll /
 * ucrtbase.dll set, depending on the llvm-mingw default for i686-w64-mingw32
 * -- check with `i686-w64-mingw32-objdump -p hello-x86-crt.exe`; build.sh
 * prints the import list). Those extra i386 DLLs are NOT built by stage A
 * and are not shipped in app/Madeira/i386-windows/ yet -- this file is
 * parked for whichever milestone adds them, not expected to run today.
 */
#include <stdio.h>
#include <windows.h>

int main(void)
{
    printf("MADEIRA-X86-32-CRT: hello from a 32-bit PE (printf)\n");
    fflush(stdout);
    return 42;
}
