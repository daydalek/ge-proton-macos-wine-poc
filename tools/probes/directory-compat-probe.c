/* SPDX-License-Identifier: LGPL-2.1-or-later
 * Reproduce legacy virtual filesystem hooks returning empty modern directory records.
 * Build with llvm-mingw for i686/x86_64; run inside Wine. Temporary fixtures are removed.
 */
#include <windows.h>
#include <winternl.h>
#include <stdio.h>
#include <stdint.h>

typedef NTSTATUS (WINAPI *query_fn)(HANDLE,HANDLE,PIO_APC_ROUTINE,PVOID,PIO_STATUS_BLOCK,PVOID,ULONG,ULONG,BOOLEAN,PUNICODE_STRING,BOOLEAN);
static query_fn original;
static LONG modern,legacy,empty;
static BOOL empty_all;
static NTSTATUS WINAPI query_hook(HANDLE h,HANDLE e,PIO_APC_ROUTINE a,PVOID c,PIO_STATUS_BLOCK io,
                                 PVOID b,ULONG len,ULONG cls,BOOLEAN single,PUNICODE_STRING mask,BOOLEAN restart)
{
    if(cls==63){modern++;io->Status=0;io->Information=0;return 0;}
    if(cls==3){legacy++;if(empty_all){empty++;io->Status=0;io->Information=0;return 0;}}
    return original(h,e,a,c,io,b,len,cls,single,mask,restart);
}
static BOOL install_hook(void)
{
    BYTE *entry=(BYTE *)GetProcAddress(GetModuleHandleW(L"ntdll.dll"),"NtQueryDirectoryFile");
    BYTE *trampoline=VirtualAlloc(NULL,64,MEM_COMMIT|MEM_RESERVE,PAGE_EXECUTE_READWRITE);
    DWORD old;
#ifdef _WIN64
    if(!entry||!trampoline||memcmp(entry,"\x4c\x8b\xd1\xb8",4)){printf("unsupported syscall stub\n");return FALSE;}
    /* Wine's complete x64 syscall thunk uses absolute shared-user-data addresses. */
    memcpy(trampoline,entry,32);original=(query_fn)trampoline;
    VirtualProtect(entry,12,PAGE_EXECUTE_READWRITE,&old);
    entry[0]=0x48;entry[1]=0xb8;*(uintptr_t *)(entry+2)=(uintptr_t)query_hook;entry[10]=0xff;entry[11]=0xe0;
    VirtualProtect(entry,12,old,&old);FlushInstructionCache(GetCurrentProcess(),entry,12);return TRUE;
#else
    if(!entry||!trampoline||entry[0]!=0xb8){printf("unsupported syscall stub\n");return FALSE;}
    memcpy(trampoline,entry,5);trampoline[5]=0xe9;
    *(int32_t *)(trampoline+6)=(intptr_t)(entry+5)-(intptr_t)(trampoline+10);original=(query_fn)trampoline;
    VirtualProtect(entry,5,PAGE_EXECUTE_READWRITE,&old);entry[0]=0xe9;
    *(int32_t *)(entry+1)=(intptr_t)query_hook-(intptr_t)(entry+5);
    VirtualProtect(entry,5,old,&old);FlushInstructionCache(GetCurrentProcess(),entry,5);return TRUE;
#endif
}
static int enumerate(const WCHAR *pattern,FINDEX_INFO_LEVELS level,int expected)
{
    WIN32_FIND_DATAW data;int count=0,bad=0;
    int iterations=0;
    HANDLE h=FindFirstFileExW(pattern,level,&data,FindExSearchNameMatch,NULL,0);
    if(h!=INVALID_HANDLE_VALUE){
        do{
            if(++iterations>1000){bad++;break;}
            if(!wcscmp(data.cFileName,L".")||!wcscmp(data.cFileName,L".."))continue;
            if(wcsncmp(data.cFileName,L"record-",7)||data.nFileSizeHigh||data.nFileSizeLow!=7)bad++;
            if(level==FindExInfoBasic && data.cAlternateFileName[0])bad++;
            count++;
        }while(FindNextFileW(h,&data));
        if(GetLastError()!=ERROR_NO_MORE_FILES)bad++;
        FindClose(h);
    }
    printf("enumerate level=%u count=%d expected=%d bad=%d modern=%ld legacy=%ld\n",level,count,expected,bad,modern,legacy);
    return count!=expected||bad;
}
int main(void)
{
    WCHAR tmp[MAX_PATH],dir[MAX_PATH],path[MAX_PATH],pattern[MAX_PATH];int failures=0;
    GetTempPathW(MAX_PATH,tmp);swprintf(dir,MAX_PATH,L"%lswine-enumeration-%lu",tmp,GetCurrentProcessId());CreateDirectoryW(dir,NULL);
    setvbuf(stdout,NULL,_IONBF,0);
    for(int i=0;i<200;i++){
        swprintf(path,MAX_PATH,L"%ls\\record-%03d-long-name-abcdef0123456789.dat",dir,i);
        HANDLE h=CreateFileW(path,GENERIC_WRITE,0,NULL,CREATE_ALWAYS,0,NULL);DWORD written;
        if(h==INVALID_HANDLE_VALUE)return 2;WriteFile(h,"payload",7,&written,NULL);CloseHandle(h);
    }
    swprintf(pattern,MAX_PATH,L"%ls\\record-*.dat",dir);
    failures+=enumerate(pattern,FindExInfoStandard,200);
    if(!install_hook())return 3;
    failures+=enumerate(pattern,FindExInfoStandard,200);
    failures+=enumerate(pattern,FindExInfoBasic,200);
    swprintf(path,MAX_PATH,L"%ls\\record-000-long-name-abcdef0123456789.dat",dir);
    failures+=enumerate(path,FindExInfoStandard,1);
    swprintf(path,MAX_PATH,L"%ls\\absent.dat",dir);WIN32_FIND_DATAW data;HANDLE h=FindFirstFileW(path,&data);
    printf("absent handle=%p error=%lu\n",h,GetLastError());
    if(h!=INVALID_HANDLE_VALUE){failures++;FindClose(h);}else if(GetLastError()!=ERROR_FILE_NOT_FOUND)failures++;
    if(legacy){
        empty_all=TRUE;h=FindFirstFileW(pattern,&data);
        printf("empty handle=%p error=%lu\n",h,GetLastError());
        if(h!=INVALID_HANDLE_VALUE){failures++;FindClose(h);}else if(GetLastError()!=ERROR_FILE_NOT_FOUND)failures++;
        printf("empty legacy response handled, retries=%ld\n",empty);empty_all=FALSE;
    }
    for(int i=0;i<200;i++){swprintf(path,MAX_PATH,L"%ls\\record-%03d-long-name-abcdef0123456789.dat",dir,i);DeleteFileW(path);}RemoveDirectoryW(dir);
    printf("RESULT failures=%d\n",failures);return failures?1:0;
}
