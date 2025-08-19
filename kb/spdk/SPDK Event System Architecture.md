---
title: SPDK Event System Architecture
type: note
permalink: spdk/spdk-event-system-architecture
---

# SPDK Event System Architecture Research

## Executive Summary

SPDK implements a sophisticated event-driven architecture built around **reactors** that orchestrate three complementary systems:

1. **Events** - Cross-core message passing
2. **Pollers** - Hardware polling and periodic tasks  
3. **Bdev Events** - Device lifecycle notifications

All systems work together in SPDK's shared-nothing, polling-based architecture.

## Core Event System

### 1. Events (Cross-Core Messages)

**Primary APIs** (`include/spdk/event.h`):

```c
// Event function signature
typedef void (*spdk_event_fn)(void *arg1, void *arg2);

// Core event APIs
struct spdk_event *spdk_event_allocate(uint32_t lcore, spdk_event_fn fn, void *arg1, void *arg2);
void spdk_event_call(struct spdk_event *event);
```

**Usage examples**:
```c
// Cross-core message passing: test/event/event_perf/event_perf.c:133-134
event = spdk_event_allocate(next_lcore, submit_new_event, NULL, NULL);
spdk_event_call(event);

// Reactor coordination: lib/event/reactor.c:1045, 1066
ev = spdk_event_allocate(target->lcore, _reactor_set_interrupt_mode, target, NULL);
spdk_event_call(ev);
```

**Implementation details**:
- Events are cross-core message passing mechanism (`lib/event/reactor.c:1045, 1066`)
- Each reactor has lock-free queues for incoming events
- `spdk_event_call()` sends events between CPU cores
- One-time execution, cross-core communication

### 2. Pollers (Hardware Polling)

**APIs** (`include/spdk/thread.h`):

```c
// Poller function signature - returns work status
typedef int (*spdk_poller_fn)(void *ctx);

// Poller registration
struct spdk_poller *spdk_poller_register(spdk_poller_fn fn, void *arg, uint64_t period_microseconds);
struct spdk_poller *spdk_poller_register_named(spdk_poller_fn fn, void *arg, uint64_t period_microseconds, const char *name);
void spdk_poller_unregister(struct spdk_poller **poller);
```

**Usage example** from `app/spdk_dd/spdk_dd.c:1235, 1244`:
```c
// Register pollers for async I/O polling
g_job.input.u.aio.poller = spdk_poller_register(dd_input_poll, NULL, 0);
g_job.output.u.aio.poller = spdk_poller_register(dd_output_poll, NULL, 0);

// Cleanup
spdk_poller_unregister(&g_job.input.u.aio.poller);
```

**Key characteristics**:
- Repeated execution on threads until unregistered
- Replace interrupts with polling (performance optimization)
- Period of 0 = every reactor iteration, >0 = timed execution

### 3. Bdev Event System

**Event types** (`include/spdk/bdev.h:65-69`):
```c
enum spdk_bdev_event_type {
    SPDK_BDEV_EVENT_REMOVE,
    SPDK_BDEV_EVENT_RESIZE,
    SPDK_BDEV_EVENT_MEDIA_MANAGEMENT,
};

typedef void (*spdk_bdev_event_cb_t)(enum spdk_bdev_event_type type, 
                                     struct spdk_bdev *bdev, void *event_ctx);
```

**Core notification API** (`lib/bdev/bdev.c:3710-3741`):
```c
int spdk_bdev_notify_blockcnt_change(struct spdk_bdev *bdev, uint64_t size)
{
    // Updates bdev size and sends SPDK_BDEV_EVENT_RESIZE to all open descriptors
    TAILQ_FOREACH(desc, &bdev->internal.open_descs, link) {
        spdk_thread_send_msg(desc->thread, _resize_notify, desc);
    }
}
```

**Working event handler example** (`lib/nvmf/subsystem.c:1339-1359`):
```c
static void nvmf_ns_event(enum spdk_bdev_event_type type, struct spdk_bdev *bdev, void *event_ctx)
{
    switch (type) {
    case SPDK_BDEV_EVENT_REMOVE:
        nvmf_ns_hot_remove(event_ctx);
        break;
    case SPDK_BDEV_EVENT_RESIZE:
        nvmf_ns_resize(event_ctx);  // Handles resize at nvmf/subsystem.c:1304
        break;
    }
}
```

## Reactor Architecture: The Central Orchestrator

### Reactor Main Loop (`lib/event/reactor.c:928-990`)

**Reactors are the core event loops** - one per CPU core - that orchestrate all systems:

```c
static int reactor_run(void *arg)
{
    struct spdk_reactor *reactor = arg;
    
    SPDK_NOTICELOG("Reactor started on core %u\n", reactor->lcore);
    
    while (1) {
        if (reactor->in_interrupt) {
            reactor_interrupt_run(reactor);  // Interrupt mode
        } else {
            _reactor_run(reactor);           // Polling mode  
        }
    }
}
```

### The Core `_reactor_run()` Function (`lib/event/reactor.c:892-925`)

**This is where events and pollers execute together:**

