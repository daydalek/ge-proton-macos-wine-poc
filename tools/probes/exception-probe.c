/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include <windows.h>
#include <stdio.h>
static volatile LONG handled;
static LONG CALLBACK handler(EXCEPTION_POINTERS *p)
{
#ifdef _WIN64
    DWORD64 *ip = &p->ContextRecord->Rip;
#else
    DWORD *ip = &p->ContextRecord->Eip;
#endif
    const unsigned char *code = (const unsigned char *)(ULONG_PTR)*ip;
    if (p->ExceptionRecord->ExceptionCode == EXCEPTION_ILLEGAL_INSTRUCTION && code[0] == 0x0f && code[1] == 0x0b) *ip += 2;
    else if (p->ExceptionRecord->ExceptionCode == EXCEPTION_PRIV_INSTRUCTION && code[0] == 0xfa) *ip += 1;
    else return EXCEPTION_CONTINUE_SEARCH;
    InterlockedIncrement(&handled);
    return EXCEPTION_CONTINUE_EXECUTION;
}
static DWORD WINAPI worker(void *arg)
{
    (void)arg;
    for (int i = 0; i < 20; ++i) {
        __asm__ volatile("ud2");
        __asm__ volatile("cli");
        Sleep(1);
        if (!GetCurrentThreadId()) return 1;
    }
    return 0;
}
int main(void)
{
    PVOID h = AddVectoredExceptionHandler(1, handler);
    HANDLE thread = CreateThread(NULL, 0, worker, NULL, 0, NULL);
    if (!h || !thread) return 2;
    DWORD main_result = worker(NULL), other_result = 1;
    DWORD waited = WaitForSingleObject(thread, 30000);
    GetExitCodeThread(thread, &other_result);
    CloseHandle(thread);
    RemoveVectoredExceptionHandler(h);
    printf("exception resumes=%ld expected=80; main=%lu worker=%lu wait=%lu\n", handled, main_result, other_result, waited);
    return handled == 80 && !main_result && !other_result && waited == WAIT_OBJECT_0 ? 0 : 1;
}
