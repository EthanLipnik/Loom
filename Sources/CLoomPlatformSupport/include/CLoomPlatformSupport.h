#ifndef CLOOMPLATFORMSUPPORT_H
#define CLOOMPLATFORMSUPPORT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct loom_dnssd_browser loom_dnssd_browser;
typedef struct loom_dnssd_advertiser loom_dnssd_advertiser;

typedef enum loom_dnssd_event_kind {
    LOOM_DNSSD_EVENT_READY = 1,
    LOOM_DNSSD_EVENT_ADDED = 2,
    LOOM_DNSSD_EVENT_CHANGED = 3,
    LOOM_DNSSD_EVENT_REMOVED = 4,
    LOOM_DNSSD_EVENT_FAILED = 5,
    LOOM_DNSSD_EVENT_CANCELLED = 6
} loom_dnssd_event_kind;

typedef struct loom_dnssd_service_result {
    const char *instance_name_utf8;
    const char *host_name_utf8;
    uint64_t event_sequence;
    uint16_t port;
    uint32_t interface_index;
    uint32_t ttl_seconds;
    const char *ipv4_address_utf8;
    const char *ipv6_address_utf8;
    size_t property_count;
    const char *const *property_keys_utf8;
    const char *const *property_values_utf8;
} loom_dnssd_service_result;

typedef void (*loom_dnssd_browser_callback)(
    loom_dnssd_event_kind kind,
    uint32_t status,
    const loom_dnssd_service_result *result,
    void *context
);

typedef void (*loom_dnssd_advertiser_callback)(uint32_t status, void *context);
typedef void (*loom_context_release_callback)(void *context);

loom_dnssd_browser *loom_dnssd_browser_start(
    const char *query_name_utf8,
    uint32_t interface_index,
    loom_dnssd_browser_callback callback,
    void *context,
    loom_context_release_callback release_context,
    uint32_t *error_code
);

void loom_dnssd_browser_cancel(loom_dnssd_browser *browser);
void loom_dnssd_browser_release(loom_dnssd_browser *browser);

loom_dnssd_advertiser *loom_dnssd_advertiser_start(
    const char *instance_name_utf8,
    const char *host_name_utf8,
    uint16_t port,
    uint32_t interface_index,
    size_t property_count,
    const char *const *property_keys_utf8,
    const char *const *property_values_utf8,
    loom_dnssd_advertiser_callback callback,
    void *context,
    loom_context_release_callback release_context,
    uint32_t *error_code
);

int loom_dnssd_advertiser_stop(
    loom_dnssd_advertiser *advertiser,
    uint32_t *error_code
);
void loom_dnssd_advertiser_release(loom_dnssd_advertiser *advertiser);

int loom_platform_protect_current_user(
    const uint8_t *input,
    size_t input_length,
    uint8_t **output,
    size_t *output_length,
    uint32_t *error_code
);

int loom_platform_unprotect_current_user(
    const uint8_t *input,
    size_t input_length,
    uint8_t **output,
    size_t *output_length,
    uint32_t *error_code
);

int loom_platform_read_file(
    const char *path_utf8,
    size_t maximum_length,
    uint8_t **output,
    size_t *output_length,
    int *exists,
    uint32_t *error_code
);

int loom_platform_atomic_replace_user_only(
    const char *path_utf8,
    const uint8_t *contents,
    size_t contents_length,
    uint32_t *error_code
);

int loom_platform_delete_file(
    const char *path_utf8,
    uint32_t *error_code
);

void loom_platform_free(void *buffer);
void loom_platform_secure_free(void *buffer, size_t length);

#ifdef __cplusplus
}
#endif

#endif
