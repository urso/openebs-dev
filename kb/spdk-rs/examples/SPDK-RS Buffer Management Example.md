---
title: SPDK-RS Buffer Management Example
type: note
permalink: spdk-rs/examples/spdk-rs-buffer-management-example
---

# SPDK-RS Buffer Management Example

Shows DMA-capable memory allocation and management using DmaBuf for high-performance I/O operations.

## DMA Buffer Allocation
**Source:** `src/dma.rs:56-80`

Allocate aligned DMA-capable memory buffers:

```rust
let buffer = DmaBuf::new(4096, 4096)?;     // 4KB buffer, page-aligned
let data = buffer.as_mut_slice();          // Direct memory access
```

## Buffer Lifetime Management
**Source:** `src/dma.rs:24-40`

Automatic memory cleanup using RAII patterns:

```rust
// Buffer automatically freed when dropped
drop(buffer);                              // Explicit cleanup (optional)
```

## I/O Vector Operations
**Source:** `src/io_vec.rs`

Convert buffers to scatter-gather I/O vectors:

```rust
let io_vecs = buffers.as_io_vecs();        // Convert to IoVec array
let vec = IoVec::new(ptr, length);         // Manual IoVec creation
```
