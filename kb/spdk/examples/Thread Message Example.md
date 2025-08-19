---
title: Thread Message Example
type: note
permalink: spdk/examples/thread-message-example
---

# Thread Message Example

Demonstrates cross-thread communication using SPDK's message passing system.

## Pattern
Instead of sharing data between threads, send messages to request work on the owning thread.

## Code Example

```c
struct cross_thread_msg {
    struct my_device *device;
    int operation_type;
    int result;
    struct spdk_thread *orig_thread;
};

static void send_response(void *ctx)
{
    struct cross_thread_msg *msg = ctx;
    
    // Process response on original thread
    printf("Operation result: %d\n", msg->result);
    free(msg);
}

static void handle_cross_thread_request(void *ctx)
{
    struct cross_thread_msg *msg = ctx;
    
    // Process request on the device's owning thread
    int result = process_request(msg->device, msg->operation_type);
    
    // Send response back to originating thread
    msg->result = result;
    spdk_thread_send_msg(msg->orig_thread, send_response, msg);
}

// Send request to device thread
static void send_request_to_device_thread(struct my_device *device, int op_type)
{
    struct cross_thread_msg *msg = calloc(1, sizeof(*msg));
    msg->device = device;
    msg->operation_type = op_type;
    msg->orig_thread = spdk_get_thread();
    
    spdk_thread_send_msg(device->thread, handle_cross_thread_request, msg);
}
```

## Key Points
- Each device/resource is owned by one thread
- Use messages to request work on the owning thread
- Always send responses back to the originating thread
- Never share mutable data between threads