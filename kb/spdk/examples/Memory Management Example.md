---
title: Memory Management Example
type: note
permalink: spdk/examples/memory-management-example
---

# Memory Management Example

Demonstrates SPDK's DMA-safe memory allocation, NUMA awareness, and hugepage integration.

## Pattern
SPDK requires DMA-capable memory for all I/O operations. Use SPDK's memory APIs to ensure proper alignment, NUMA locality, and hugepage backing.

## Code Example

```c
#include "spdk/env.h"
#include "spdk/log.h"

struct io_context {
    void *read_buffer;
    void *write_buffer;
    size_t buffer_size;
    int numa_node;
};

static int allocate_io_buffers(struct io_context *ctx, size_t size)
{
    // Get current NUMA node for optimal memory locality
    ctx->numa_node = spdk_env_get_current_core();
    if (ctx->numa_node < 0) {
        ctx->numa_node = SPDK_ENV_SOCKET_ID_ANY;
    }
    
    // Allocate DMA-safe read buffer with 64-byte alignment
    ctx->read_buffer = spdk_malloc(size, 64, NULL, ctx->numa_node, SPDK_MALLOC_DMA);
    if (!ctx->read_buffer) {
        SPDK_ERRLOG("Failed to allocate read buffer of size %zu\n", size);
        return -ENOMEM;
    }
    
    // Allocate and zero-initialize write buffer
    ctx->write_buffer = spdk_zmalloc(size, 64, NULL, ctx->numa_node, SPDK_MALLOC_DMA);
    if (!ctx->write_buffer) {
        SPDK_ERRLOG("Failed to allocate write buffer of size %zu\n", size);
        spdk_free(ctx->read_buffer);
        ctx->read_buffer = NULL;
        return -ENOMEM;
    }
    
    ctx->buffer_size = size;
    
    SPDK_INFOLOG("memory", "Allocated %zu byte I/O buffers on NUMA node %d\n", 
                 size, ctx->numa_node);
    return 0;
}

static void free_io_buffers(struct io_context *ctx)
{
    if (ctx->read_buffer) {
        spdk_free(ctx->read_buffer);
        ctx->read_buffer = NULL;
    }
    
    if (ctx->write_buffer) {
        spdk_free(ctx->write_buffer);
        ctx->write_buffer = NULL;
    }
    
    ctx->buffer_size = 0;
}

static int resize_buffer(void **buffer, size_t old_size, size_t new_size, int numa_node)
{
    // SPDK doesn't have realloc, so manually copy data
    void *new_buffer = spdk_malloc(new_size, 64, NULL, numa_node, SPDK_MALLOC_DMA);
    if (!new_buffer) {
        return -ENOMEM;
    }
    
    if (*buffer && old_size > 0) {
        // Copy existing data
        size_t copy_size = old_size < new_size ? old_size : new_size;
        memcpy(new_buffer, *buffer, copy_size);
        spdk_free(*buffer);
    }
    
    *buffer = new_buffer;
    return 0;
}

// Example: NUMA-aware allocation for multi-socket systems
static void *allocate_per_socket_buffers(size_t size_per_socket)
{
    struct per_socket_buffers {
        void **buffers;
        int socket_count;
    } *multi_buffers;
    
    int socket_count = spdk_env_get_socket_count();
    
    multi_buffers = calloc(1, sizeof(*multi_buffers));
    multi_buffers->socket_count = socket_count;
    multi_buffers->buffers = calloc(socket_count, sizeof(void*));
    
    // Allocate buffer on each NUMA socket
    for (int i = 0; i < socket_count; i++) {
        multi_buffers->buffers[i] = spdk_malloc(size_per_socket, 64, NULL, i, SPDK_MALLOC_DMA);
        if (!multi_buffers->buffers[i]) {
            SPDK_ERRLOG("Failed to allocate buffer on socket %d\n", i);
            // Cleanup on failure
            for (int j = 0; j < i; j++) {
                spdk_free(multi_buffers->buffers[j]);
            }
            free(multi_buffers->buffers);
            free(multi_buffers);
            return NULL;
        }
    }
    
    return multi_buffers;
}

// Get optimal buffer for current thread's NUMA node
static void *get_local_buffer(struct per_socket_buffers *multi_buffers)
{
    int current_socket = spdk_env_get_current_core();
    if (current_socket < 0 || current_socket >= multi_buffers->socket_count) {
        current_socket = 0; // Fallback to first socket
    }
    
    return multi_buffers->buffers[current_socket];
}
```

## Memory Flags

```c
// Common allocation patterns
void *dma_buffer = spdk_malloc(size, 64, NULL, SPDK_ENV_SOCKET_ID_ANY, SPDK_MALLOC_DMA);
void *shared_mem = spdk_malloc(size, 4096, NULL, socket_id, SPDK_MALLOC_DMA | SPDK_MALLOC_SHARE);
void *zero_buffer = spdk_zmalloc(size, 64, NULL, socket_id, SPDK_MALLOC_DMA);
```

## Key Points
- Always use `SPDK_MALLOC_DMA` flag for I/O buffers
- Use 64-byte alignment for optimal performance
- Consider NUMA locality for better performance
- Use `spdk_zmalloc()` when you need zero-initialized memory
- No `spdk_realloc()` - implement manual copy when needed
- Always check allocation success and handle cleanup properly