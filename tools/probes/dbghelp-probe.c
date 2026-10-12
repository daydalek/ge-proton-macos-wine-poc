// SPDX-License-Identifier: LGPL-2.1-or-later
#include <windows.h>
#include <dbghelp.h>
#include <stdio.h>
int main(void){WCHAR path[MAX_PATH],dir[MAX_PATH];DWORD pid=GetCurrentProcessId();BOOL symbols=SymInitialize(GetCurrentProcess(),NULL,TRUE);printf("SymInitialize: %d error=%lu\n",symbols,GetLastError());if(!symbols)return 1;GetTempPathW(MAX_PATH,dir);swprintf(path,MAX_PATH,L"%lsdbghelp-probe-%lu.dmp",dir,pid);HANDLE f=CreateFileW(path,GENERIC_WRITE,0,NULL,CREATE_ALWAYS,FILE_ATTRIBUTE_TEMPORARY,NULL);if(f==INVALID_HANDLE_VALUE)return 2;BOOL dump=MiniDumpWriteDump(GetCurrentProcess(),pid,f,MiniDumpNormal,NULL,NULL,NULL);DWORD err=GetLastError();LARGE_INTEGER size;GetFileSizeEx(f,&size);CloseHandle(f);DeleteFileW(path);SymCleanup(GetCurrentProcess());printf("MiniDumpWriteDump: %d error=%lu bytes=%lld bits=%u\n",dump,err,size.QuadPart,(unsigned)sizeof(void*)*8);return dump&&size.QuadPart>32?0:3;}
