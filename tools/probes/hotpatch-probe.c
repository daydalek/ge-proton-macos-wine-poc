/* SPDX-License-Identifier: LGPL-2.1-or-later
 * Verify i386 Windows hotpatch prologues (5x 0x90 + 8b ff) and runtime hook
 * installation/chaining/restoration across the six GDI32/USER32 APIs used by
 * rUGP localization patches and compatible hotpatchers.
 */
#include <windows.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>

static char probe_font[LF_FACESIZE] = "Arial";

typedef HFONT (WINAPI *create_font_indirect_a_fn)(const LOGFONTA *);
typedef DWORD (WINAPI *get_glyph_outline_a_fn)(HDC, UINT, UINT, LPGLYPHMETRICS, DWORD, LPVOID, const MAT2 *);
typedef INT   (WINAPI *enum_font_families_ex_a_fn)(HDC, LPLOGFONTA, FONTENUMPROCA, LPARAM, DWORD);
typedef BOOL  (WINAPI *set_window_text_a_fn)(HWND, LPCSTR);
typedef HWND  (WINAPI *create_window_ex_a_fn)(DWORD, LPCSTR, LPCSTR, DWORD, INT, INT, INT, INT, HWND, HMENU, HINSTANCE, LPVOID);
typedef BOOL  (WINAPI *append_menu_a_fn)(HMENU, UINT, UINT_PTR, LPCSTR);

#ifndef _WIN64

struct hotpatch_site
{
    const char *dll;
    const char *name;
    BYTE *entry;
    void *hook;
    void **orig_out;
    BYTE saved[7];
};

static create_font_indirect_a_fn orig_CreateFontIndirectA;
static get_glyph_outline_a_fn orig_GetGlyphOutlineA;
static enum_font_families_ex_a_fn orig_EnumFontFamiliesExA;
static set_window_text_a_fn orig_SetWindowTextA;
static create_window_ex_a_fn orig_CreateWindowExA;
static append_menu_a_fn orig_AppendMenuA;

static create_font_indirect_a_fn chain_CreateFontIndirectA;
static create_font_indirect_a_fn e9_trampoline_CreateFontIndirectA;

static LONG hits_CreateFontIndirectA;
static LONG hits_GetGlyphOutlineA;
static LONG hits_EnumFontFamiliesExA;
static LONG hits_SetWindowTextA;
static LONG hits_CreateWindowExA;
static LONG hits_AppendMenuA;
static LONG hits_chain_CreateFontIndirectA;
static LONG hits_e9_CreateFontIndirectA;
static BYTE last_created_charset;

static HFONT WINAPI hook_CreateFontIndirectA(const LOGFONTA *lf)
{
    LOGFONTA copy;
    InterlockedIncrement(&hits_CreateFontIndirectA);
    if (lf)
    {
        copy = *lf;
        if (copy.lfCharSet == SHIFTJIS_CHARSET)
            copy.lfCharSet = GB2312_CHARSET;
        last_created_charset = copy.lfCharSet;
        return orig_CreateFontIndirectA(&copy);
    }
    return orig_CreateFontIndirectA(lf);
}

static HFONT WINAPI hook_chain_CreateFontIndirectA(const LOGFONTA *lf)
{
    InterlockedIncrement(&hits_chain_CreateFontIndirectA);
    return chain_CreateFontIndirectA(lf);
}

static HFONT WINAPI hook_e9_CreateFontIndirectA(const LOGFONTA *lf)
{
    InterlockedIncrement(&hits_e9_CreateFontIndirectA);
    return e9_trampoline_CreateFontIndirectA(lf);
}

static DWORD WINAPI hook_GetGlyphOutlineA(HDC hdc, UINT ch, UINT fmt, LPGLYPHMETRICS gm,
                                          DWORD size, LPVOID buf, const MAT2 *mat)
{
    InterlockedIncrement(&hits_GetGlyphOutlineA);
    if (ch == 0x8140)
        ch = 'A';
    return orig_GetGlyphOutlineA(hdc, ch, fmt, gm, size, buf, mat);
}

static INT WINAPI hook_EnumFontFamiliesExA(HDC hdc, LPLOGFONTA lf, FONTENUMPROCA proc,
                                           LPARAM lparam, DWORD flags)
{
    LOGFONTA copy;
    InterlockedIncrement(&hits_EnumFontFamiliesExA);
    if (lf)
    {
        copy = *lf;
        if (copy.lfCharSet == SHIFTJIS_CHARSET)
            copy.lfCharSet = DEFAULT_CHARSET;
        return orig_EnumFontFamiliesExA(hdc, &copy, proc, lparam, flags);
    }
    return orig_EnumFontFamiliesExA(hdc, lf, proc, lparam, flags);
}

