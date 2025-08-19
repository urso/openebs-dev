---
title: Mayastor IO Engine - Reactor System
type: note
permalink: mayastor/io-engine/mayastor-io-engine-reactor-system
---

# Mayastor IO Engine - Reactor System

## Overview
The reactor system in Mayastor's io-engine provides a **hybrid async runtime** that bridges SPDK's callback-based world with Rust futures. It implements custom future execution while maintaining SPDK's single-threaded, non-blocking cooperative scheduling nature.

## Key Architecture Components

### Reactor Structure (`io-engine/src/core/reactor.rs:102`)
```rust
pub struct Reactor {
    /// Vector of SPDK threads allocated by various subsystems
    threads: RefCell<VecDeque<spdk_rs::Thread>>,
    /// Incoming threads scheduled to this core but not polled yet
    incoming: crossbeam::queue::SegQueue<spdk_rs::Thread>,
    /// Logical core this reactor is created on
    lcore: u32,
    /// Cross-core future communication channels
    sx: Sender<Pin<Box<dyn Future<Output = ()> + 'static>>>,
    rx: Receiver<Pin<Box<dyn Future<Output = ()> + 'static>>>,
}
```

**Core Concepts:**
- **One reactor per CPU core** - each reactor manages SPDK threads and Rust futures on its assigned core
- **Cooperative scheduling** - all tasks run non-preemptively, yielding control voluntarily
- **Thread-local queues** - each reactor maintains its own task queue using thread-local storage

### Dual Runtime Architecture

#### 1. SPDK Reactor Runtime (Primary)
- **Purpose**: Handles I/O operations, storage management, low-latency tasks
- **Thread affinity**: Each reactor pinned to specific CPU core
- **Scheduling**: Cooperative, tasks must yield control explicitly
- **Future support**: Custom async-task integration for Rust futures

#### 2. Tokio Runtime (Secondary) (`io-engine/src/core/runtime.rs:53`)
```rust
static RUNTIME: Lazy<Runtime> = Lazy::new(|| {
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .worker_threads(4)
        .max_blocking_threads(6)
        .on_thread_start(Mthread::unaffinitize)  // Unaffinitized threads
        .build()
        .unwrap();
    Runtime { rt }
});
```

- **Purpose**: For blocking operations, external API calls, non-critical tasks
- **Thread affinity**: Unaffinitized - Tokio threads don't run on reactor cores
- **Bridge functions**: `spawn()`, `spawn_blocking()`, `spawn_await()` for cross-runtime communication

## Async Runtime Capabilities

### 1. Future Spawning and Execution
- **Local spawning**: `spawn_local()` (`io-engine/src/core/reactor.rs:337`) spawns futures on the current reactor
- **Cross-core communication**: `send_future()` (`io-engine/src/core/reactor.rs:328`) sends futures between cores
- **Uses async-task crate**: Custom scheduler with `async_task::spawn_local()` for task management
- **Thread-local scheduling**: Uses crossbeam channels and thread-local queues

### 2. SPDK Integration
- **SPDK thread management**: Reactors manage SPDK threads (`spdk_rs::Thread`) alongside Rust futures
- **Message passing**: Uses SPDK's lockless queues for inter-core communication
- **Callback integration**: `spawn_at()` (`io-engine/src/core/reactor.rs:561`) converts SPDK callbacks to futures

### 3. Health Monitoring (`io-engine/src/core/reactor.rs:684`)
- **Heartbeat system**: Monitors reactor health with timeout detection
- **Freeze detection**: Identifies stuck reactors that aren't processing heartbeats
- **Event generation**: Emits freeze/unfreeze events for monitoring

## Execution Patterns & Code Examples

### 1. **spawn_local()** - Execute Future on Current Reactor
```rust
// Execute async work on current reactor
self.spawn_local(async move {
    // async work here
}).detach();
```
*Source: `io-engine/src/core/reactor.rs:323`*

### 2. **send_future()** - Cross-Core Future Communication
```rust
// Send future to current reactor's core
Reactors::current().send_future(async move {
    let result = copier.copy_segment(blk, &mut task).await;
    // handle result
});

// Send to master core for management operations
Reactors::master().send_future(fut);
```
*Sources: `io-engine/src/rebuild/rebuild_task.rs:164`, `io-engine/src/jsonrpc.rs:216`*

### 3. **block_on()** - Block Until Future Completes (Testing Only)
```rust
// WARNING: For testing only, can leave messages behind
Reactor::block_on(async move {
    let errors = self.create_pools().await;
    // handle errors
});
```
*Source: `io-engine/src/subsys/config/pool.rs:138`*

### 4. **SPDK Callback Pattern** - Traditional C Callbacks
```rust
// Traditional SPDK callback for I/O completion
extern "C" fn io_completion_cb(io: *mut spdk_bdev_io, success: bool, arg: *mut c_void) {
    let sender = unsafe { Box::from_raw(arg as *mut oneshot::Sender<NvmeStatus>) };
    unsafe { spdk_bdev_free_io(io); }
    
    let status = if success { NvmeStatus::SUCCESS } else { NvmeStatus::from(io) };
    sender.send(status).expect("io completion error");
}
```
*Source: `io-engine/src/core/handle.rs:83`*

### 5. **spawn_at()** - Bridge Callbacks to Futures
```rust
// Internal trampoline that converts SPDK callbacks to futures
extern "C" fn trampoline<F>(arg: *mut c_void) {
    let mut ctx = unsafe { Box::from_raw(arg as *mut Ctx<F>) };
    Reactors::current()
        .spawn_local(async move {
            let result = ctx.future.await;
            ctx.sender.send(result).ok();
        })
        .detach();
}
```
*Source: `io-engine/src/core/reactor.rs:577-596`*

## Reactor States (`io-engine/src/core/reactor.rs:66`)

```rust
pub enum ReactorState {
    Init,      // Reactor initializing
    Running,   // Normal operation, polling for work
    Shutdown,  // Graceful shutdown in progress
    Delayed,   // Development mode with 1ms delays
}
```

## Key Questions & Answers

### Does the reactor provide a Rust async runtime?
**Yes, but limited**: The reactor system provides:
- ✅ **Future spawning and execution** with `spawn_local()`
- ✅ **Async/await support** within the reactor context
- ✅ **Cross-core future communication** via channels
- ❌ **No traditional executor**: Uses custom scheduling, not tokio/async-std

### Do we still need callbacks?
**Mixed approach**:
- **Rust futures**: Preferred for new code and cross-core operations
- **SPDK callbacks**: Still used for low-level I/O completion and SPDK integration
- **Bridge functions**: `spawn_at()` converts between callback and future worlds

### Usage Guidelines
1. **Use `spawn_local()`** for async work on current reactor
2. **Use `send_future()`** for cross-core communication
3. **Use `spawn_at()`** to bridge SPDK callbacks to futures
4. **Avoid `block_on()`** in production (testing only)
5. **Master core** handles management operations, gRPC calls
6. **Worker cores** handle I/O operations

## Source Code Locations
- **Reactor implementation**: `io-engine/src/core/reactor.rs`
- **Runtime bridge**: `io-engine/src/core/runtime.rs`
- **Core module exports**: `io-engine/src/core/mod.rs`
- **Example usage**: `io-engine/src/rebuild/rebuild_task.rs`, `io-engine/src/jsonrpc.rs`