#include "CLoomPlatformSupport.h"

#if defined(_WIN32)
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#define WIN32_LEAN_AND_MEAN
#define UNICODE
#define _UNICODE
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <aclapi.h>
#include <dpapi.h>
#include <windns.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

static wchar_t *loom_utf8_to_wide(const char *value, uint32_t *error_code) {
    if (value == NULL) {
        if (error_code != NULL) {
            *error_code = ERROR_INVALID_PARAMETER;
        }
        return NULL;
    }
    int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, NULL, 0);
    if (length <= 0) {
        if (error_code != NULL) {
            *error_code = GetLastError();
        }
        return NULL;
    }
    wchar_t *result = (wchar_t *)calloc((size_t)length, sizeof(wchar_t));
    if (result == NULL) {
        if (error_code != NULL) {
            *error_code = ERROR_OUTOFMEMORY;
        }
        return NULL;
    }
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, result, length) <= 0) {
        if (error_code != NULL) {
            *error_code = GetLastError();
        }
        free(result);
        return NULL;
    }
    return result;
}

static int loom_copy_local_blob(
    DATA_BLOB *blob,
    uint8_t **output,
    size_t *output_length,
    uint32_t *error_code,
    int sensitive
) {
    if (output == NULL || output_length == NULL) {
        if (error_code != NULL) {
            *error_code = ERROR_INVALID_PARAMETER;
        }
        return 0;
    }
    uint8_t *copy = (uint8_t *)malloc(blob->cbData == 0 ? 1 : blob->cbData);
    if (copy == NULL) {
        if (error_code != NULL) {
            *error_code = ERROR_OUTOFMEMORY;
        }
        if (sensitive && blob->pbData != NULL) {
            SecureZeroMemory(blob->pbData, blob->cbData);
        }
        LocalFree(blob->pbData);
        return 0;
    }
    if (blob->cbData > 0) {
        memcpy(copy, blob->pbData, blob->cbData);
    }
    if (sensitive && blob->pbData != NULL) {
        SecureZeroMemory(blob->pbData, blob->cbData);
    }
    LocalFree(blob->pbData);
    *output = copy;
    *output_length = blob->cbData;
    if (error_code != NULL) {
        *error_code = ERROR_SUCCESS;
    }
    return 1;
}

int loom_platform_protect_current_user(
    const uint8_t *input,
    size_t input_length,
    uint8_t **output,
    size_t *output_length,
    uint32_t *error_code
) {
    if (input == NULL || input_length == 0 || input_length > MAXDWORD) {
        if (error_code != NULL) {
            *error_code = ERROR_INVALID_PARAMETER;
        }
        return 0;
    }
    DATA_BLOB input_blob = {(DWORD)input_length, (BYTE *)input};
    DATA_BLOB output_blob = {0, NULL};
    if (!CryptProtectData(
        &input_blob,
        L"Loom identity key",
        NULL,
        NULL,
        NULL,
        CRYPTPROTECT_UI_FORBIDDEN,
        &output_blob
    )) {
        if (error_code != NULL) {
            *error_code = GetLastError();
        }
        return 0;
    }
    return loom_copy_local_blob(&output_blob, output, output_length, error_code, 0);
}

int loom_platform_unprotect_current_user(
    const uint8_t *input,
    size_t input_length,
    uint8_t **output,
    size_t *output_length,
    uint32_t *error_code
) {
    if (input == NULL || input_length == 0 || input_length > MAXDWORD) {
        if (error_code != NULL) {
            *error_code = ERROR_INVALID_PARAMETER;
        }
        return 0;
    }
    DATA_BLOB input_blob = {(DWORD)input_length, (BYTE *)input};
    DATA_BLOB output_blob = {0, NULL};
    LPWSTR description = NULL;
    if (!CryptUnprotectData(
        &input_blob,
        &description,
        NULL,
        NULL,
        NULL,
        CRYPTPROTECT_UI_FORBIDDEN,
        &output_blob
    )) {
        if (error_code != NULL) {
            *error_code = GetLastError();
        }
        return 0;
    }
    if (description != NULL) {
        LocalFree(description);
    }
    return loom_copy_local_blob(&output_blob, output, output_length, error_code, 1);
}

static uint32_t loom_set_user_only_acl(const wchar_t *path) {
    HANDLE token = NULL;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
        return GetLastError();
    }

    DWORD token_length = 0;
    (void)GetTokenInformation(token, TokenUser, NULL, 0, &token_length);
    DWORD status = GetLastError();
    if (status != ERROR_INSUFFICIENT_BUFFER || token_length == 0) {
        CloseHandle(token);
        return status;
    }
    TOKEN_USER *token_user = (TOKEN_USER *)malloc(token_length);
    if (token_user == NULL) {
        CloseHandle(token);
        return ERROR_OUTOFMEMORY;
    }
    if (!GetTokenInformation(token, TokenUser, token_user, token_length, &token_length)) {
        status = GetLastError();
        free(token_user);
        CloseHandle(token);
        return status;
    }

    EXPLICIT_ACCESSW access = {0};
    access.grfAccessPermissions = GENERIC_ALL;
    access.grfAccessMode = SET_ACCESS;
    access.grfInheritance = NO_INHERITANCE;
    BuildTrusteeWithSidW(&access.Trustee, token_user->User.Sid);

    PACL acl = NULL;
    status = SetEntriesInAclW(1, &access, NULL, &acl);
    if (status == ERROR_SUCCESS) {
        status = SetNamedSecurityInfoW(
            (LPWSTR)path,
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
            NULL,
            NULL,
            acl,
            NULL
        );
    }
    if (acl != NULL) {
        LocalFree(acl);
    }
    SecureZeroMemory(token_user, token_length);
    free(token_user);
    CloseHandle(token);
    return status;
}

int loom_platform_read_file(
    const char *path_utf8,
    size_t maximum_length,
    uint8_t **output,
    size_t *output_length,
    int *exists,
    uint32_t *error_code
) {
    if (output == NULL || output_length == NULL || exists == NULL) {
        if (error_code != NULL) {
            *error_code = ERROR_INVALID_PARAMETER;
        }
        return 0;
    }
    *output = NULL;
    *output_length = 0;
    *exists = 0;
    wchar_t *path = loom_utf8_to_wide(path_utf8, error_code);
    if (path == NULL) {
        return 0;
    }
    HANDLE file = CreateFileW(
        path,
        GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        NULL
    );
    free(path);
    if (file == INVALID_HANDLE_VALUE) {
        DWORD status = GetLastError();
        if (status == ERROR_FILE_NOT_FOUND || status == ERROR_PATH_NOT_FOUND) {
            if (error_code != NULL) {
                *error_code = ERROR_SUCCESS;
            }
            return 1;
        }
        if (error_code != NULL) {
            *error_code = status;
        }
        return 0;
    }
    *exists = 1;

    LARGE_INTEGER length;
    if (!GetFileSizeEx(file, &length)) {
        DWORD status = GetLastError();
        CloseHandle(file);
        if (error_code != NULL) {
            *error_code = status;
        }
        return 0;
    }
    if (length.QuadPart < 0 || (uint64_t)length.QuadPart > maximum_length ||
        (uint64_t)length.QuadPart > SIZE_MAX) {
        CloseHandle(file);
        if (error_code != NULL) {
            *error_code = ERROR_FILE_TOO_LARGE;
        }
        return 0;
    }

    size_t length_value = (size_t)length.QuadPart;
    uint8_t *buffer = (uint8_t *)malloc(length_value == 0 ? 1 : length_value);
    if (buffer == NULL) {
        CloseHandle(file);
        if (error_code != NULL) {
            *error_code = ERROR_OUTOFMEMORY;
        }
        return 0;
    }
    size_t offset = 0;
    while (offset < length_value) {
        DWORD chunk = (DWORD)((length_value - offset) > MAXDWORD ? MAXDWORD : (length_value - offset));
        DWORD bytes_read = 0;
        if (!ReadFile(file, buffer + offset, chunk, &bytes_read, NULL) || bytes_read == 0) {
            DWORD status = GetLastError();
            SecureZeroMemory(buffer, length_value);
            free(buffer);
            CloseHandle(file);
            if (error_code != NULL) {
                *error_code = status == ERROR_SUCCESS ? ERROR_HANDLE_EOF : status;
            }
            return 0;
        }
        offset += bytes_read;
    }
    CloseHandle(file);
    *output = buffer;
    *output_length = length_value;
    if (error_code != NULL) {
        *error_code = ERROR_SUCCESS;
    }
    return 1;
}

int loom_platform_atomic_replace_user_only(
    const char *path_utf8,
    const uint8_t *contents,
    size_t contents_length,
    uint32_t *error_code
) {
    if (contents == NULL || contents_length == 0) {
        if (error_code != NULL) {
            *error_code = ERROR_INVALID_PARAMETER;
        }
        return 0;
    }
    wchar_t *path = loom_utf8_to_wide(path_utf8, error_code);
    if (path == NULL) {
        return 0;
    }
    size_t path_length = wcslen(path);
    size_t temporary_capacity = path_length + 80;
    wchar_t *temporary = (wchar_t *)calloc(temporary_capacity, sizeof(wchar_t));
    if (temporary == NULL) {
        free(path);
        if (error_code != NULL) {
            *error_code = ERROR_OUTOFMEMORY;
        }
        return 0;
    }
    if (_snwprintf_s(
        temporary,
        temporary_capacity,
        _TRUNCATE,
        L"%ls.tmp.%lu.%lu.%llu",
        path,
        GetCurrentProcessId(),
        GetCurrentThreadId(),
        (unsigned long long)GetTickCount64()
    ) < 0) {
        free(temporary);
        free(path);
        if (error_code != NULL) {
            *error_code = ERROR_BUFFER_OVERFLOW;
        }
        return 0;
    }

    HANDLE file = CreateFileW(
        temporary,
        GENERIC_WRITE | WRITE_DAC | DELETE,
        0,
        NULL,
        CREATE_NEW,
        FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_TEMPORARY,
        NULL
    );
    if (file == INVALID_HANDLE_VALUE) {
        DWORD status = GetLastError();
        free(temporary);
        free(path);
        if (error_code != NULL) {
            *error_code = status;
        }
        return 0;
    }

    size_t offset = 0;
    int write_succeeded = 1;
    DWORD status = ERROR_SUCCESS;
    while (offset < contents_length) {
        DWORD chunk = (DWORD)((contents_length - offset) > MAXDWORD ? MAXDWORD : (contents_length - offset));
        DWORD bytes_written = 0;
        if (!WriteFile(file, contents + offset, chunk, &bytes_written, NULL) || bytes_written == 0) {
            status = GetLastError();
            write_succeeded = 0;
            break;
        }
        offset += bytes_written;
    }
    if (write_succeeded && !FlushFileBuffers(file)) {
        status = GetLastError();
        write_succeeded = 0;
    }
    CloseHandle(file);

    if (write_succeeded) {
        status = loom_set_user_only_acl(temporary);
        write_succeeded = status == ERROR_SUCCESS;
    }
    if (write_succeeded) {
        DWORD attributes = GetFileAttributesW(path);
        if (attributes == INVALID_FILE_ATTRIBUTES && GetLastError() == ERROR_FILE_NOT_FOUND) {
            if (!MoveFileExW(temporary, path, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
                status = GetLastError();
                write_succeeded = 0;
            }
        } else if (!ReplaceFileW(path, temporary, NULL, 0, NULL, NULL)) {
            status = GetLastError();
            write_succeeded = 0;
        }
    }
    if (write_succeeded) {
        status = loom_set_user_only_acl(path);
        write_succeeded = status == ERROR_SUCCESS;
    }
    if (!write_succeeded) {
        (void)DeleteFileW(temporary);
    }
    free(temporary);
    free(path);
    if (error_code != NULL) {
        *error_code = status;
    }
    return write_succeeded;
}

int loom_platform_delete_file(const char *path_utf8, uint32_t *error_code) {
    wchar_t *path = loom_utf8_to_wide(path_utf8, error_code);
    if (path == NULL) {
        return 0;
    }
    int succeeded = DeleteFileW(path) != 0;
    DWORD status = succeeded ? ERROR_SUCCESS : GetLastError();
    if (!succeeded && (status == ERROR_FILE_NOT_FOUND || status == ERROR_PATH_NOT_FOUND)) {
        succeeded = 1;
        status = ERROR_SUCCESS;
    }
    free(path);
    if (error_code != NULL) {
        *error_code = status;
    }
    return succeeded;
}

void loom_platform_free(void *buffer) {
    free(buffer);
}

void loom_platform_secure_free(void *buffer, size_t length) {
    if (buffer != NULL) {
        SecureZeroMemory(buffer, length);
        free(buffer);
    }
}

static char *loom_wide_to_utf8(const wchar_t *value) {
    if (value == NULL) {
        return NULL;
    }
    int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, -1, NULL, 0, NULL, NULL);
    if (length <= 0) {
        return NULL;
    }
    char *result = (char *)calloc((size_t)length, 1);
    if (result == NULL) {
        return NULL;
    }
    if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, -1, result, length, NULL, NULL) <= 0) {
        free(result);
        return NULL;
    }
    return result;
}

static char *loom_wide_to_utf8_bounded(const wchar_t *value, size_t maximum_bytes) {
    if (value == NULL) {
        return NULL;
    }
    int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, -1, NULL, 0, NULL, NULL);
    if (length <= 0 || (size_t)(length - 1) > maximum_bytes) {
        return NULL;
    }
    char *result = (char *)calloc((size_t)length, 1);
    if (result == NULL) {
        return NULL;
    }
    if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, -1, result, length, NULL, NULL) <= 0) {
        free(result);
        return NULL;
    }
    return result;
}

static char *loom_ip_address_to_utf8(INT family, const void *address) {
    if (address == NULL) {
        return NULL;
    }
    wchar_t buffer[INET6_ADDRSTRLEN] = {0};
    if (InetNtopW(family, (PVOID)address, buffer, INET6_ADDRSTRLEN) == NULL) {
        return NULL;
    }
    return loom_wide_to_utf8(buffer);
}

typedef struct loom_dnssd_resolve_context loom_dnssd_resolve_context;

struct loom_dnssd_browser {
    CRITICAL_SECTION lock;
    volatile LONG references;
    volatile LONG cancelled;
    volatile LONG browse_completed;
    volatile LONG64 next_event_sequence;
    DNS_SERVICE_CANCEL browse_cancel;
    loom_dnssd_browser_callback callback;
    void *context;
    loom_context_release_callback release_context;
    uint32_t interface_index;
    wchar_t *query_name;
    loom_dnssd_resolve_context *resolves;
};

struct loom_dnssd_resolve_context {
    loom_dnssd_browser *browser;
    DNS_SERVICE_CANCEL cancel;
    DNS_SERVICE_RESOLVE_REQUEST request;
    wchar_t *query_name;
    uint64_t event_sequence;
    uint32_t ttl_seconds;
    loom_dnssd_resolve_context *next;
};

struct loom_dnssd_advertiser {
    CRITICAL_SECTION lock;
    volatile LONG references;
    DNS_SERVICE_CANCEL register_cancel;
    DNS_SERVICE_REGISTER_REQUEST request;
    PDNS_SERVICE_INSTANCE instance;
    loom_dnssd_advertiser_callback callback;
    void *context;
    loom_context_release_callback release_context;
    int registration_pending;
    int registered;
    int stopping;
};

static void loom_browser_retain(loom_dnssd_browser *browser) {
    (void)InterlockedIncrement(&browser->references);
}

static void loom_browser_destroy(loom_dnssd_browser *browser) {
    if (browser == NULL) {
        return;
    }
    free(browser->query_name);
    if (browser->release_context != NULL) {
        browser->release_context(browser->context);
    }
    DeleteCriticalSection(&browser->lock);
    free(browser);
}

static void loom_browser_release_reference(loom_dnssd_browser *browser) {
    if (InterlockedDecrement(&browser->references) == 0) {
        loom_browser_destroy(browser);
    }
}

static void loom_browser_emit(
    loom_dnssd_browser *browser,
    loom_dnssd_event_kind kind,
    uint32_t status,
    const loom_dnssd_service_result *result
) {
    if (browser->callback != NULL) {
        browser->callback(kind, status, result, browser->context);
    }
}

static void loom_remove_resolve_context(loom_dnssd_resolve_context *resolve) {
    loom_dnssd_browser *browser = resolve->browser;
    EnterCriticalSection(&browser->lock);
    loom_dnssd_resolve_context **cursor = &browser->resolves;
    while (*cursor != NULL) {
        if (*cursor == resolve) {
            *cursor = resolve->next;
            break;
        }
        cursor = &(*cursor)->next;
    }
    LeaveCriticalSection(&browser->lock);
}

static void loom_free_service_result(loom_dnssd_service_result *result) {
    free((void *)result->instance_name_utf8);
    free((void *)result->host_name_utf8);
    free((void *)result->ipv4_address_utf8);
    free((void *)result->ipv6_address_utf8);
    if (result->property_keys_utf8 != NULL) {
        for (size_t index = 0; index < result->property_count; index += 1) {
            free((void *)result->property_keys_utf8[index]);
        }
        free((void *)result->property_keys_utf8);
    }
    if (result->property_values_utf8 != NULL) {
        for (size_t index = 0; index < result->property_count; index += 1) {
            free((void *)result->property_values_utf8[index]);
        }
        free((void *)result->property_values_utf8);
    }
}

static VOID WINAPI loom_dns_resolve_complete(
    DWORD status,
    PVOID query_context,
    PDNS_SERVICE_INSTANCE instance
) {
    loom_dnssd_resolve_context *resolve = (loom_dnssd_resolve_context *)query_context;
    if (resolve == NULL) {
        if (instance != NULL) {
            DnsServiceFreeInstance(instance);
        }
        return;
    }
    loom_dnssd_browser *browser = resolve->browser;
    loom_remove_resolve_context(resolve);

    if (status == ERROR_SUCCESS && instance != NULL && InterlockedCompareExchange(&browser->cancelled, 0, 0) == 0) {
        loom_dnssd_service_result result = {0};
        result.instance_name_utf8 = loom_wide_to_utf8_bounded(instance->pszInstanceName, 1024);
        result.host_name_utf8 = loom_wide_to_utf8_bounded(instance->pszHostName, 1024);
        result.event_sequence = resolve->event_sequence;
        result.port = instance->wPort;
        result.interface_index = instance->dwInterfaceIndex;
        result.ttl_seconds = resolve->ttl_seconds;
        result.ipv4_address_utf8 = loom_ip_address_to_utf8(AF_INET, instance->ip4Address);
        result.ipv6_address_utf8 = loom_ip_address_to_utf8(AF_INET6, instance->ip6Address);

        size_t property_count = instance->dwPropertyCount;
        if (property_count > 256) {
            property_count = 256;
        }
        result.property_count = property_count;
        int properties_valid = 1;
        size_t encoded_property_bytes = 0;
        if (property_count > 0) {
            char **keys = (char **)calloc(property_count, sizeof(char *));
            char **values = (char **)calloc(property_count, sizeof(char *));
            if (keys != NULL && values != NULL) {
                for (size_t index = 0; index < property_count; index += 1) {
                    keys[index] = loom_wide_to_utf8_bounded(instance->keys[index], 254);
                    values[index] = loom_wide_to_utf8_bounded(instance->values[index], 254);
                    if (keys[index] == NULL || values[index] == NULL) {
                        properties_valid = 0;
                        break;
                    }
                    size_t key_length = strlen(keys[index]);
                    size_t value_length = strlen(values[index]);
                    size_t item_length = key_length + 1 + value_length;
                    if (key_length == 0 || strchr(keys[index], '=') != NULL || item_length > 255 ||
                        encoded_property_bytes > 65535 - (item_length + 1)) {
                        properties_valid = 0;
                        break;
                    }
                    encoded_property_bytes += item_length + 1;
                }
                result.property_keys_utf8 = (const char *const *)keys;
                result.property_values_utf8 = (const char *const *)values;
            } else {
                free(keys);
                free(values);
                result.property_count = 0;
                properties_valid = 0;
            }
        }
        if (result.instance_name_utf8 != NULL && properties_valid) {
            loom_browser_emit(browser, LOOM_DNSSD_EVENT_ADDED, ERROR_SUCCESS, &result);
        } else {
            loom_browser_emit(
                browser,
                LOOM_DNSSD_EVENT_FAILED,
                result.instance_name_utf8 == NULL ? ERROR_NO_UNICODE_TRANSLATION : ERROR_INVALID_DATA,
                NULL
            );
        }
        loom_free_service_result(&result);
    } else if (status != ERROR_CANCELLED && InterlockedCompareExchange(&browser->cancelled, 0, 0) == 0) {
        loom_browser_emit(browser, LOOM_DNSSD_EVENT_FAILED, status, NULL);
    }

    if (instance != NULL) {
        DnsServiceFreeInstance(instance);
    }
    free(resolve->query_name);
    free(resolve);
    loom_browser_release_reference(browser);
}

static int loom_start_resolve(
    loom_dnssd_browser *browser,
    const wchar_t *query_name,
    uint32_t ttl_seconds
) {
    loom_dnssd_resolve_context *resolve = (loom_dnssd_resolve_context *)calloc(1, sizeof(*resolve));
    if (resolve == NULL) {
        return 0;
    }
    size_t query_length = wcslen(query_name) + 1;
    resolve->query_name = (wchar_t *)calloc(query_length, sizeof(wchar_t));
    if (resolve->query_name == NULL) {
        free(resolve);
        return 0;
    }
    memcpy(resolve->query_name, query_name, query_length * sizeof(wchar_t));
    resolve->browser = browser;
    resolve->event_sequence = (uint64_t)InterlockedIncrement64(&browser->next_event_sequence);
    resolve->ttl_seconds = ttl_seconds;
    resolve->request.Version = DNS_QUERY_REQUEST_VERSION1;
    resolve->request.InterfaceIndex = browser->interface_index;
    resolve->request.QueryName = resolve->query_name;
    resolve->request.pResolveCompletionCallback = loom_dns_resolve_complete;
    resolve->request.pQueryContext = resolve;

    loom_browser_retain(browser);
    EnterCriticalSection(&browser->lock);
    if (InterlockedCompareExchange(&browser->cancelled, 0, 0) != 0) {
        LeaveCriticalSection(&browser->lock);
        loom_browser_release_reference(browser);
        free(resolve->query_name);
        free(resolve);
        return 0;
    }
    resolve->next = browser->resolves;
    browser->resolves = resolve;
    LeaveCriticalSection(&browser->lock);

    DNS_STATUS status = DnsServiceResolve(&resolve->request, &resolve->cancel);
    if (status != DNS_REQUEST_PENDING) {
        loom_remove_resolve_context(resolve);
        loom_browser_emit(browser, LOOM_DNSSD_EVENT_FAILED, status, NULL);
        loom_browser_release_reference(browser);
        free(resolve->query_name);
        free(resolve);
        return 0;
    }
    return 1;
}

static VOID WINAPI loom_dns_browse_callback(DWORD status, PVOID query_context, PDNS_RECORD records) {
    loom_dnssd_browser *browser = (loom_dnssd_browser *)query_context;
    if (browser == NULL) {
        if (records != NULL) {
            DnsRecordListFree(records, DnsFreeRecordList);
        }
        return;
    }

    if (status == ERROR_SUCCESS && InterlockedCompareExchange(&browser->cancelled, 0, 0) == 0) {
        for (PDNS_RECORD record = records; record != NULL; record = record->pNext) {
            if (record->wType != DNS_TYPE_PTR || record->Data.PTR.pNameHost == NULL) {
                continue;
            }
            if (record->dwTtl == 0) {
                char *instance_name = loom_wide_to_utf8(record->Data.PTR.pNameHost);
                if (instance_name != NULL) {
                    loom_dnssd_service_result result = {0};
                    result.instance_name_utf8 = instance_name;
                    result.event_sequence = (uint64_t)InterlockedIncrement64(&browser->next_event_sequence);
                    result.interface_index = browser->interface_index;
                    loom_browser_emit(browser, LOOM_DNSSD_EVENT_REMOVED, ERROR_SUCCESS, &result);
                    free(instance_name);
                }
            } else {
                (void)loom_start_resolve(browser, record->Data.PTR.pNameHost, record->dwTtl);
            }
        }
    } else if (status == ERROR_CANCELLED) {
        loom_browser_emit(browser, LOOM_DNSSD_EVENT_CANCELLED, status, NULL);
        if (InterlockedExchange(&browser->browse_completed, 1) == 0) {
            loom_browser_release_reference(browser);
        }
    } else {
        loom_browser_emit(browser, LOOM_DNSSD_EVENT_FAILED, status, NULL);
        if (InterlockedExchange(&browser->browse_completed, 1) == 0) {
            loom_browser_release_reference(browser);
        }
    }

    if (records != NULL) {
        DnsRecordListFree(records, DnsFreeRecordList);
    }
}

loom_dnssd_browser *loom_dnssd_browser_start(
    const char *query_name_utf8,
    uint32_t interface_index,
    loom_dnssd_browser_callback callback,
    void *context,
    loom_context_release_callback release_context,
    uint32_t *error_code
) {
    if (query_name_utf8 == NULL || callback == NULL) {
        if (release_context != NULL) {
            release_context(context);
        }
        if (error_code != NULL) {
            *error_code = ERROR_INVALID_PARAMETER;
        }
        return NULL;
    }
    loom_dnssd_browser *browser = (loom_dnssd_browser *)calloc(1, sizeof(*browser));
    if (browser == NULL) {
        if (release_context != NULL) {
            release_context(context);
        }
        if (error_code != NULL) {
            *error_code = ERROR_OUTOFMEMORY;
        }
        return NULL;
    }
    InitializeCriticalSection(&browser->lock);
    browser->references = 2;
    browser->callback = callback;
    browser->context = context;
    browser->release_context = release_context;
    browser->interface_index = interface_index;
    browser->query_name = loom_utf8_to_wide(query_name_utf8, error_code);
    if (browser->query_name == NULL) {
        browser->references = 1;
        loom_browser_release_reference(browser);
        return NULL;
    }

    DNS_SERVICE_BROWSE_REQUEST request = {0};
    request.Version = DNS_QUERY_REQUEST_VERSION1;
    request.InterfaceIndex = interface_index;
    request.QueryName = browser->query_name;
    request.pBrowseCallback = loom_dns_browse_callback;
    request.pQueryContext = browser;
    DNS_STATUS status = DnsServiceBrowse(&request, &browser->browse_cancel);
    if (status != DNS_REQUEST_PENDING) {
        browser->references = 1;
        loom_browser_release_reference(browser);
        if (error_code != NULL) {
            *error_code = status;
        }
        return NULL;
    }
    if (error_code != NULL) {
        *error_code = ERROR_SUCCESS;
    }
    loom_browser_emit(browser, LOOM_DNSSD_EVENT_READY, ERROR_SUCCESS, NULL);
    return browser;
}

void loom_dnssd_browser_cancel(loom_dnssd_browser *browser) {
    if (browser == NULL || InterlockedExchange(&browser->cancelled, 1) != 0) {
        return;
    }
    (void)DnsServiceBrowseCancel(&browser->browse_cancel);
    EnterCriticalSection(&browser->lock);
    for (loom_dnssd_resolve_context *resolve = browser->resolves; resolve != NULL; resolve = resolve->next) {
        (void)DnsServiceResolveCancel(&resolve->cancel);
    }
    LeaveCriticalSection(&browser->lock);
}

void loom_dnssd_browser_release(loom_dnssd_browser *browser) {
    if (browser == NULL) {
        return;
    }
    loom_dnssd_browser_cancel(browser);
    loom_browser_release_reference(browser);
}

static void loom_advertiser_retain(loom_dnssd_advertiser *advertiser) {
    (void)InterlockedIncrement(&advertiser->references);
}

static void loom_advertiser_destroy(loom_dnssd_advertiser *advertiser) {
    if (advertiser->instance != NULL) {
        DnsServiceFreeInstance(advertiser->instance);
    }
    if (advertiser->release_context != NULL) {
        advertiser->release_context(advertiser->context);
    }
    DeleteCriticalSection(&advertiser->lock);
    free(advertiser);
}

static void loom_advertiser_release_reference(loom_dnssd_advertiser *advertiser) {
    if (InterlockedDecrement(&advertiser->references) == 0) {
        loom_advertiser_destroy(advertiser);
    }
}

static VOID WINAPI loom_dns_register_complete(
    DWORD status,
    PVOID query_context,
    PDNS_SERVICE_INSTANCE instance
) {
    loom_dnssd_advertiser *advertiser = (loom_dnssd_advertiser *)query_context;
    if (advertiser == NULL) {
        if (instance != NULL) {
            DnsServiceFreeInstance(instance);
        }
        return;
    }
    int stopping;
    int registration_callback;
    int should_deregister = 0;
    EnterCriticalSection(&advertiser->lock);
    stopping = advertiser->stopping;
    registration_callback = advertiser->registration_pending;
    if (registration_callback) {
        advertiser->registration_pending = 0;
        advertiser->registered = status == ERROR_SUCCESS;
        should_deregister = stopping && advertiser->registered;
    } else {
        advertiser->registered = 0;
    }
    LeaveCriticalSection(&advertiser->lock);

    if (should_deregister) {
        loom_advertiser_retain(advertiser);
        DWORD deregister_status = DnsServiceDeRegister(&advertiser->request, NULL);
        if (deregister_status != DNS_REQUEST_PENDING) {
            if (advertiser->callback != NULL) {
                advertiser->callback(deregister_status, advertiser->context);
            }
            loom_advertiser_release_reference(advertiser);
        }
    } else if (advertiser->callback != NULL) {
        advertiser->callback(status, advertiser->context);
    }
    if (instance != NULL) {
        DnsServiceFreeInstance(instance);
    }
    loom_advertiser_release_reference(advertiser);
}

