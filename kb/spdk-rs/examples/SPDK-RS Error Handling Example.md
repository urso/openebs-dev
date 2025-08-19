---
title: SPDK-RS Error Handling Example
type: note
permalink: spdk-rs/examples/spdk-rs-error-handling-example
---

# SPDK-RS Error Handling Example

Shows error handling patterns using SPDK-RS error types and proper error recovery strategies.

## SPDK Error Types
**Source:** `src/error.rs`

Handle SPDK-specific errors and results:

```rust
type SpdkResult<T> = Result<T, SpdkError>;     // SPDK operation results
match spdk_operation() { Ok(val) => ..., Err(e) => ... }
```

## Errno Error Handling  
**Source:** `src/ffihelper.rs`

Handle system error codes from SPDK operations:

```rust
type ErrnoResult<T> = Result<T, nix::errno::Errno>;  // System errno results
match result { Err(Errno::EBUSY) => retry(), _ => ... }
```

## DMA Error Handling
**Source:** `src/dma.rs:18-22`

Handle DMA buffer allocation failures:

```rust
match DmaBuf::new(size, align) {
    Err(DmaError::Alloc {}) => fallback_allocation(), // Allocation failed
    Ok(buffer) => use_buffer(buffer),
}
```
