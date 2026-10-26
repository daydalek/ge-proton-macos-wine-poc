/* SPDX-License-Identifier: LGPL-2.1-or-later */
#pragma once
#include <stdint.h>
#include <stddef.h>

/* Private arm64-helper protocol, independent of the public Wine ABI.
 * One in-flight request per socket; socket reply publishes shared writes.
 * BGRA rows are tightly packed. The anonymous file is inherited, never named.
 */
#define WGDI_COREML_MAGIC 0x5747434du
#define WGDI_COREML_VERSION 1u
#define WGDI_COREML_PIXELS (2u * 1024u * 1024u)
struct wgdi_coreml_frame {
    uint32_t magic, version, sequence, width, height, status;
    uint64_t inference_ns;
    char error[256];
};
#define WGDI_COREML_BYTES (sizeof(struct wgdi_coreml_frame) + (size_t)WGDI_COREML_PIXELS * 20)
