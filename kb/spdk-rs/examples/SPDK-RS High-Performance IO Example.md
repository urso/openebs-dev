# SPDK-RS High-Performance IO Example

Shows high-performance I/O patterns using zero-copy operations, efficient buffer management, and device optimization.

## Device Opening
**Source:** `src/bdev_desc.rs:74-80`

Open block devices with optimal settings for high throughput:

```rust  
let desc = BdevDesc::open("nvme0", true, event_handler)?; // Open for I/O
let bdev = desc.bdev();                                   // Get device handle
```

## Buffer Pre-allocation
**Source:** `src/dma.rs:56-80`

Pre-allocate DMA buffers to avoid runtime allocation overhead:

```rust
let buffer = DmaBuf::new(buffer_size, 4096)?;  // Page-aligned buffer
let pool: Vec<DmaBuf> = (0..count).map(|_| buffer).collect(); // Buffer pool
```

## Zero-Copy Operations
**Source:** `src/bdev.rs:90-100` + `src/dma.rs`

Perform I/O operations without data copying:

```rust
let data = buffer.as_mut_slice();              // Direct buffer access
// Submit I/O using buffer without copying data
```