static BOOL WINAPI hook_SetWindowTextA(HWND hwnd, LPCSTR text)
{
    InterlockedIncrement(&hits_SetWindowTextA);
    return orig_SetWindowTextA(hwnd, text && !strcmp(text, "raw-title") ? "hooked-title" : text);
}

static HWND WINAPI hook_CreateWindowExA(DWORD ex_style, LPCSTR cls, LPCSTR name, DWORD style,
                                        INT x, INT y, INT w, INT h, HWND parent, HMENU menu,
                                        HINSTANCE inst, LPVOID param)
{
    InterlockedIncrement(&hits_CreateWindowExA);
    if (name && !strcmp(name, "raw-create"))
        name = "hooked-create";
    return orig_CreateWindowExA(ex_style, cls, name, style, x, y, w, h, parent, menu, inst, param);
}

static BOOL WINAPI hook_AppendMenuA(HMENU menu, UINT flags, UINT_PTR id, LPCSTR data)
{
    InterlockedIncrement(&hits_AppendMenuA);
    if ((flags & MF_STRING) == MF_STRING && data && !strcmp(data, "raw-menu"))
        data = "hooked-menu";
    return orig_AppendMenuA(menu, flags, id, data);
}

/* Exact byte-for-byte algorithm from rugpHook.dll RVA 0x1000. */
static BOOL install_rugp_hotpatch(struct hotpatch_site *site)
{
    HMODULE mod = LoadLibraryA(site->dll);
    BYTE *esi = mod ? (BYTE *)GetProcAddress(mod, site->name) : NULL;
    BYTE *ebx;
    DWORD old_prot = 0;

    if (!esi) return FALSE;
    site->entry = esi;
    ebx = esi - 5;
    if (!VirtualProtect(ebx, 7, PAGE_EXECUTE_READWRITE, &old_prot))
        return FALSE;
    memcpy(site->saved, ebx, 7);

    if (esi[0] == 0xe9)
    {
        int32_t rel = *(int32_t *)(esi + 1);
        *site->orig_out = (void *)(esi + 5 + rel);
        *(int32_t *)(esi + 1) = (int32_t)((intptr_t)site->hook - (intptr_t)(esi + 5));
        FlushInstructionCache(GetCurrentProcess(), ebx, 7);
        VirtualProtect(ebx, 7, old_prot, &old_prot);
        return TRUE;
    }

    if (*(uint16_t *)esi != 0xff8b ||
        *(uint32_t *)ebx != 0x90909090u ||
        esi[-1] != 0x90)
    {
        VirtualProtect(ebx, 7, old_prot, &old_prot);
        return FALSE;
    }

    *(uint16_t *)esi = 0xf9eb;
    ebx[0] = 0xe9;
    *(int32_t *)(esi - 4) = (int32_t)((intptr_t)site->hook - (intptr_t)esi);
    *site->orig_out = (void *)(esi + 2);
    FlushInstructionCache(GetCurrentProcess(), ebx, 7);
    VirtualProtect(ebx, 7, old_prot, &old_prot);
    return TRUE;
}

/* Second independent hotpatcher sample: Detours-style short-jump follower that
 * chains an already-hotpatched (EB F9 -> E9 rel32) entry point. */
static BOOL install_chained_hotpatch(BYTE *entry, void *new_hook, void **prev_target)
{
    DWORD old_prot = 0;
    BYTE *patch_base = entry - 5;

    if (!entry || *(uint16_t *)entry != 0xf9eb || patch_base[0] != 0xe9)
        return FALSE;
    if (!VirtualProtect(patch_base, 7, PAGE_EXECUTE_READWRITE, &old_prot))
        return FALSE;
    *prev_target = (void *)(entry + *(int32_t *)(entry - 4));
    *(int32_t *)(entry - 4) = (int32_t)((intptr_t)new_hook - (intptr_t)entry);
    FlushInstructionCache(GetCurrentProcess(), patch_base, 7);
    VirtualProtect(patch_base, 7, old_prot, &old_prot);
    return TRUE;
}

