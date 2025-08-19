---
title: SPDK Coding Patterns for Development
type: note
permalink: spdk/spdk-coding-patterns-for-development
---

# SPDK Coding Patterns

Essential patterns for writing SPDK code.

## Core Rules
## Core Architectural Principles

SPDK's design is built on these fundamental principles:

1. **No Blocking Operations** - All I/O is asynchronous with callbacks for maximum throughput
2. **Polled Mode** - Uses polling instead of interrupts to eliminate context switches  
3. **User-space** - Runs entirely in user space, bypassing kernel overhead
4. **NUMA Awareness** - Memory allocation considers NUMA topology for performance
5. **Modular Design** - Pluggable modules with standardized interfaces
6. **Constructor-based Registration** - Uses C constructor attributes for automatic registration
7. **DMA-safe Memory** - All I/O memory allocations are DMA-capable
8. **Thread-per-core** - Each CPU core typically runs one SPDK thread
9. **Lockless Data Structures** - Extensive use of lockless queues and rings
10. **Hugepage Support** - Leverages hugepages for better memory performance

## Core Rules
- **Everything is asynchronous** - Use callbacks, never block
- **Memory must be DMA-safe** - Use `spdk_malloc()` for I/O buffers  
- **Thread-per-core** - Each thread owns resources, use messages for communication
- **Function naming:** `spdk_{component}_{action}()` (e.g., `spdk_bdev_read()`)
## Patterns

### 1. Asynchronous Operations
All operations use callbacks. Never block.
```c
typedef void (*completion_cb)(void *ctx, int status);
spdk_bdev_read(desc, ch, buffer, offset, length, completion_cb, ctx);
```
→ **Example:** [[Async Operation Example]]

### 2. Memory Management  
Use SPDK APIs for all I/O buffers.
```c
void *buffer = spdk_malloc(size, 64, NULL, SPDK_ENV_SOCKET_ID_ANY, SPDK_MALLOC_DMA);
spdk_free(buffer);
```
→ **Example:** [[Memory Management Example]]

### 3. Polling
Register pollers to check for work.
```c
static int my_poller(void *ctx) {
    return work_done ? SPDK_POLLER_BUSY : SPDK_POLLER_IDLE;
}
device->poller = spdk_poller_register(my_poller, device, 0);
```
→ **Example:** [[Poller Example]]

### 4. Thread Messages
Send messages between threads instead of sharing data.
```c
spdk_thread_send_msg(target_thread, handle_message, ctx);
```
→ **Example:** [[Thread Message Example]]

### 5. Module Registration
Modules register themselves automatically.
```c
static struct spdk_bdev_module my_module = {
    .name = "my_device",
    .module_init = my_init,
    .module_fini = my_fini,
};
SPDK_BDEV_MODULE_REGISTER(my_device, &my_module)
```
→ **Example:** [[Block Device Module Example]]

### 6. RPC Methods
For configuration and management.
```c
SPDK_RPC_REGISTER("method_name", rpc_handler, SPDK_RPC_RUNTIME)
```
→ **Example:** [[RPC Method Example]]

### 7. I/O Channels
Each thread gets its own channel for lock-free access.
```c
struct spdk_io_channel *ch = spdk_bdev_get_io_channel(desc);
spdk_put_io_channel(ch);
```
→ **Example:** [[IO Channel Example]]

### 8. Error Handling
Use standard errno values and SPDK logging.
```c
if (!param) {
    SPDK_ERRLOG("Invalid parameter\n");
    return -EINVAL;
}
```
→ **Example:** [[Error Handling Example]]

### 9. Event Framework
For cross-core coordination and task scheduling.
```c
struct spdk_event *event = spdk_event_allocate(target_core, handler, arg1, arg2);
spdk_event_call(event);
```
→ **Example:** [[Event Framework Example]]

### 10. State Machines
For complex async workflows with multiple steps.
→ **Example:** [[State Machine Example]]

## Performance Context

These patterns exist to achieve SPDK's performance goals:

- **Asynchronous Operations** - Eliminate blocking to maximize CPU utilization and I/O throughput
- **Memory Management** - DMA-safe allocation avoids kernel memory mapping overhead  
- **Polling** - Eliminates interrupt overhead and provides predictable low latency
- **Thread Messages** - Lock-free communication prevents cache line bouncing
- **Module Registration** - Zero-cost abstraction for pluggable components
- **RPC Methods** - Out-of-band management doesn't affect data path performance
- **I/O Channels** - Thread-local access eliminates locking in hot paths
- **Error Handling** - Fast-path optimization with unlikely branch hints
- **Event Framework** - Efficient cross-core work distribution
- **State Machines** - Structured async flow reduces callback complexity

## Key Headers

| Pattern | Header |
|---------|--------|
| Async I/O | `include/spdk/bdev.h` |
| Memory | `include/spdk/env.h` |
| Threading | `include/spdk/thread.h` |
| Modules | `include/spdk/bdev_module.h` |
| RPC | `include/spdk/rpc.h` |
| Events | `include/spdk/event.h` |
| I/O Channels | `include/spdk/io_channel.h` |
| Logging | `include/spdk/log.h` |

