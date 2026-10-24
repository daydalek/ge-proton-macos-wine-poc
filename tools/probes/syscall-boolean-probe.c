/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include <windows.h>
#include <stdio.h>

/* Deliberately expose a full ABI argument slot to inject undefined upper bits
 * into NtWaitForSingleObject's BOOLEAN parameter. GetProcAddress keeps the
 * compiler from narrowing the slot according to the usual BOOLEAN prototype. */
typedef LONG (WINAPI *raw_wait_fn)(HANDLE, ULONG_PTR, LARGE_INTEGER *);
static volatile LONG apcs;
static void CALLBACK on_apc(ULONG_PTR unused)
{
    (void)unused;
    ++apcs;
}

int main(void)
{
    const ULONGLONG cases[] = {0x100, 0xdeadbeef12345600ULL, 0x101, 0xdeadbeef123456ffULL};
    raw_wait_fn wait = (raw_wait_fn)GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtWaitForSingleObject");
    HANDLE event = CreateEventW(NULL, FALSE, FALSE, NULL);
    LARGE_INTEGER timeout;
    unsigned int failures = 0;
    timeout.QuadPart = 0;
    if (!wait || !event) return 2;
    setbuf(stdout, NULL);
    for (unsigned int i = 0; i < sizeof(cases) / sizeof(*cases); ++i)
    {
        LONG before = apcs, immediate, status;
        int alertable = !!(cases[i] & 0xff);
        if (!QueueUserAPC(on_apc, GetCurrentThread(), 0)) return 3;
        status = wait(event, (ULONG_PTR)cases[i], &timeout);
        immediate = apcs - before;
        SleepEx(0, TRUE);
        int ok = status == (alertable ? 0xc0 : 0x102)
                && immediate == alertable && apcs == before + 1;
        printf("BOOLEAN case=%u low=%#x status=%#lx immediate_apcs=%ld total_apcs=%ld %s\n",
                i, (unsigned int)(cases[i] & 0xff), status, immediate, apcs - before, ok ? "PASS" : "FAIL");
        failures += !ok;
    }
    CloseHandle(event);
    printf("Syscall BOOLEAN probe: bits=%u failures=%u\n", (unsigned int)(sizeof(void *) * 8), failures);
    return failures ? 1 : 0;
}
