/* SPDX-License-Identifier: GPL-3.0-or-later
 * With the additional permission in LICENSE-EXCEPTION.md.
 * Run from an EXE folder containing non-ASCII characters, no working-dir override.
 */
#include <windows.h>
#include <stdio.h>
#include <wchar.h>

int main(void)
{
    WCHAR absolute[32768], leaf[80];
    DWORD length, written = 0, read = 0;
    DWORD marker = GetCurrentProcessId() ^ GetTickCount(), value = 0;
    HANDLE output, input;
    int failed = 1;
    setvbuf(stdout, NULL, _IONBF, 0);
    length = GetModuleFileNameW(NULL, absolute, ARRAYSIZE(absolute));
    if (!length || length >= ARRAYSIZE(absolute)) return 2;
    WCHAR *slash = wcsrchr(absolute, L'\\');
    if (!slash) return 2;
    slash[1] = 0;
    swprintf(leaf, ARRAYSIZE(leaf), L"madeira-cwd-%lu-%lu.tmp", GetCurrentProcessId(), GetTickCount());
    if (wcslen(absolute) + wcslen(leaf) + 1 > ARRAYSIZE(absolute)) return 2;
    wcscat(absolute, leaf);
    output = CreateFileW(absolute, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_NEW,
                         FILE_ATTRIBUTE_NORMAL, NULL);
    if (output == INVALID_HANDLE_VALUE)
    {
        printf("[initial-cwd] FAIL create absolute probe error=%lu\n", GetLastError());
        return 2;
    }
    BOOL ok = WriteFile(output, &marker, sizeof(marker), &written, NULL);
    CloseHandle(output);
    if (!ok || written != sizeof(marker)) goto cleanup;
    input = CreateFileW(leaf, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                        FILE_ATTRIBUTE_NORMAL, NULL);
    if (input == INVALID_HANDLE_VALUE)
    {
        printf("[initial-cwd] FAIL relative lookup error=%lu\n", GetLastError());
        goto cleanup;
    }
    ok = ReadFile(input, &value, sizeof(value), &read, NULL);
    CloseHandle(input);
    failed = !ok || read != sizeof(value) || value != marker;
cleanup:
    if (!DeleteFileW(absolute))
    {
        printf("[initial-cwd] FAIL remove probe error=%lu\n", GetLastError());
        failed = 1;
    }
    printf("[initial-cwd] %s relative resource lookup\n", failed ? "FAIL" : "PASS");
    return failed;
}
