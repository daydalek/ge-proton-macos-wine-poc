// SPDX-License-Identifier: LGPL-2.1-or-later
#include <windows.h>
#include <stdio.h>
#include <wchar.h>
static int run_child(const WCHAR *path, const WCHAR *mode)
{
 WCHAR cmd[2048],saved[2048];STARTUPINFOW si={sizeof(si)};PROCESS_INFORMATION pi;DWORD code;
 swprintf(cmd,2048,L"\"%ls\" --child %ls",path,mode);wcscpy(saved,cmd);
 if(!CreateProcessW(path,cmd,NULL,NULL,FALSE,0,NULL,NULL,&si,&pi))return 100;
 if(WaitForSingleObject(pi.hProcess,15000)!=WAIT_OBJECT_0){TerminateProcess(pi.hProcess,101);return 101;}
 GetExitCodeProcess(pi.hProcess,&code);CloseHandle(pi.hThread);CloseHandle(pi.hProcess);
 return wcscmp(cmd,saved)?102:code;
}
int wmain(int argc,WCHAR **argv)
{
 WCHAR path[1024],key[1280];HKEY h;DWORD v=7,disposition,saved_type=0,saved_size=0;BYTE *saved_value=NULL;int failures=0,code;WCHAR *base;
 if(argc>=3&&!wcscmp(argv[1],L"--child")){
  if(!wcscmp(argv[2],L"plain"))return argc==3?0:21;
  return argc==5&&!wcscmp(argv[3],L"--test")&&!wcscmp(argv[4],L"参数 空格")?0:22;
 }
 GetModuleFileNameW(NULL,path,1024);base=wcsrchr(path,'\\');base=base?base+1:path;
 swprintf(key,1280,L"Software\\Wine\\AppDefaults\\%ls",base);
 if(RegCreateKeyExW(HKEY_CURRENT_USER,key,0,NULL,0,KEY_ALL_ACCESS,NULL,&h,&disposition))return 2;
 DWORD prior=RegQueryValueExW(h,L"CommandLineAppend",NULL,&saved_type,NULL,&saved_size);
 if(prior!=ERROR_SUCCESS&&prior!=ERROR_FILE_NOT_FOUND){RegCloseKey(h);return 3;}
 if(prior==ERROR_SUCCESS){saved_value=HeapAlloc(GetProcessHeap(),0,saved_size?saved_size:1);if(!saved_value){RegCloseKey(h);return 4;}if(RegQueryValueExW(h,L"CommandLineAppend",NULL,&saved_type,saved_value,&saved_size)){HeapFree(GetProcessHeap(),0,saved_value);RegCloseKey(h);return 5;}}
 RegDeleteValueW(h,L"CommandLineAppend");code=run_child(path,L"plain");printf("absent: %d\n",code);failures+=!!code;
 const WCHAR suffix[]=L"--test \"参数 空格\"";
 RegSetValueExW(h,L"CommandLineAppend",0,REG_SZ,(const BYTE*)suffix,sizeof(suffix));code=run_child(path,L"append");printf("quoted Unicode, caller unchanged: %d\n",code);failures+=!!code;
 RegSetValueExW(h,L"CommandLineAppend",0,REG_DWORD,(const BYTE*)&v,sizeof(v));code=run_child(path,L"plain");printf("wrong registry type: %d\n",code);failures+=!!code;
 RegSetValueExW(h,L"CommandLineAppend",0,REG_SZ,(const BYTE*)L"",sizeof(WCHAR));code=run_child(path,L"plain");printf("empty: %d\n",code);failures+=!!code;
 WCHAR *large=HeapAlloc(GetProcessHeap(),0,32767*sizeof(WCHAR));for(int i=0;i<32766;i++)large[i]='x';large[32766]=0;
 RegSetValueExW(h,L"CommandLineAppend",0,REG_SZ,(const BYTE*)large,32767*sizeof(WCHAR));HeapFree(GetProcessHeap(),0,large);
 code=run_child(path,L"plain");printf("oversized: %d\n",code);failures+=!!code;
 if(saved_value){RegSetValueExW(h,L"CommandLineAppend",0,saved_type,saved_value,saved_size);HeapFree(GetProcessHeap(),0,saved_value);}else RegDeleteValueW(h,L"CommandLineAppend");RegCloseKey(h);if(disposition==REG_CREATED_NEW_KEY)RegDeleteKeyW(HKEY_CURRENT_USER,key);
 printf("Command line probe: %s; bits=%u\n",failures?"FAIL":"PASS",(unsigned)sizeof(void*)*8);return !!failures;
}
