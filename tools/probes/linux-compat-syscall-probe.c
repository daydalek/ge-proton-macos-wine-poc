/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* Linux Wine WoW64 uses int 0x80 for 32-bit thread-area setup. Verify the
 * execution environment handles that syscall entry using a read-only getpid. */
#if !defined(__linux__) || !defined(__x86_64__)
#error This probe requires an x86_64 Linux userspace
#endif

#include <stdio.h>
#include <unistd.h>

int main(void)
{
    long native = getpid();
    int compat;

    printf("Native PID=%ld; entering Linux i386 getpid through int 0x80\n", native);
    fflush(stdout);
    __asm__ volatile("int $0x80" : "=a"(compat) : "0"(20)
                     : "memory", "cc", "r8", "r9", "r10", "r11");
    printf("Compatible PID=%d %s\n", compat, compat == native ? "PASS" : "FAIL");
    return compat == native ? 0 : 1;
}
