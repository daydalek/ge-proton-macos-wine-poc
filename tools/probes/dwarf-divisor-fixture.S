/* SPDX-License-Identifier: LGPL-2.1-or-later */
.text
#ifdef __x86_64__
.globl fixture
fixture:
#else
.globl _fixture
_fixture:
#endif
 ret
.section .debug_abbrev,"dr"
.byte 1,0x11,1,0x03,0x08,0x1b,0x08,0,0
.byte 2,0x34,0,0x03,0x08,0x49,0x13,0x02,0x0a,0x3f,0x0c,0,0
.byte 3,0x24,0,0x03,0x08,0x0b,0x0b,0x3e,0x0b,0,0
.byte 0
.section .debug_info,"dr"
.Lunit:
.long .Lend-.Lbody
.Lbody:
.short 4
.long 0
#ifdef __x86_64__
.byte 8
#else
.byte 4
#endif
.byte 1
.asciz "divisor-fixture.c"
.asciz "."
.byte 2
.asciz "division_by_zero"
.long .Ltype-.Lunit
.byte 5,0x08,6,0x08,0,0x1b
.byte 1
.byte 2
.asciz "modulo_by_zero"
.long .Ltype-.Lunit
.byte 5,0x08,6,0x08,0,0x1d
.byte 1
.byte 2
.asciz "valid_division"
.long .Ltype-.Lunit
.byte 5,0x08,6,0x08,2,0x1b
.byte 1
.Ltype:
.byte 3
.asciz "int"
.byte 4,5
.byte 0
.Lend:
