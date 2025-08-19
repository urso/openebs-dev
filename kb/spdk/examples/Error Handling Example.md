---
title: Error Handling Example
type: note
permalink: spdk/examples/error-handling-example
---

# Error Handling Example

Demonstrates SPDK's error handling patterns, logging conventions, and resource cleanup strategies.

## Pattern
SPDK uses standard errno values for return codes, structured logging for diagnostics, and consistent cleanup patterns for resource management.

## Code Example

```c
#include "spdk/log.h"
#include "spdk/util.h"
#include "spdk/likely.h"

// Standard error handling with cleanup
static int initialize_device(const char *device_name, struct device_context **ctx_out)
{
    struct device_context *ctx = NULL;
    int rc = 0;
    
    // Parameter validation
    if (spdk_unlikely(!device_name || !ctx_out)) {
        SPDK_ERRLOG("Invalid parameters: device_name=%p, ctx_out=%p\n", 
                    device_name, ctx_out);
        return -EINVAL;
    }
    
    // Allocation with error handling
    ctx = calloc(1, sizeof(*ctx));
    if (spdk_unlikely(!ctx)) {
        SPDK_ERRLOG("Failed to allocate device context\n");
        return -ENOMEM;
    }
    
    // Resource initialization with cleanup on failure
    ctx->name = strdup(device_name);
    if (spdk_unlikely(!ctx->name)) {
        SPDK_ERRLOG("Failed to duplicate device name '%s'\n", device_name);
        rc = -ENOMEM;
        goto cleanup_ctx;
    }
    
    ctx->buffer = spdk_malloc(BUFFER_SIZE, 64, NULL, SPDK_ENV_SOCKET_ID_ANY, SPDK_MALLOC_DMA);
    if (spdk_unlikely(!ctx->buffer)) {
        SPDK_ERRLOG("Failed to allocate DMA buffer for device '%s'\n", device_name);
        rc = -ENOMEM;
        goto cleanup_name;
    }
    
    // Device initialization
    rc = open_device(device_name, &ctx->handle);
    if (spdk_unlikely(rc != 0)) {
        SPDK_ERRLOG("Failed to open device '%s': %s\n", device_name, spdk_strerror(-rc));
        goto cleanup_buffer;
    }
    
    // I/O channel setup
    ctx->ch = spdk_bdev_get_io_channel(ctx->desc);
    if (spdk_unlikely(!ctx->ch)) {
        SPDK_ERRLOG("Failed to get I/O channel for device '%s'\n", device_name);
        rc = -ENOMEM;
        goto cleanup_device;
    }
    
    SPDK_INFOLOG("device", "Successfully initialized device '%s'\n", device_name);
    *ctx_out = ctx;
    return 0;
    
    // Cleanup cascade - reverse order of initialization
cleanup_device:
    close_device(ctx->handle);
cleanup_buffer:
    spdk_free(ctx->buffer);
cleanup_name:
    free(ctx->name);
cleanup_ctx:
    free(ctx);
    return rc;
}

// Comprehensive error categorization
enum error_category {
    ERROR_INVALID_PARAM,
    ERROR_RESOURCE_EXHAUSTED,
    ERROR_DEVICE_ERROR,
    ERROR_NETWORK_ERROR,
    ERROR_TIMEOUT,
    ERROR_PERMISSION
};

static const char *error_category_to_string(enum error_category cat)
{
    switch (cat) {
    case ERROR_INVALID_PARAM: return "Invalid Parameter";
    case ERROR_RESOURCE_EXHAUSTED: return "Resource Exhausted";
    case ERROR_DEVICE_ERROR: return "Device Error";
    case ERROR_NETWORK_ERROR: return "Network Error";
    case ERROR_TIMEOUT: return "Timeout";
    case ERROR_PERMISSION: return "Permission Denied";
    default: return "Unknown Error";
    }
}

// Structured error reporting
static int report_error(enum error_category category, int errno_val, 
                       const char *context, const char *fmt, ...)
{
    va_list args;
    char buffer[256];
    
    va_start(args, fmt);
    vsnprintf(buffer, sizeof(buffer), fmt, args);
    va_end(args);
    
    SPDK_ERRLOG("[%s] %s: %s (errno: %d - %s)\n",
                error_category_to_string(category),
                context,
                buffer,
                errno_val,
                spdk_strerror(-errno_val));
    
    return errno_val;
}

// Callback error handling pattern
struct async_context {
    void (*completion_cb)(void *ctx, int status);
    void *cb_ctx;
    bool cleanup_needed;
    void *resources[];
};

static void async_operation_complete(struct spdk_bdev_io *bdev_io, bool success, void *cb_arg)
{
    struct async_context *ctx = cb_arg;
    int status = success ? 0 : -EIO;
    
    // Free the bdev I/O first
    spdk_bdev_free_io(bdev_io);
    
    if (spdk_unlikely(!success)) {
        SPDK_ERRLOG("Async operation failed\n");
        status = -EIO;
    } else {
        SPDK_DEBUGLOG("ops", "Async operation completed successfully\n");
    }
    
    // Resource cleanup if needed
    if (ctx->cleanup_needed) {
        for (int i = 0; ctx->resources[i] != NULL; i++) {
            spdk_free(ctx->resources[i]);
        }
    }
    
    // Always call completion callback
    if (spdk_likely(ctx->completion_cb)) {
        ctx->completion_cb(ctx->cb_ctx, status);
    }
    
    free(ctx);
}

// Retry mechanism with exponential backoff
struct retry_context {
    int max_retries;
    int current_retry;
    uint64_t base_delay_us;
    uint64_t max_delay_us;
    void (*operation_fn)(void *ctx);
    void (*completion_cb)(void *ctx, int final_status);
    void *cb_ctx;
    int last_error;
};

static void schedule_retry(struct retry_context *retry_ctx);

static void retry_timer_callback(void *ctx)
{
    struct retry_context *retry_ctx = ctx;
    
    SPDK_DEBUGLOG("retry", "Retry attempt %d/%d\n", 
                  retry_ctx->current_retry + 1, retry_ctx->max_retries);
    
    retry_ctx->operation_fn(retry_ctx);
}

static void handle_operation_failure(struct retry_context *retry_ctx, int error_code)
{
    retry_ctx->last_error = error_code;
    retry_ctx->current_retry++;
    
    if (retry_ctx->current_retry >= retry_ctx->max_retries) {
        SPDK_ERRLOG("Operation failed after %d retries, giving up: %s\n",
                    retry_ctx->max_retries, spdk_strerror(-error_code));
        retry_ctx->completion_cb(retry_ctx->cb_ctx, error_code);
        free(retry_ctx);
        return;
    }
    
    SPDK_WARNLOG("Operation failed (attempt %d/%d), retrying: %s\n",
                 retry_ctx->current_retry, retry_ctx->max_retries,
                 spdk_strerror(-error_code));
    
    schedule_retry(retry_ctx);
}

static void schedule_retry(struct retry_context *retry_ctx)
{
    // Exponential backoff with jitter
    uint64_t delay = retry_ctx->base_delay_us * (1ULL << retry_ctx->current_retry);
    delay = spdk_min(delay, retry_ctx->max_delay_us);
    
    // Add random jitter (±25%)
    uint64_t jitter = delay / 4;
    delay += (rand() % (2 * jitter)) - jitter;
    
    struct spdk_poller *timer = spdk_poller_register(retry_timer_callback, 
                                                    retry_ctx, delay);
    if (!timer) {
        SPDK_ERRLOG("Failed to schedule retry timer\n");
        retry_ctx->completion_cb(retry_ctx->cb_ctx, -ENOMEM);
        free(retry_ctx);
    }
}

// Defensive programming patterns
static int validate_io_request(struct io_request *req)
{
    if (spdk_unlikely(!req)) {
        SPDK_ERRLOG("NULL I/O request\n");
        return -EINVAL;
    }
    
    if (spdk_unlikely(!req->buffer)) {
        SPDK_ERRLOG("I/O request missing buffer\n");
        return -EINVAL;
    }
    
    if (spdk_unlikely(req->length == 0)) {
        SPDK_ERRLOG("I/O request has zero length\n");
        return -EINVAL;
    }
    
    if (spdk_unlikely(req->offset % SECTOR_SIZE != 0)) {
        SPDK_ERRLOG("I/O request offset %lu not sector-aligned\n", req->offset);
        return -EINVAL;
    }
    
    if (spdk_unlikely(req->length % SECTOR_SIZE != 0)) {
        SPDK_ERRLOG("I/O request length %lu not sector-aligned\n", req->length);
        return -EINVAL;
    }
    
    return 0;
}

// Resource leak detection
#ifdef DEBUG
static atomic_int g_allocation_count = 0;
static atomic_int g_channel_count = 0;

#define TRACK_ALLOCATION() atomic_fetch_add(&g_allocation_count, 1)
#define TRACK_FREE() atomic_fetch_sub(&g_allocation_count, 1)
#define TRACK_CHANNEL_GET() atomic_fetch_add(&g_channel_count, 1)
#define TRACK_CHANNEL_PUT() atomic_fetch_sub(&g_channel_count, 1)

static void check_resource_leaks(void)
{
    int allocs = atomic_load(&g_allocation_count);
    int channels = atomic_load(&g_channel_count);
    
    if (allocs != 0) {
        SPDK_ERRLOG("Memory leak detected: %d allocations not freed\n", allocs);
    }
    
    if (channels != 0) {
        SPDK_ERRLOG("Channel leak detected: %d channels not released\n", channels);
    }
}
#else
#define TRACK_ALLOCATION()
#define TRACK_FREE()
#define TRACK_CHANNEL_GET()
#define TRACK_CHANNEL_PUT()
#define check_resource_leaks()
#endif
```

## Logging Patterns

```c
// Use appropriate log levels
SPDK_ERRLOG("Critical errors that prevent operation\n");
SPDK_WARNLOG("Warning conditions that may affect performance\n");  
SPDK_INFOLOG("module", "Informational messages for specific modules\n");
SPDK_DEBUGLOG("module", "Debug information (compiled out in release)\n");

// Log with context
SPDK_ERRLOG("Failed to allocate buffer for device '%s' size %lu: %s\n",
            device_name, size, spdk_strerror(-rc));

// Conditional logging for performance
if (spdk_log_get_level() >= SPDK_LOG_DEBUG) {
    log_detailed_state(context);
}
```

## Key Points
- Use standard errno values (`-EINVAL`, `-ENOMEM`, `-EIO`, etc.)
- Always validate input parameters first
- Implement reverse-order cleanup on failure paths
- Use `spdk_likely()`/`spdk_unlikely()` for performance hints
- Log errors with sufficient context for debugging
- Handle both success and failure in async callbacks
- Implement retry mechanisms for transient failures
- Use defensive programming to catch bugs early