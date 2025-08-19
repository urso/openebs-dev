---
title: Event Framework Example
type: note
permalink: spdk/examples/event-framework-example
---

# Event Framework Example

Demonstrates SPDK's reactor pattern and event-driven programming for cross-core coordination.

## Pattern
SPDK uses events for cross-core communication and coordination. Events are lightweight messages that execute callbacks on specific CPU cores.

## Code Example

```c
#include "spdk/event.h"
#include "spdk/thread.h"
#include "spdk/log.h"

struct cross_core_task {
    int task_id;
    void *data;
    size_t data_size;
    uint32_t target_core;
    uint32_t origin_core;
    void (*completion_cb)(void *ctx, int result);
    void *cb_ctx;
};

// Event handler that processes work on target core
static void process_task_on_core(void *arg1, void *arg2)
{
    struct cross_core_task *task = arg1;
    int status = (int)(uintptr_t)arg2;
    
    SPDK_INFOLOG("event", "Processing task %d on core %u\n", 
                 task->task_id, spdk_env_get_current_core());
    
    // Simulate work processing
    int result = process_work(task->data, task->data_size);
    
    // Send result back to origin core
    struct spdk_event *response_event = spdk_event_allocate(task->origin_core,
                                                           send_result_to_origin,
                                                           task,
                                                           (void *)(uintptr_t)result);
    if (response_event) {
        spdk_event_call(response_event);
    } else {
        SPDK_ERRLOG("Failed to allocate response event\n");
        task->completion_cb(task->cb_ctx, -ENOMEM);
        free(task->data);
        free(task);
    }
}

// Event handler that receives results back on origin core
static void send_result_to_origin(void *arg1, void *arg2)
{
    struct cross_core_task *task = arg1;
    int result = (int)(uintptr_t)arg2;
    
    SPDK_INFOLOG("event", "Task %d completed with result %d\n", 
                 task->task_id, result);
    
    // Call completion callback on original core
    task->completion_cb(task->cb_ctx, result);
    
    // Cleanup
    free(task->data);
    free(task);
}

// Submit task to be processed on specific core
static int submit_task_to_core(int task_id, void *data, size_t size, 
                              uint32_t target_core,
                              void (*completion_cb)(void *ctx, int result),
                              void *cb_ctx)
{
    struct cross_core_task *task = calloc(1, sizeof(*task));
    if (!task) {
        return -ENOMEM;
    }
    
    // Copy data for cross-core access
    task->data = malloc(size);
    if (!task->data) {
        free(task);
        return -ENOMEM;
    }
    memcpy(task->data, data, size);
    
    task->task_id = task_id;
    task->data_size = size;
    task->target_core = target_core;
    task->origin_core = spdk_env_get_current_core();
    task->completion_cb = completion_cb;
    task->cb_ctx = cb_ctx;
    
    // Create and send event to target core
    struct spdk_event *event = spdk_event_allocate(target_core, process_task_on_core,
                                                  task, NULL);
    if (!event) {
        free(task->data);
        free(task);
        return -ENOMEM;
    }
    
    spdk_event_call(event);
    return 0;
}

// Example: Round-robin work distribution
struct work_distributor {
    uint32_t next_core;
    uint32_t core_count;
    uint32_t *available_cores;
};

static void init_work_distributor(struct work_distributor *dist)
{
    dist->core_count = spdk_env_get_core_count();
    dist->available_cores = calloc(dist->core_count, sizeof(uint32_t));
    dist->next_core = 0;
    
    // Get list of available cores
    uint32_t i = 0;
    uint32_t core;
    SPDK_ENV_FOREACH_CORE(core) {
        dist->available_cores[i++] = core;
    }
}

static uint32_t get_next_core(struct work_distributor *dist)
{
    uint32_t core = dist->available_cores[dist->next_core];
    dist->next_core = (dist->next_core + 1) % dist->core_count;
    return core;
}

// Application shutdown coordination using events
struct shutdown_coordinator {
    int pending_shutdowns;
    void (*final_callback)(void);
};

static void component_shutdown_complete(void *arg1, void *arg2)
{
    struct shutdown_coordinator *coord = arg1;
    
    coord->pending_shutdowns--;
    SPDK_INFOLOG("event", "Component shutdown complete, %d remaining\n", 
                 coord->pending_shutdowns);
    
    if (coord->pending_shutdowns == 0) {
        // All components shut down, call final callback
        coord->final_callback();
        free(coord);
    }
}

static void initiate_graceful_shutdown(int component_count, 
                                     void (*final_callback)(void))
{
    struct shutdown_coordinator *coord = calloc(1, sizeof(*coord));
    coord->pending_shutdowns = component_count;
    coord->final_callback = final_callback;
    
    // Send shutdown events to all cores
    uint32_t core;
    SPDK_ENV_FOREACH_CORE(core) {
        struct spdk_event *event = spdk_event_allocate(core, 
                                                      shutdown_component_on_core,
                                                      coord, NULL);
        spdk_event_call(event);
    }
}
```

## Event Patterns

```c
// Basic event creation and execution
struct spdk_event *event = spdk_event_allocate(target_core, handler_func, arg1, arg2);
spdk_event_call(event);

// Event with error handling
if (!event) {
    SPDK_ERRLOG("Failed to allocate event\n");
    return -ENOMEM;
}

// Self-scheduling events (re-execute on same core)
static void recurring_task(void *arg1, void *arg2)
{
    // Do work...
    
    // Schedule next iteration
    struct spdk_event *next = spdk_event_allocate(spdk_env_get_current_core(),
                                                 recurring_task, arg1, arg2);
    if (next) {
        spdk_event_call(next);
    }
}
```

## Key Points
- Events execute on the specified target core
- Keep event handlers lightweight and fast
- Always check event allocation success
- Use events for cross-core coordination, not high-frequency operations
- Events are one-shot - create new events for recurring tasks
- Clean up resources in event handlers, not after `spdk_event_call()`