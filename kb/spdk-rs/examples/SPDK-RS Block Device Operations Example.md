# SPDK-RS Block Device Operations Example

Shows basic block device operations including device discovery, opening, querying properties, and I/O channel management.

## Device Discovery
**Source:** `src/bdev.rs:90-100`

Find and lookup block devices by name:

```rust
let bdev = Bdev::lookup_by_name("malloc0")?;    // Find device by name
let device_count = Bdev::get_first()?.count();  // Count all devices
```

## Device Access
**Source:** `src/bdev_desc.rs:63-80`

Open devices for I/O operations with event handling:

```rust
let desc = BdevDesc::open("malloc0", true, event_handler)?; // Open for write
let bdev = desc.bdev();                                     // Get device handle  
```

## Device Properties
**Source:** `src/bdev.rs:45-100`

Query device characteristics and capabilities:

```rust
let block_size = bdev.block_len();           // Block size in bytes
let num_blocks = bdev.num_blocks();          // Total blocks
let alignment = bdev.alignment();            // Buffer alignment requirement
```