static wchar_t **loom_convert_string_array(
    size_t count,
    const char *const *values,
    uint32_t *error_code
) {
    if (count == 0) {
        return NULL;
    }
    wchar_t **result = (wchar_t **)calloc(count, sizeof(wchar_t *));
    if (result == NULL) {
        if (error_code != NULL) {
            *error_code = ERROR_OUTOFMEMORY;
        }
        return NULL;
    }
    for (size_t index = 0; index < count; index += 1) {
        result[index] = loom_utf8_to_wide(values[index], error_code);
        if (result[index] == NULL) {
            for (size_t previous = 0; previous < index; previous += 1) {
                free(result[previous]);
            }
            free(result);
            return NULL;
        }
    }
    return result;
}

static void loom_free_wide_array(size_t count, wchar_t **values) {
    if (values == NULL) {
        return;
    }
    for (size_t index = 0; index < count; index += 1) {
        free(values[index]);
    }
    free(values);
}

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
) {
    if (instance_name_utf8 == NULL || port == 0 || callback == NULL || property_count > 256 ||
        (property_count > 0 && (property_keys_utf8 == NULL || property_values_utf8 == NULL))) {
        if (release_context != NULL) {
            release_context(context);
        }
        if (error_code != NULL) {
            *error_code = ERROR_INVALID_PARAMETER;
        }
        return NULL;
    }
    wchar_t *instance_name = loom_utf8_to_wide(instance_name_utf8, error_code);
    if (instance_name == NULL) {
        if (release_context != NULL) {
            release_context(context);
        }
        return NULL;
    }
    wchar_t *host_name = NULL;
    if (host_name_utf8 != NULL && host_name_utf8[0] != '\0') {
        host_name = loom_utf8_to_wide(host_name_utf8, error_code);
    } else {
        DWORD host_length = 0;
        (void)GetComputerNameExW(ComputerNameDnsFullyQualified, NULL, &host_length);
        if (host_length > 0) {
            host_name = (wchar_t *)calloc((size_t)host_length + 1, sizeof(wchar_t));
            if (host_name != NULL && !GetComputerNameExW(ComputerNameDnsFullyQualified, host_name, &host_length)) {
                free(host_name);
                host_name = NULL;
            }
        }
    }
    if (host_name == NULL) {
        free(instance_name);
        if (error_code != NULL && *error_code == ERROR_SUCCESS) {
            *error_code = GetLastError();
        }
        if (release_context != NULL) {
            release_context(context);
        }
        return NULL;
    }

    wchar_t **keys = loom_convert_string_array(property_count, property_keys_utf8, error_code);
    wchar_t **values = loom_convert_string_array(property_count, property_values_utf8, error_code);
    if (property_count > 0 && (keys == NULL || values == NULL)) {
        loom_free_wide_array(property_count, keys);
        loom_free_wide_array(property_count, values);
        free(host_name);
        free(instance_name);
        if (release_context != NULL) {
            release_context(context);
        }
        return NULL;
    }

    PDNS_SERVICE_INSTANCE instance = DnsServiceConstructInstance(
        instance_name,
        host_name,
        NULL,
        NULL,
        port,
        0,
        0,
        (DWORD)property_count,
        (PCWSTR *)keys,
        (PCWSTR *)values
    );
    loom_free_wide_array(property_count, keys);
    loom_free_wide_array(property_count, values);
    free(host_name);
    free(instance_name);
    if (instance == NULL) {
        if (error_code != NULL) {
            *error_code = GetLastError();
        }
        if (release_context != NULL) {
            release_context(context);
        }
        return NULL;
    }

    loom_dnssd_advertiser *advertiser = (loom_dnssd_advertiser *)calloc(1, sizeof(*advertiser));
    if (advertiser == NULL) {
        DnsServiceFreeInstance(instance);
        if (release_context != NULL) {
            release_context(context);
        }
        if (error_code != NULL) {
            *error_code = ERROR_OUTOFMEMORY;
        }
        return NULL;
    }
    InitializeCriticalSection(&advertiser->lock);
    advertiser->references = 2;
    advertiser->instance = instance;
    advertiser->callback = callback;
    advertiser->context = context;
    advertiser->release_context = release_context;
    advertiser->registration_pending = 1;
    advertiser->request.Version = DNS_QUERY_REQUEST_VERSION1;
    advertiser->request.InterfaceIndex = interface_index;
    advertiser->request.pServiceInstance = instance;
    advertiser->request.pRegisterCompletionCallback = loom_dns_register_complete;
    advertiser->request.pQueryContext = advertiser;
    advertiser->request.unicastEnabled = FALSE;

    DWORD status = DnsServiceRegister(&advertiser->request, &advertiser->register_cancel);
    if (status != DNS_REQUEST_PENDING) {
        advertiser->references = 1;
        loom_advertiser_release_reference(advertiser);
        if (error_code != NULL) {
            *error_code = status;
        }
        return NULL;
    }
    if (error_code != NULL) {
        *error_code = ERROR_SUCCESS;
    }
    return advertiser;
}

