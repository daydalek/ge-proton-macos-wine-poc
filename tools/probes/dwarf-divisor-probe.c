// SPDX-License-Identifier: LGPL-2.1-or-later
#include <windows.h>
#include <dbghelp.h>
#include <stdio.h>
#include <string.h>
static unsigned count,valid;
static BOOL CALLBACK visit(SYMBOL_INFO *s,ULONG size,void *context){printf("symbol: %s\n",s->Name);count++;if(!strcmp(s->Name,"valid_division"))valid++;return TRUE;}
int wmain(int argc,WCHAR **argv){if(argc!=2)return 2;HANDLE p=GetCurrentProcess();if(!SymInitialize(p,NULL,FALSE))return 3;DWORD64 b=SymLoadModuleExW(p,NULL,argv[1],NULL,sizeof(void*)==8?0x180000000ULL:0x10000000,0,NULL,0);if(!b){printf("load error %lu\n",GetLastError());return 4;}BOOL ok=SymEnumSymbols(p,b,"*",visit,NULL);printf("DWARF divisor probe: enum=%d symbols=%u control=%u bits=%u\n",ok,count,valid,(unsigned)sizeof(void*)*8);SymCleanup(p);return ok&&valid?0:5;}
