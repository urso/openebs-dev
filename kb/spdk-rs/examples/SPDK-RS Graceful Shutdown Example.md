---
title: SPDK-RS Graceful Shutdown Example
type: note
permalink: spdk-rs/examples/spdk-rs-graceful-shutdown-example
---

# SPDK-RS Graceful Shutdown Example

Shows proper cleanup patterns for SPDK applications including thread termination, device cleanup, and application shutdown.

## Thread Cleanup
**Source:** `src/thread.rs:64-80`

Cleanly exit worker threads before application shutdown:

```rust
thread.exit();         // Request thread exit
thread.wait_exit();    // Wait for completion
```

## Device Cleanup
**Source:** `src/bdev_desc.rs`

Close device descriptors to stop I/O operations:

```rust
let desc = BdevDesc::open("malloc0", true, event_handler)?;
desc.close();          // Clean descriptor closure
```

## Application Shutdown  
**Source:** `examples/hello_world.rs:25-27` + `src/libspdk/`

Stop the SPDK application with proper exit codes:

```rust
unsafe { spdk_app_stop(0); }  // Success exit
unsafe { spdk_app_fini(); }   // Final cleanup
```