static BOOL restore_hotpatch(const struct hotpatch_site *site)
{
    DWORD old_prot = 0;
    BYTE *ebx = site->entry - 5;

    if (!site->entry || !VirtualProtect(ebx, 7, PAGE_EXECUTE_READWRITE, &old_prot))
        return FALSE;
    memcpy(ebx, site->saved, 7);
    FlushInstructionCache(GetCurrentProcess(), ebx, 7);
    VirtualProtect(ebx, 7, old_prot, &old_prot);
    return TRUE;
}

static int check_entry_layout(const char *dll, const char *name)
{
    HMODULE mod = LoadLibraryA(dll);
    const BYTE *p = mod ? (const BYTE *)GetProcAddress(mod, name) : NULL;
    int bad = 0;

    if (!p)
    {
        printf("MISSING %s!%s\n", dll, name);
        return 1;
    }
    /* Verify 2-byte alignment, 5-byte 0x90 prefix, and 8b ff entry. */
    if (((uintptr_t)p & 1) != 0 || ((uintptr_t)p & 3) > 2)
        bad = 1;
    for (int i = -5; i < 0; i++)
        if (p[i] != 0x90) bad = 1;
    if (p[0] != 0x8b || p[1] != 0xff)
        bad = 1;

    printf("LAYOUT %s!%s addr=%p align=%u bytes=%02x %02x %02x %02x %02x | %02x %02x | %02x %02x %02x status=%s\n",
           dll, name, (const void *)p, (unsigned)((uintptr_t)p & 15),
           p[-5], p[-4], p[-3], p[-2], p[-1], p[0], p[1], p[2], p[3], p[4],
           bad ? "FAIL" : "OK");
    return bad;
}

#endif /* !_WIN64 */

static int CALLBACK enum_font_cb(const LOGFONTA *lf, const TEXTMETRICA *tm, DWORD type, LPARAM lparam)
{
    (void)lf;
    (void)tm;
    (void)type;
    (*(int *)lparam)++;
    return 0;
}

static int exercise_baseline_apis(BYTE req_charset, UINT glyph_char,
                                  const char *expected_create_title,
                                  const char *expected_set_title, const char *expected_menu_text)
{
    static const MAT2 ident = { {0, 1}, {0, 0}, {0, 0}, {0, 1} };
    LOGFONTA lf;
    GLYPHMETRICS gm;
    HDC hdc;
    HFONT hfont, old_font;
    HWND hwnd;
    HMENU hmenu;
    char buf[64];
    int enum_count = 0;
    int failures = 0;

    memset(&lf, 0, sizeof(lf));
    lf.lfHeight = -16;
    lf.lfCharSet = req_charset;
    strcpy(lf.lfFaceName, probe_font);

    hfont = CreateFontIndirectA(&lf);
    if (!hfont) failures++;

    hdc = CreateCompatibleDC(NULL);
    if (!hdc) failures++;
    old_font = hdc ? SelectObject(hdc, hfont) : NULL;

    memset(&gm, 0, sizeof(gm));
    if (GetGlyphOutlineA(hdc, glyph_char, GGO_METRICS, &gm, 0, NULL, &ident) == GDI_ERROR)
        failures++;

    EnumFontFamiliesExA(hdc, &lf, enum_font_cb, (LPARAM)&enum_count, 0);
    if (enum_count <= 0) failures++;

    if (old_font) SelectObject(hdc, old_font);
    if (hdc) DeleteDC(hdc);
    if (hfont) DeleteObject(hfont);

    hwnd = CreateWindowExA(0, "STATIC", "raw-create", WS_POPUP, 0, 0, 64, 32, NULL, NULL, GetModuleHandleA(NULL), NULL);
    if (!hwnd)
        failures++;
    else
    {
        buf[0] = '\0';
        GetWindowTextA(hwnd, buf, sizeof(buf));
        if (strcmp(buf, expected_create_title) != 0)
            failures++;
        if (!SetWindowTextA(hwnd, "raw-title"))
            failures++;
        buf[0] = '\0';
        GetWindowTextA(hwnd, buf, sizeof(buf));
        if (strcmp(buf, expected_set_title) != 0)
            failures++;
        DestroyWindow(hwnd);
    }

    hmenu = CreatePopupMenu();
    if (!hmenu)
        failures++;
    else
    {
        if (!AppendMenuA(hmenu, MF_STRING, 101, "raw-menu"))
            failures++;
        buf[0] = '\0';
        GetMenuStringA(hmenu, 101, buf, sizeof(buf), MF_BYCOMMAND);
        if (strcmp(buf, expected_menu_text) != 0)
            failures++;
        DestroyMenu(hmenu);
    }

    return failures;
}

