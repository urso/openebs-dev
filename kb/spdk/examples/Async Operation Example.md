---
title: Async Operation Example
type: note
permalink: spdk/examples/async-operation-example
---

# Async Operation Example

Basic asynchronous operation with callback pattern - the foundation of all SPDK I/O.

## Pattern
All SPDK operations that could block take a callback function that is called when the operation completes.

## Code Example

```c
static void operation_complete(void *ctx, int status) {
    struct my_context *my_ctx = ctx;
    
    if (status == 0) {
        printf("Operation succeeded\n");
        my_ctx->success_count++;
    } else {
        SPDK_ERRLOG("Operation failed: %d\n", status);
        my_ctx->error_count++;
    }
    
    // Always clean up resources in callback
    spdk_free(my_ctx->buffer);
    free(my_ctx);
}

// Usage
struct my_context *ctx = malloc(sizeof(*ctx));
ctx->buffer = spdk_malloc(4096, 64, NULL, SPDK_ENV_SOCKET_ID_ANY, SPDK_MALLOC_DMA);
spdk_bdev_read(desc, ch, ctx->buffer, 0, 4096, operation_complete, ctx);
```

## Key Points
- Always handle both success and error cases in callbacks
- Clean up resources in the callback, not after the call
- Pass context through the callback parameter
- Never block or wait for completion