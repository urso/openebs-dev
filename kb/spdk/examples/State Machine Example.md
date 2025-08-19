---
title: State Machine Example
type: note
permalink: spdk/examples/state-machine-example
---

# Async State Machine Example

Complex asynchronous workflow using explicit state machine pattern for multiple dependent operations.

## Pattern
For complex async flows with multiple steps, use explicit state machines to manage the sequence and error handling.

## Code Example

```c
enum operation_state {
    OP_INIT,
    OP_READ_COMPLETE,
    OP_PROCESS_COMPLETE,
    OP_WRITE_COMPLETE,
    OP_DONE
};

struct async_operation {
    enum operation_state state;
    void *buffer;
    struct spdk_bdev_desc *desc;
    struct spdk_io_channel *ch;
    void (*completion_cb)(void *ctx, int status);
    void *cb_ctx;
    int error_code;
};

static void state_machine_continue(struct async_operation *op, int status);

static void read_complete(struct spdk_bdev_io *bdev_io, bool success, void *cb_arg)
{
    struct async_operation *op = cb_arg;
    spdk_bdev_free_io(bdev_io);
    
    op->state = OP_READ_COMPLETE;
    op->error_code = success ? 0 : -EIO;
    state_machine_continue(op, op->error_code);
}

static void write_complete(struct spdk_bdev_io *bdev_io, bool success, void *cb_arg)
{
    struct async_operation *op = cb_arg;
    spdk_bdev_free_io(bdev_io);
    
    op->state = OP_WRITE_COMPLETE;
    op->error_code = success ? 0 : -EIO;
    state_machine_continue(op, op->error_code);
}

static void process_complete(void *ctx)
{
    struct async_operation *op = ctx;
    
    op->state = OP_PROCESS_COMPLETE;
    state_machine_continue(op, 0);
}

static void state_machine_continue(struct async_operation *op, int status)
{
    switch (op->state) {
    case OP_INIT:
        // Start with read operation
        spdk_bdev_read(op->desc, op->ch, op->buffer, 0, 4096, read_complete, op);
        break;
        
    case OP_READ_COMPLETE:
        if (status != 0) {
            // Error: complete operation
            op->completion_cb(op->cb_ctx, status);
            spdk_free(op->buffer);
            free(op);
            return;
        }
        // Process data asynchronously
        spdk_thread_send_msg_nowait(process_complete, op);
        break;
        
    case OP_PROCESS_COMPLETE:
        // Write processed data back
        spdk_bdev_write(op->desc, op->ch, op->buffer, 4096, 4096, write_complete, op);
        break;
        
    case OP_WRITE_COMPLETE:
        // Operation complete - success or failure
        op->completion_cb(op->cb_ctx, status);
        spdk_free(op->buffer);
        free(op);
        break;
        
    default:
        assert(false);
        break;
    }
}

// Initialize and start the state machine
struct async_operation *op = calloc(1, sizeof(*op));
op->state = OP_INIT;
op->buffer = spdk_malloc(8192, 64, NULL, SPDK_ENV_SOCKET_ID_ANY, SPDK_MALLOC_DMA);
op->desc = desc;
op->ch = ch;
op->completion_cb = final_callback;
op->cb_ctx = final_ctx;

state_machine_continue(op, 0);
```

## Key Points
- Use explicit state enums for clarity
- Handle errors at each state transition
- Clean up resources only at final states
- Use `state_machine_continue()` as the central dispatcher
- Document state transitions and error paths