int loom_dnssd_advertiser_stop(
    loom_dnssd_advertiser *advertiser,
    uint32_t *error_code
) {
    if (advertiser == NULL) {
        if (error_code != NULL) {
            *error_code = ERROR_INVALID_PARAMETER;
        }
        return 0;
    }
    int registration_pending;
    int registered;
    EnterCriticalSection(&advertiser->lock);
    if (advertiser->stopping) {
        LeaveCriticalSection(&advertiser->lock);
        if (error_code != NULL) {
            *error_code = ERROR_SUCCESS;
        }
        return 0;
    }
    advertiser->stopping = 1;
    registration_pending = advertiser->registration_pending;
    registered = advertiser->registered;
    LeaveCriticalSection(&advertiser->lock);

    if (registration_pending) {
        (void)DnsServiceRegisterCancel(&advertiser->register_cancel);
        if (error_code != NULL) {
            *error_code = ERROR_SUCCESS;
        }
        return 1;
    }
    if (registered) {
        loom_advertiser_retain(advertiser);
        DWORD status = DnsServiceDeRegister(&advertiser->request, NULL);
        if (status != DNS_REQUEST_PENDING) {
            loom_advertiser_release_reference(advertiser);
            if (error_code != NULL) {
                *error_code = status;
            }
            return 0;
        }
        if (error_code != NULL) {
            *error_code = ERROR_SUCCESS;
        }
        return 1;
    }
    if (error_code != NULL) {
        *error_code = ERROR_SUCCESS;
    }
    return 0;
}

void loom_dnssd_advertiser_release(loom_dnssd_advertiser *advertiser) {
    if (advertiser == NULL) {
        return;
    }
    uint32_t ignored_error = ERROR_SUCCESS;
    (void)loom_dnssd_advertiser_stop(advertiser, &ignored_error);
    loom_advertiser_release_reference(advertiser);
}

#else

#include <stdlib.h>

struct loom_dnssd_browser { int unused; };
struct loom_dnssd_advertiser { int unused; };

static void loom_set_unsupported(uint32_t *error_code) {
    if (error_code != NULL) {
        *error_code = 50;
    }
}

loom_dnssd_browser *loom_dnssd_browser_start(
    const char *query_name_utf8,
    uint32_t interface_index,
    loom_dnssd_browser_callback callback,
    void *context,
    loom_context_release_callback release_context,
    uint32_t *error_code
) {
    (void)query_name_utf8;
    (void)interface_index;
    (void)callback;
    if (release_context != NULL) {
        release_context(context);
    }
    loom_set_unsupported(error_code);
    return NULL;
}

void loom_dnssd_browser_cancel(loom_dnssd_browser *browser) { (void)browser; }
void loom_dnssd_browser_release(loom_dnssd_browser *browser) { (void)browser; }

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
) {
    (void)instance_name_utf8;
    (void)host_name_utf8;
    (void)port;
    (void)interface_index;
    (void)property_count;
    (void)property_keys_utf8;
    (void)property_values_utf8;
    (void)callback;
    if (release_context != NULL) {
        release_context(context);
    }
    loom_set_unsupported(error_code);
    return NULL;
}

int loom_dnssd_advertiser_stop(loom_dnssd_advertiser *advertiser, uint32_t *error_code) {
    (void)advertiser;
    loom_set_unsupported(error_code);
    return 0;
}
void loom_dnssd_advertiser_release(loom_dnssd_advertiser *advertiser) { (void)advertiser; }

int loom_platform_protect_current_user(
    const uint8_t *input,
    size_t input_length,
    uint8_t **output,
    size_t *output_length,
    uint32_t *error_code
) {
    (void)input;
    (void)input_length;
    (void)output;
    (void)output_length;
    loom_set_unsupported(error_code);
    return 0;
}

int loom_platform_unprotect_current_user(
    const uint8_t *input,
    size_t input_length,
    uint8_t **output,
    size_t *output_length,
    uint32_t *error_code
) {
    (void)input;
    (void)input_length;
    (void)output;
    (void)output_length;
    loom_set_unsupported(error_code);
    return 0;
}

int loom_platform_read_file(
    const char *path_utf8,
    size_t maximum_length,
    uint8_t **output,
    size_t *output_length,
    int *exists,
    uint32_t *error_code
) {
    (void)path_utf8;
    (void)maximum_length;
    (void)output;
    (void)output_length;
    if (exists != NULL) {
        *exists = 0;
    }
    loom_set_unsupported(error_code);
    return 0;
}

int loom_platform_atomic_replace_user_only(
    const char *path_utf8,
    const uint8_t *contents,
    size_t contents_length,
    uint32_t *error_code
) {
    (void)path_utf8;
    (void)contents;
    (void)contents_length;
    loom_set_unsupported(error_code);
    return 0;
}

int loom_platform_delete_file(const char *path_utf8, uint32_t *error_code) {
    (void)path_utf8;
    loom_set_unsupported(error_code);
    return 0;
}

void loom_platform_free(void *buffer) {
    free(buffer);
}

void loom_platform_secure_free(void *buffer, size_t length) {
    if (buffer != NULL) {
        volatile uint8_t *bytes = (volatile uint8_t *)buffer;
        for (size_t index = 0; index < length; index += 1) {
            bytes[index] = 0;
        }
        free(buffer);
    }
}

#endif
