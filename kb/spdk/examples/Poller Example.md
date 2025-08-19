---
title: Poller Example
type: note
permalink: spdk/examples/poller-example
---

# Poller Example

Shows how to register a poller to periodically check for work and process completions.

## Pattern
SPDK uses pollers instead of interrupts. Register a function that gets called repeatedly to check for completed work.

## Code Example

```c
struct my_device {
    struct spdk_poller *poller;
    struct work_queue *pending_work;
    struct completion_queue *completed_work;
};

static int my_poller(void *ctx)
{
    struct my_device *device = ctx;
    bool work_done = false;
    
    // Check for completed operations
    int completed = check_device_completions(device);
    if (completed > 0) {
        process_completions(device, completed);
        work_done = true;
    }
    
    // Submit pending work if available
    if (has_pending_work(device)) {
        submit_pending_work(device);
        work_done = true;
    }
    
    return work_done ? SPDK_POLLER_BUSY : SPDK_POLLER_IDLE;
}

// Initialize device with poller
struct my_device *device = calloc(1, sizeof(*device));
device->poller = spdk_poller_register(my_poller, device, 0);

// Cleanup when done
spdk_poller_unregister(&device->poller);
```

## Key Points
- Return `SPDK_POLLER_BUSY` when work was done, `SPDK_POLLER_IDLE` when no work
- Use `period_us = 0` for high-frequency polling (every reactor iteration)
- Always unregister pollers during cleanup
- Keep poller functions lightweight and fast