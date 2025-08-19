---
title: SPDK-RS Async IO Example
type: note
permalink: spdk-rs/examples/spdk-rs-async-io-example
---

# SPDK-RS Async IO Example

Shows async patterns that bridge SPDK's callback-based model with Rust's async/await using real async APIs.

## Device Statistics
**Source:** `src/bdev_async.rs:79-80`

Get block device statistics asynchronously:

```rust
let stats = bdev.stats_async().await?;      // Get device stats  
bdev.stats_reset_async().await?;            // Reset statistics
```

## Async Context Operations
**Source:** `src/bdev_async.rs:38-50`

Execute custom operations with async callback context:

```rust
let result = bdev.call_errno_fn_async(|ctx| {
    // Custom async operation using context
}).await?;
```

## Device Management
**Source:** `src/bdev.rs:90-100` + `src/bdev_async.rs:53-76`

Lookup and manage devices asynchronously:

```rust
let bdev = Bdev::lookup_by_name("malloc0")?; // Find device
bdev.unregister_bdev_async().await?;         // Async unregister
```