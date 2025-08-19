# SPDK-RS Low-Latency Example

Shows low-latency optimization patterns using dedicated threads, polling, and CPU core pinning for minimal response times.

## Thread Pinning
**Source:** `src/thread.rs:53-62`

Pin threads to specific CPU cores to avoid migration overhead:

```rust
let thread = Thread::new("low_latency".to_string(), core_id)?; // Pin to core
thread.set_current();                                         // Activate thread
```

## Polling Operations
**Source:** `src/poller.rs:35-60`

Use polling instead of blocking for minimal latency:

```rust
let poller = Poller::new(callback);        // Create poller
poller.register();                         // Start polling
```

## Core Management
**Source:** `src/cpu_cores.rs`

Select optimal CPU cores for latency-critical operations:

```rust
let isolated_cores = Cores::isolated();    // Get isolated cores
let core_id = isolated_cores[0];           // Use first isolated core
```