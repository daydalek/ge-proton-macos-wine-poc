// SPDX-License-Identifier: LGPL-2.1-or-later
#include <windows.h>
#include <dbt.h>
#include <stdio.h>
static HANDLE gate;static HDEVNOTIFY shared;static DWORD WINAPI drop(void *p){WaitForSingleObject(gate,INFINITE);SetLastError(0);return UnregisterDeviceNotification(shared)?1:0;}
static HDEVNOTIFY add(HWND w){DEV_BROADCAST_DEVICEINTERFACE_W f={0};f.dbcc_size=sizeof(f);f.dbcc_devicetype=DBT_DEVTYP_DEVICEINTERFACE;return RegisterDeviceNotificationW(w,&f,DEVICE_NOTIFY_WINDOW_HANDLE|DEVICE_NOTIFY_ALL_INTERFACE_CLASSES);}
int main(void){unsigned fail=0;HWND w=CreateWindowW(L"STATIC",L"device notification probe",WS_POPUP,0,0,100,100,NULL,NULL,NULL,NULL);if(!w)return 2;SetLastError(0);BOOL a=UnregisterDeviceNotification((HDEVNOTIFY)(ULONG_PTR)1);DWORD e=GetLastError();printf("invalid: %d error=%lu\n",a,e);fail+=a||e!=ERROR_INVALID_HANDLE;
 void *fake=HeapAlloc(GetProcessHeap(),HEAP_ZERO_MEMORY,256);SetLastError(0);a=UnregisterDeviceNotification(fake);e=GetLastError();printf("foreign pointer: %d error=%lu\n",a,e);fail+=a||e!=ERROR_INVALID_HANDLE;HeapFree(GetProcessHeap(),0,fake);
 HDEVNOTIFY h=add(w);if(!h){printf("register failed: %lu\n",GetLastError());return 3;}a=UnregisterDeviceNotification(h);printf("valid: %d\n",a);fail+=!a;SetLastError(0);a=UnregisterDeviceNotification(h);e=GetLastError();printf("duplicate: %d error=%lu\n",a,e);fail+=a||e!=ERROR_INVALID_HANDLE;
 for(int i=0;i<32;i++){shared=add(w);if(!shared)return 4;gate=CreateEventW(NULL,TRUE,FALSE,NULL);HANDLE t[2]={CreateThread(NULL,0,drop,NULL,0,NULL),CreateThread(NULL,0,drop,NULL,0,NULL)};SetEvent(gate);if(WaitForMultipleObjects(2,t,TRUE,10000)!=WAIT_OBJECT_0)return 5;DWORD x,y;GetExitCodeThread(t[0],&x);GetExitCodeThread(t[1],&y);fail+=x+y!=1;CloseHandle(t[0]);CloseHandle(t[1]);CloseHandle(gate);}
 DestroyWindow(w);printf("Device notify probe: %s; bits=%u; concurrent rounds=32\n",fail?"FAIL":"PASS",(unsigned)sizeof(void*)*8);return !!fail;}
