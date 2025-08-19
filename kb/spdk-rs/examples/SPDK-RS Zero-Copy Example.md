---
title: SPDK-RS Zero-Copy Example
type: note
permalink: spdk-rs/examples/spdk-rs-zero-copy-example
---

# SPDK-RS Zero-Copy Example

Shows basic zero-copy buffer operations using DmaBuf for direct memory access without copying data between user and kernel space.

## DMA Buffer Allocation
**Source:** `src/dma.rs:56-80`

Creates aligned memory buffers suitable for DMA operations:

```rust
let buffer = DmaBuf::new(4096, 4096)?; // 4KB buffer, page-aligned
let data = buffer.as_mut_slice();      // Direct access to buffer memory
```

## Vectored I/O Operations  
**Source:** `src/io_vec.rs`

Combines multiple buffers into scatter-gather lists for efficient batch I/O:

```rust
let buffers = vec![buffer1, buffer2, buffer3];
let io_vecs = buffers.as_io_vecs(); // Convert to I/O vector array
```

## Device-Aligned Buffers
**Source:** `src/bdev.rs:45-100` + `src/dma.rs`

Creates buffers aligned to device requirements:

```rust
let alignment = bdev.alignment() as u64;
let buffer = DmaBuf::new(block_size * 8, alignment)?; // Device-aligned buffer
```