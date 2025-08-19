---
title: SPDK-RS Custom Bdev Module Example
type: note
permalink: spdk-rs/examples/spdk-rs-custom-bdev-module-example
---

# SPDK-RS Custom Bdev Module Example

Shows how to create custom block device modules using BdevModule builder pattern and BdevOps trait implementation.

## Module Registration
**Source:** `src/bdev_module.rs`

Register a new block device module with SPDK:

```rust
let module = BdevModuleBuilder::new("memory")
    .with_module_init::<MemoryModule>()
    .register(); // Register with SPDK
```

## BdevOps Implementation  
**Source:** `src/bdev_ops.rs`

Implement the BdevOps trait for handling I/O requests:

```rust
impl BdevOps for MemoryBdevOps {
    type ChannelData = ();
    fn destruct(self: Pin<&mut Self>) { /* cleanup */ }
}
```

## Module Lifecycle
**Source:** `src/bdev_module.rs` traits

Handle module initialization and cleanup:

```rust
impl WithModuleInit for MemoryModule {
    fn module_init() -> i32 { 0 } // Success
}
```