```c
static void _reactor_run(struct spdk_reactor *reactor)
{
    // 1. PROCESS EVENTS FIRST
    event_queue_run_batch(reactor);  // Process cross-core event messages
    
    // 2. EXECUTE POLLERS ON ALL THREADS  
    TAILQ_FOREACH_SAFE(lw_thread, &reactor->threads, link, tmp) {
        thread = spdk_thread_get_from_ctx(lw_thread);
        rc = spdk_thread_poll(thread, 0, reactor->tsc_last);  // ← POLLERS RUN HERE
        
        // Track busy/idle time based on poller return values
        if (rc == 0) {
            reactor->idle_tsc += now - reactor->tsc_last;     // Idle time
        } else if (rc > 0) {
            reactor->busy_tsc += now - reactor->tsc_last;     // Busy time
        }
        
        // Handle thread rescheduling/cleanup
        reactor_post_process_lw_thread(reactor, lw_thread);
    }
}
```

### Thread Model Architecture

```
┌─────────────────────────────────────┐
│       Reactor (1 per CPU core)     │
│                                     │
│  ┌─────────────────────────────────┐ │
│  │ 1. event_queue_run_batch()     │ │ ← Process cross-core events
│  └─────────────────────────────────┘ │
│  ┌─────────────────────────────────┐ │
│  │ 2. For each SPDK thread:       │ │ ← Execute pollers
│  │    spdk_thread_poll()          │ │   
│  │    - Run active pollers        │ │
│  │    - Run timed pollers         │ │ 
│  └─────────────────────────────────┘ │
│                                     │
│  Thread 1: [Poller A] [Poller B]   │
│  Thread 2: [Poller C] [Poller D]   │
│  Thread N: [Poller X] [Poller Y]   │
└─────────────────────────────────────┘
```

## Key Architectural Points

1. **1 Reactor = 1 POSIX thread = 1 CPU core**
2. **N SPDK threads per reactor** (lightweight, cooperative)  
3. **M Pollers per SPDK thread**
4. **Events processed first** - `event_queue_run_batch()` handles cross-core messages
5. **Pollers executed via threads** - `spdk_thread_poll()` runs all registered pollers
6. **No preemption** - Everything runs to completion in the reactor loop

## Application Framework Integration

### Application Startup

**Example from** `examples/bdev/hello_world/hello_bdev.c:317-347`:
```c
int main(int argc, char **argv)
{
    struct spdk_app_opts opts = {};
    spdk_app_opts_init(&opts, sizeof(opts));
    
    // Start app framework with entry point event
    rc = spdk_app_start(&opts, hello_start, &hello_context);
    
    spdk_app_fini();
    return rc;
}
```

### Event-Driven Application Logic

**Example from** `test/event/event_perf/event_perf.c:51-66`:
```c
// Application event handler
static void submit_new_event(void *arg1, void *arg2)
{
    if (spdk_get_ticks() > g_tsc_end) {
        spdk_app_stop(0);  // Stop application via event
        return;
    }
    
    // Chain more events for performance testing
    event = spdk_event_allocate(next_lcore, submit_new_event, NULL, NULL);
    spdk_event_call(event);
}
```

## Event System Comparison

| System | Purpose | Execution | Examples |
|--------|---------|-----------|----------|
| **Events** | Cross-core messages | One-time | App init, shutdown, work distribution |
| **Pollers** | Hardware polling | Repeated | NVMe completions, network I/O, timers |
| **Bdev Events** | Device lifecycle | Event-driven | Device resize, removal, media events |

## Performance Characteristics

From the documentation (`doc/event.md`):
- **Event-driven model** replaces thread-per-connection approach
- **Message passing** is faster than traditional locking on modern CPUs
- **Lock-free queues** for cross-core communication
- **Polling** replaces interrupts for higher performance
- **Shared-nothing** architecture minimizes synchronization

## Implementation Examples

### Basic Event Usage
```c
// Allocate and send event to specific core
struct spdk_event *evt = spdk_event_allocate(target_core, my_function, arg1, arg2);
spdk_event_call(evt);
```

### Basic Poller Usage  
```c
// Register poller for hardware checking
struct spdk_poller *poller = spdk_poller_register(check_hardware, ctx, 0);

// Cleanup when done
spdk_poller_unregister(&poller);
```

### Bdev Event Handler
```c
static void my_bdev_event_cb(enum spdk_bdev_event_type type, struct spdk_bdev *bdev, void *ctx)
{
    switch (type) {
    case SPDK_BDEV_EVENT_RESIZE:
        handle_device_resize(bdev);
        break;
    case SPDK_BDEV_EVENT_REMOVE:
        handle_device_removal(bdev);
        break;
    }
}
```

## Conclusion

SPDK's event system provides a unified architecture where:

- **Reactors** orchestrate everything on each CPU core
- **Events** enable efficient cross-core communication
- **Pollers** provide high-performance hardware polling
- **Bdev Events** manage device lifecycle changes

All systems work together in a lock-free, shared-nothing architecture optimized for modern multi-core systems and high-performance storage workloads.

## References

- **SPDK Event Framework**: `include/spdk/event.h`, `lib/event/reactor.c`
- **Thread/Poller APIs**: `include/spdk/thread.h`, `lib/thread/thread.c`  
- **Bdev Event System**: `include/spdk/bdev.h:65-99`, `lib/bdev/bdev.c:3710-3741`
- **Reactor Implementation**: `lib/event/reactor.c:892-990`
- **Application Examples**: `examples/bdev/hello_world/hello_bdev.c`, `test/event/event_perf/event_perf.c`
- **Working Protocol Examples**: `lib/nvmf/subsystem.c:1339-1359`, `lib/vhost/vhost_blk.c`
- **Performance Examples**: `test/event/event_perf/event_perf.c`, `app/spdk_dd/spdk_dd.c`