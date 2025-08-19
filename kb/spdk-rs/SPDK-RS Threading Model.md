---
title: SPDK-RS Threading Model
type: note
permalink: spdk-rs/spdk-rs-threading-model
---

# SPDK-RS Threading Model

SPDK-RS provides safe abstractions over SPDK's reactor-based threading model while preserving the event-driven, non-blocking characteristics essential for high-performance storage applications.

## SPDK Reactor Limitations

**Important**: SPDK-RS provides thread-level and poller-level abstractions that work *within* the SPDK reactor model, but developers must still manually initialize and manage the reactor system using raw SPDK FFI calls.

### What SPDK-RS Provides
- Thread lifecycle management (`Thread`)
- Event-driven polling (`Poller`) 
- CPU core affinity (`Cores`, `CpuMask`)
- Thread-safe context switching

### What Requires Raw SPDK
- Reactor initialization (`spdk_app_start`, `spdk_app_opts`)
- Application framework setup (`spdk_app_parse_args`)
- Environment layer bootstrap

For complete reactor concepts, see [[SPDK Coding Patterns for Development]].

## Thread Abstraction

### `Thread` Wrapper
```rust
// Create thread on specific core
let thread = Thread::new("worker_thread".to_string(), core_id)?;

// Execute closure on thread context
thread.with(|| {
    // SPDK operations here
});

// Send message to thread
thread.send_msg(data, |data| {
    // Process data on target thread
});
```

**Key Features:**
- Safe thread creation and destruction
- Context switching with `CurrentThreadGuard`
- Cross-thread message passing
- Thread identification and naming

### Thread Safety Patterns

**CurrentThreadGuard - RAII Context Switching**
```rust
{
    let _guard = CurrentThreadGuard::new(); // Save current thread
    target_thread.set_current();           // Switch context
    // SPDK operations here
} // Automatically restore previous thread context
```

**Thread Verification**
```rust
assert!(Thread::is_spdk_thread()); // Verify SPDK thread context
let current = Thread::current();   // Get current thread handle
```

## Poller System

SPDK-RS provides a high-level `Poller` abstraction over SPDK's event-driven polling mechanism.

### Basic Poller Usage
```rust
let poller = PollerBuilder::new()
    .with_name("my_poller")
    .with_interval(Duration::from_millis(100))
    .with_data(MyData::default())
    .with_poll_fn(|data| {
        // Poll function - return 0 to continue, 1 to indicate work done
        0
    })
    .build();

// Control poller
poller.pause();
poller.resume();
poller.stop(); // Or just drop(poller)
```

### Cross-Thread Pollers
```rust
let poller = PollerBuilder::new()
    .with_core(target_core)  // Creates dedicated thread
    .with_poll_fn(|_| { /* work */ 0 })
    .build();
```

**Features:**
- Named and unnamed pollers
- Custom polling intervals (microsecond precision)
- Pause/resume/stop control
- Cross-core execution with automatic thread creation
- RAII cleanup with automatic unregistration

## CPU Core Management

### Core Selection
```rust
let current_core = Cores::current();
let total_cores = Cores::count();

// Round-robin core selection
let mut selector = RoundRobinCoreSelector::new();
let next_core = selector.next_core();
```

### CPU Affinity
```rust
let mut mask = CpuMask::new();
mask.set_cpu(core_id, true);
// Used internally by Thread::new()
```

## Event-Driven Constraints

### Non-Blocking Requirements
All operations within SPDK threads must be non-blocking:

```rust
// ❌ WRONG - blocks reactor
thread.with(|| {
    std::thread::sleep(Duration::from_secs(1)); // Blocks entire reactor!
});

// ✅ CORRECT - use poller for delayed work
let poller = PollerBuilder::new()
    .with_interval(Duration::from_secs(1))
    .with_poll_fn(|_| { /* work */ 0 })
    .build();
```

### Thread Context Rules
- SPDK operations must run on SPDK threads
- Use `Thread::with()` or message passing for cross-thread calls
- Verify context with `Thread::is_spdk_thread()`

## Integration with Async/Await

SPDK-RS bridges callback-based SPDK to Rust's async/await:

```rust
// Async wrapper around SPDK callback
pub async fn async_operation(&self) -> Result<(), Error> {
    let (sender, receiver) = oneshot::channel();
    
    // Convert to SPDK callback
    unsafe {
        spdk_async_operation(callback, sender_as_ptr);
    }
    
    receiver.await?
}
```

**Limitations:**
- Futures are driven by the SPDK reactor, not Tokio
- Must maintain SPDK thread context throughout async chains
- Cannot use blocking async operations

## Unaffinitized Threading

For operations outside SPDK's reactor model:

```rust
// Spawn thread with inverse CPU affinity (non-SPDK cores)
let handle = Thread::spawn_unaffinitized(|| {
    // Can use blocking operations here
    // No SPDK context available
});
```

## Best Practices

1. **Minimize Thread Creation** - Use message passing instead of creating many threads
2. **Verify Context** - Always check `Thread::is_spdk_thread()` before SPDK operations  
3. **Use Guards** - Leverage `CurrentThreadGuard` for safe context switching
4. **Non-Blocking Only** - Never block in SPDK thread context
5. **Poller Cleanup** - Ensure pollers are properly stopped/dropped

For practical threading examples, see [[SPDK-RS Integration Patterns]].

For underlying SPDK reactor concepts, see [[SPDK Coding Patterns for Development]].