int main(void)
{
    int failures = 0;

    setvbuf(stdout, NULL, _IONBF, 0);
    if (GetEnvironmentVariableA("WINE_PROBE_FONT", probe_font, sizeof(probe_font)) >= sizeof(probe_font))
        return 2;
    printf("HOTPATCH_FONT %s\n", probe_font);
    failures += exercise_baseline_apis(DEFAULT_CHARSET, 'A', "raw-create", "raw-title", "raw-menu");

#ifndef _WIN64
    struct hotpatch_site sites[6] = {
        { "gdi32.dll",  "CreateFontIndirectA", NULL, (void *)hook_CreateFontIndirectA, (void **)&orig_CreateFontIndirectA, {0} },
        { "gdi32.dll",  "GetGlyphOutlineA",    NULL, (void *)hook_GetGlyphOutlineA,    (void **)&orig_GetGlyphOutlineA,    {0} },
        { "gdi32.dll",  "EnumFontFamiliesExA", NULL, (void *)hook_EnumFontFamiliesExA, (void **)&orig_EnumFontFamiliesExA, {0} },
        { "user32.dll", "SetWindowTextA",      NULL, (void *)hook_SetWindowTextA,      (void **)&orig_SetWindowTextA,      {0} },
        { "user32.dll", "CreateWindowExA",     NULL, (void *)hook_CreateWindowExA,     (void **)&orig_CreateWindowExA,     {0} },
        { "user32.dll", "AppendMenuA",         NULL, (void *)hook_AppendMenuA,         (void **)&orig_AppendMenuA,         {0} },
    };

    for (int i = 0; i < 6; i++)
        failures += check_entry_layout(sites[i].dll, sites[i].name);

    /* Also check import-thunk and existing DECLSPEC_HOTPATCH exports. */
    failures += check_entry_layout("kernel32.dll", "CreateFileA");
    failures += check_entry_layout("user32.dll", "SetWindowTextW");
    failures += check_entry_layout("gdi32.dll", "GetStockObject");

    for (int i = 0; i < 6; i++)
    {
        if (!install_rugp_hotpatch(&sites[i]))
        {
            printf("HOOK_INSTALL_FAIL %s!%s\n", sites[i].dll, sites[i].name);
            failures++;
        }
    }

    if (!failures)
    {
        int is_relay = (sites[0].entry[3] == 0x8b && sites[0].entry[4] == 0xec && sites[0].entry[5] == 0x5d);
        LOGFONTA lf_test;

        memset(&lf_test, 0, sizeof(lf_test));
        lf_test.lfHeight = -12;
        lf_test.lfCharSet = SHIFTJIS_CHARSET;
        strcpy(lf_test.lfFaceName, probe_font);

        failures += exercise_baseline_apis(SHIFTJIS_CHARSET, 0x8140, "hooked-create", "hooked-title", "hooked-menu");
        if (last_created_charset != GB2312_CHARSET)
            failures++;

        if (!is_relay)
        {
            /* Intra-DLL callers must also traverse the hotpatched entry points. */
            HFONT hf = CreateFontA(-12, 0, 0, 0, FW_NORMAL, 0, 0, 0, SHIFTJIS_CHARSET,
                                   OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, DEFAULT_QUALITY,
                                   DEFAULT_PITCH, probe_font);
            if (!hf) failures++;
            else DeleteObject(hf);

            int enum_count = 0;
            HDC hdc = CreateCompatibleDC(NULL);
            if (!hdc) failures++;
            else
            {
                EnumFontFamiliesA(hdc, probe_font, enum_font_cb, (LPARAM)&enum_count);
                DeleteDC(hdc);
                if (enum_count <= 0) failures++;
            }

            HMENU hmenu = CreatePopupMenu();
            if (!hmenu) failures++;
            else
            {
                char menu_buf[64] = {0};
                if (!ChangeMenuA(hmenu, 0, "raw-menu", 102, MF_APPEND | MF_STRING))
                    failures++;
                GetMenuStringA(hmenu, 102, menu_buf, sizeof(menu_buf), MF_BYCOMMAND);
                if (strcmp(menu_buf, "hooked-menu") != 0)
                    failures++;
                DestroyMenu(hmenu);
            }

            if (hits_CreateFontIndirectA < 2 || hits_GetGlyphOutlineA < 1 ||
                hits_EnumFontFamiliesExA < 2 || hits_SetWindowTextA < 1 ||
                hits_CreateWindowExA < 1 || hits_AppendMenuA < 2)
                failures++;
        }
        else if (hits_CreateFontIndirectA < 1 || hits_GetGlyphOutlineA < 1 ||
                 hits_EnumFontFamiliesExA < 1 || hits_SetWindowTextA < 1 ||
                 hits_CreateWindowExA < 1 || hits_AppendMenuA < 1)
        {
            failures++;
        }

        /* Sample 2: chain a second hotpatcher onto CreateFontIndirectA. */
        LONG before_chain = hits_CreateFontIndirectA;
        if (!install_chained_hotpatch(sites[0].entry, (void *)hook_chain_CreateFontIndirectA,
                                      (void **)&chain_CreateFontIndirectA))
            failures++;
        else
        {
            HFONT hf = CreateFontIndirectA(&lf_test);
            if (!hf) failures++;
            else DeleteObject(hf);
            if (hits_chain_CreateFontIndirectA != 1 || hits_CreateFontIndirectA != before_chain + 1)
                failures++;
        }

        for (int i = 0; i < 6; i++)
            if (!restore_hotpatch(&sites[i]))
                failures++;

        /* Sample 3: pre-existing E9 5-byte relative jump at entry[0..4] chained by rugpHook. */
        if (!is_relay)
        {
            BYTE *entry = sites[0].entry;
            BYTE saved5[5];
            DWORD old_prot = 0;
            BYTE *tramp = VirtualAlloc(NULL, 32, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
            if (!tramp || !VirtualProtect(entry - 5, 10, PAGE_EXECUTE_READWRITE, &old_prot))
                failures++;
            else
            {
                memcpy(saved5, entry, 5);
                memcpy(tramp, entry, 5);
                tramp[5] = 0xe9;
                *(int32_t *)(tramp + 6) = (int32_t)((intptr_t)(entry + 5) - (intptr_t)(tramp + 10));
                e9_trampoline_CreateFontIndirectA = (create_font_indirect_a_fn)tramp;

                entry[0] = 0xe9;
                *(int32_t *)(entry + 1) = (int32_t)((intptr_t)hook_e9_CreateFontIndirectA - (intptr_t)(entry + 5));
                FlushInstructionCache(GetCurrentProcess(), entry, 5);
                VirtualProtect(entry - 5, 10, old_prot, &old_prot);

                LONG before_e9 = hits_CreateFontIndirectA;
                if (!install_rugp_hotpatch(&sites[0]))
                    failures++;
                else
                {
                    HFONT hf = CreateFontIndirectA(&lf_test);
                    if (!hf) failures++;
                    else DeleteObject(hf);
                    if (hits_e9_CreateFontIndirectA != 1 || hits_CreateFontIndirectA != before_e9 + 1)
                        failures++;
                }

                VirtualProtect(entry - 5, 10, PAGE_EXECUTE_READWRITE, &old_prot);
                memcpy(entry, saved5, 5);
                FlushInstructionCache(GetCurrentProcess(), entry, 5);
                VirtualProtect(entry - 5, 10, old_prot, &old_prot);
            }
            if (tramp) VirtualFree(tramp, 0, MEM_RELEASE);
        }

        LONG before_unhook = hits_CreateFontIndirectA;
        failures += exercise_baseline_apis(DEFAULT_CHARSET, 'A', "raw-create", "raw-title", "raw-menu");
        if (hits_CreateFontIndirectA != before_unhook)
            failures++;
    }

    printf("HOTPATCH_HITS font=%ld glyph=%ld enum=%ld text=%ld wnd=%ld menu=%ld chain=%ld e9=%ld charset=0x%02x\n",
           hits_CreateFontIndirectA, hits_GetGlyphOutlineA, hits_EnumFontFamiliesExA,
           hits_SetWindowTextA, hits_CreateWindowExA, hits_AppendMenuA,
           hits_chain_CreateFontIndirectA, hits_e9_CreateFontIndirectA,
           (unsigned)last_created_charset);
#endif

    printf("HOTPATCH_PROBE_RESULT failures=%d\n", failures);
    return failures ? 1 : 0;
}
