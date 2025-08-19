---
title: I/O Channel Example
type: note
permalink: spdk/examples/i/o-channel-example
---

# I/O Channel Example

Demonstrates thread-safe device access using SPDK's I/O channel pattern.

## Pattern
I/O channels provide thread-local access to devices, eliminating the need for locking. Each thread should have its own channel to a device.

## Code Example

```c
#include "spdk/bdev.h"
#include "spdk/io_channel.h"
#include "spdk/thread.h"

struct device_context {
    struct spdk_bdev_desc *desc;
    struct spdk_io_channel *ch;
    char *device_name;
    bool channel_valid;
};

// Initialize device context and get I/O channel
static int init_device_context(struct device_context *ctx, const char *device_name)
{
    int rc;
    
    ctx->device_name = strdup(device_name);
    if (!ctx->device_name) {
        return -ENOMEM;
    }
    
    // Open device descriptor
    rc = spdk_bdev_open_ext(device_name, true, NULL, NULL, &ctx->desc);
    if (rc != 0) {
        SPDK_ERRLOG("Failed to open device %s: %s\n", device_name, spdk_strerror(-rc));
        free(ctx->device_name);
        return rc;
    }
    
    // Get I/O channel for current thread
    ctx->ch = spdk_bdev_get_io_channel(ctx->desc);
    if (!ctx->ch) {
        SPDK_ERRLOG("Failed to get I/O channel for device %s\n", device_name);
        spdk_bdev_close(ctx->desc);
        free(ctx->device_name);
        return -ENOMEM;
    }
    
    ctx->channel_valid = true;
    SPDK_INFOLOG("bdev", "Initialized device context for %s on thread %p\n",
                 device_name, spdk_get_thread());
    return 0;
}

// Cleanup device context
static void cleanup_device_context(struct device_context *ctx)
{
    if (ctx->channel_valid && ctx->ch) {
        spdk_put_io_channel(ctx->ch);
        ctx->ch = NULL;
        ctx->channel_valid = false;
    }
    
    if (ctx->desc) {
        spdk_bdev_close(ctx->desc);
        ctx->desc = NULL;
    }
    
    free(ctx->device_name);
    ctx->device_name = NULL;
}

// I/O completion callback
static void io_complete(struct spdk_bdev_io *bdev_io, bool success, void *cb_arg)
{
    struct io_request *req = cb_arg;
    
    if (success) {
        SPDK_INFOLOG("bdev", "I/O completed successfully\n");
        req->status = 0;
    } else {
        SPDK_ERRLOG("I/O failed\n");
        req->status = -EIO;
    }
    
    // Always free the I/O request
    spdk_bdev_free_io(bdev_io);
    
    // Signal completion
    req->completed = true;
    if (req->completion_cb) {
        req->completion_cb(req->cb_ctx, req->status);
    }
}

// Perform read operation using I/O channel
static int read_from_device(struct device_context *ctx, void *buffer, 
                           uint64_t offset, uint64_t length,
                           spdk_bdev_io_completion_cb completion_cb, void *cb_ctx)
{
    if (!ctx->channel_valid) {
        SPDK_ERRLOG("I/O channel not valid\n");
        return -EINVAL;
    }
    
    int rc = spdk_bdev_read(ctx->desc, ctx->ch, buffer, offset, length,
                           completion_cb, cb_ctx);
    if (rc != 0) {
        SPDK_ERRLOG("Failed to submit read: %s\n", spdk_strerror(-rc));
        return rc;
    }
    
    return 0;
}

// Multi-threaded device access pattern
struct shared_device {
    char *device_name;
    struct spdk_bdev_desc *desc;
    atomic_int ref_count;
};

struct per_thread_device {
    struct shared_device *shared;
    struct spdk_io_channel *ch;
    struct spdk_thread *thread;
};

// Initialize shared device (called once)
static int init_shared_device(struct shared_device *shared, const char *device_name)
{
    shared->device_name = strdup(device_name);
    atomic_init(&shared->ref_count, 0);
    
    int rc = spdk_bdev_open_ext(device_name, true, NULL, NULL, &shared->desc);
    if (rc != 0) {
        free(shared->device_name);
        return rc;
    }
    
    return 0;
}

// Get per-thread device context
static struct per_thread_device *get_thread_device(struct shared_device *shared)
{
    struct per_thread_device *thread_dev = calloc(1, sizeof(*thread_dev));
    if (!thread_dev) {
        return NULL;
    }
    
    thread_dev->shared = shared;
    thread_dev->thread = spdk_get_thread();
    
    // Get I/O channel for this thread
    thread_dev->ch = spdk_bdev_get_io_channel(shared->desc);
    if (!thread_dev->ch) {
        free(thread_dev);
        return NULL;
    }
    
    atomic_fetch_add(&shared->ref_count, 1);
    return thread_dev;
}

// Release per-thread device context
static void put_thread_device(struct per_thread_device *thread_dev)
{
    if (thread_dev->ch) {
        spdk_put_io_channel(thread_dev->ch);
    }
    
    atomic_fetch_sub(&thread_dev->shared->ref_count, 1);
    free(thread_dev);
}

// Example: I/O channel lifecycle management
struct io_worker {
    struct per_thread_device *device;
    struct spdk_poller *poller;
    bool running;
};

static int worker_poller(void *ctx)
{
    struct io_worker *worker = ctx;
    
    if (!worker->running) {
        return SPDK_POLLER_IDLE;
    }
    
    // Perform I/O operations using worker->device->ch
    bool work_done = perform_io_operations(worker->device);
    
    return work_done ? SPDK_POLLER_BUSY : SPDK_POLLER_IDLE;
}

static int start_io_worker(struct io_worker *worker, struct shared_device *shared)
{
    worker->device = get_thread_device(shared);
    if (!worker->device) {
        return -ENOMEM;
    }
    
    worker->running = true;
    worker->poller = spdk_poller_register(worker_poller, worker, 0);
    if (!worker->poller) {
        put_thread_device(worker->device);
        return -ENOMEM;
    }
    
    return 0;
}

static void stop_io_worker(struct io_worker *worker)
{
    worker->running = false;
    
    if (worker->poller) {
        spdk_poller_unregister(&worker->poller);
    }
    
    if (worker->device) {
        put_thread_device(worker->device);
        worker->device = NULL;
    }
}
```

## I/O Channel Best Practices

```c
// Per-thread pattern - each thread gets its own channel
static __thread struct spdk_io_channel *g_my_channel = NULL;

static struct spdk_io_channel *get_my_channel(struct spdk_bdev_desc *desc)
{
    if (!g_my_channel) {
        g_my_channel = spdk_bdev_get_io_channel(desc);
    }
    return g_my_channel;
}

// Channel cleanup on thread exit
static void cleanup_thread_channels(void)
{
    if (g_my_channel) {
        spdk_put_io_channel(g_my_channel);
        g_my_channel = NULL;
    }
}
```

## Key Points
- One I/O channel per thread - never share channels between threads
- Always pair `spdk_bdev_get_io_channel()` with `spdk_put_io_channel()`
- Channels are reference counted - multiple gets require multiple puts
- Check channel allocation success before using
- Use channels for all I/O operations to the same device
- Channels provide lock-free access to device resources