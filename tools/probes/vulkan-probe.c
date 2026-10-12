/* SPDX-License-Identifier: LGPL-2.1-or-later */
#define VK_NO_PROTOTYPES
#define VK_USE_PLATFORM_WIN32_KHR
#include <windows.h>
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int has_extension(const VkExtensionProperties *properties, uint32_t count, const char *name)
{
    uint32_t i;
    for (i = 0; i < count; ++i)
        if (!strcmp(properties[i].extensionName, name)) return 1;
    return 0;
}

int main(int argc, char **argv)
{
    HMODULE module = LoadLibraryW(L"vulkan-1.dll");
    PFN_vkGetInstanceProcAddr get;
    PFN_vkEnumerateInstanceExtensionProperties enumerate_extensions;
    PFN_vkCreateInstance create;
    PFN_vkDestroyInstance destroy = NULL;
    PFN_vkEnumeratePhysicalDevices enumerate_devices;
    PFN_vkGetPhysicalDeviceProperties get_properties;
    VkExtensionProperties *extensions = NULL;
    VkPhysicalDevice *devices = NULL;
    VkInstance instance = VK_NULL_HANDLE;
    VkSurfaceKHR surface = VK_NULL_HANDLE;
    PFN_vkDestroySurfaceKHR destroy_surface = NULL;
    HWND window = NULL;
    uint32_t extension_count = 0, device_count = 0, count = 0, i;
    const char *enabled[3];
    VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pApplicationName = "Wine Vulkan probe", .apiVersion = VK_API_VERSION_1_0};
    VkInstanceCreateInfo info = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app};
    VkResult result = VK_ERROR_INITIALIZATION_FAILED;
    int with_surface = argc == 2 && !strcmp(argv[1], "--surface"), ok = 0;
    if (argc > 2 || (argc == 2 && !with_surface)) { puts("Usage: vulkan-probe.exe [--surface]"); return 2; }
    printf("Process bits: %u\n", (unsigned)(sizeof(void *) * 8));
    if (!module) { printf("Load vulkan-1.dll failed: %lu\n", GetLastError()); goto done; }
    get = (PFN_vkGetInstanceProcAddr)GetProcAddress(module, "vkGetInstanceProcAddr");
    if (!get) goto done;
    enumerate_extensions = (PFN_vkEnumerateInstanceExtensionProperties)get(NULL, "vkEnumerateInstanceExtensionProperties");
    create = (PFN_vkCreateInstance)get(NULL, "vkCreateInstance");
    if (!enumerate_extensions || !create) goto done;
    if ((result = enumerate_extensions(NULL, &extension_count, NULL)) != VK_SUCCESS) goto done;
    if (!(extensions = calloc(extension_count ? extension_count : 1, sizeof(*extensions)))) goto done;
    if ((result = enumerate_extensions(NULL, &extension_count, extensions)) != VK_SUCCESS) goto done;
    if (has_extension(extensions, extension_count, VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME))
    {
        enabled[count++] = VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME;
        info.flags |= VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
    }
    if (with_surface)
    {
        if (!has_extension(extensions, extension_count, VK_KHR_SURFACE_EXTENSION_NAME)
                || !has_extension(extensions, extension_count, VK_KHR_WIN32_SURFACE_EXTENSION_NAME))
        { puts("Required Win32 surface extensions unavailable"); goto done; }
        enabled[count++] = VK_KHR_SURFACE_EXTENSION_NAME;
        enabled[count++] = VK_KHR_WIN32_SURFACE_EXTENSION_NAME;
    }
    info.enabledExtensionCount = count; info.ppEnabledExtensionNames = enabled;
    if ((result = create(&info, NULL, &instance)) != VK_SUCCESS) goto done;
    destroy = (PFN_vkDestroyInstance)get(instance, "vkDestroyInstance");
    enumerate_devices = (PFN_vkEnumeratePhysicalDevices)get(instance, "vkEnumeratePhysicalDevices");
    get_properties = (PFN_vkGetPhysicalDeviceProperties)get(instance, "vkGetPhysicalDeviceProperties");
    if (!destroy || !enumerate_devices || !get_properties) goto done;
    if ((result = enumerate_devices(instance, &device_count, NULL)) != VK_SUCCESS || !device_count) goto done;
    if (!(devices = calloc(device_count, sizeof(*devices)))) goto done;
    if ((result = enumerate_devices(instance, &device_count, devices)) != VK_SUCCESS) goto done;
    for (i = 0; i < device_count; ++i)
    {
        VkPhysicalDeviceProperties props;
        get_properties(devices[i], &props);
        printf("Device: %s; Vulkan %u.%u.%u\n", props.deviceName,
                VK_API_VERSION_MAJOR(props.apiVersion), VK_API_VERSION_MINOR(props.apiVersion), VK_API_VERSION_PATCH(props.apiVersion));
    }
    if (with_surface)
    {
        PFN_vkCreateWin32SurfaceKHR create_surface = (PFN_vkCreateWin32SurfaceKHR)get(instance, "vkCreateWin32SurfaceKHR");
        PFN_vkGetPhysicalDeviceSurfaceFormatsKHR get_formats = (PFN_vkGetPhysicalDeviceSurfaceFormatsKHR)get(instance, "vkGetPhysicalDeviceSurfaceFormatsKHR");
        VkWin32SurfaceCreateInfoKHR surface_info = {.sType = VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR};
        destroy_surface = (PFN_vkDestroySurfaceKHR)get(instance, "vkDestroySurfaceKHR");
        if (!create_surface || !destroy_surface || !get_formats) goto done;
        window = CreateWindowW(L"STATIC", L"Wine Vulkan surface probe", WS_OVERLAPPEDWINDOW,
                CW_USEDEFAULT, CW_USEDEFAULT, 320, 240, NULL, NULL, GetModuleHandleW(NULL), NULL);
        if (!window) goto done;
        ShowWindow(window, SW_SHOW);
        surface_info.hinstance = GetModuleHandleW(NULL); surface_info.hwnd = window;
        if ((result = create_surface(instance, &surface_info, NULL, &surface)) != VK_SUCCESS) goto done;
        if ((result = get_formats(devices[0], surface, &count, NULL)) != VK_SUCCESS || !count) goto done;
        printf("Win32 surface created; formats: %u\n", count);
    }
    ok = 1;
done:
    printf("Vulkan probe: %s; VkResult=%d\n", ok ? "PASS" : "FAIL", result);
    if (surface && destroy_surface) destroy_surface(instance, surface, NULL);
    if (window) DestroyWindow(window);
    if (instance && destroy) destroy(instance, NULL);
    free(devices); free(extensions);
    if (module) FreeLibrary(module);
    return ok ? 0 : 1;
}
