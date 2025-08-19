---
title: SPDK-RS Multi-Threading Example
type: note
permalink: spdk-rs/examples/spdk-rs-multi-threading-example
---

# SPDK-RS Multi-Threading Example

Shows thread creation and management for distributing storage operations across CPU cores using SPDK thread APIs.

## Thread Creation
**Source:** `src/thread.rs:53-62`

Create SPDK threads bound to specific CPU cores:

```rust
let thread = Thread::new("worker".to_string(), core_id)?; // Create on specific core
thread.set_current();                                     // Set as current SPDK thread
```

## Thread Lifecycle
**Source:** `src/thread.rs:64-80`

Manage thread execution and cleanup:

```rust
thread.exit();                        // Request thread exit
thread.wait_exit();                   // Wait for completion
```

## Core Management
**Source:** `src/cpu_cores.rs`

Enumerate and select available CPU cores:

```rust
let core_count = Cores::count();      // Get available core count
let cores: Vec<u32> = (0..core_count).collect(); // List cores
```
