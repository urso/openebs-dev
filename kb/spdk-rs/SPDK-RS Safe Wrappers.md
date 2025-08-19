---
title: SPDK-RS Safe Wrappers
type: note
permalink: spdk-rs/spdk-rs-safe-wrappers
---

# SPDK-RS Safe Wrappers

SPDK-RS provides comprehensive memory safety abstractions over SPDK's performance-critical but unsafe C APIs, enabling safe Rust development without sacrificing storage performance.

## Memory Safety Architecture

SPDK-RS employs multiple layers of safety without runtime overhead:

1. **Type Safety** - Generic wrappers with compile-time guarantees
2. **RAII Patterns** - Automatic resource cleanup and lifecycle management  
3. **Safe Abstractions** - Eliminating common memory errors (use-after-free, double-free)
4. **Controlled Unsafe** - Unsafe operations isolated and carefully managed

## DMA Buffer Management

SPDK's zero-copy I/O requires special memory alignment and management that SPDK-RS makes safe.

### `DmaBuf` - Safe DMA Buffers
```rust
// Create aligned DMA buffer
let buffer = DmaBuf::alloc(size, alignment)?;

// Safe access to underlying memory
let data: &[u8] = buffer.as_slice();
let data_mut: &mut [u8] = buffer.as_mut_slice();

// Automatic cleanup when dropped - no manual spdk_dma_free()
```

**Safety Guarantees:**
- Proper alignment for DMA operations
- Automatic deallocation via `Drop` trait
- Bounds checking on access
- No use-after-free vulnerabilities

### `IoVec` - Vectored I/O Safety
```rust
// Wrap raw iovec for safe manipulation  
let io_vec = IoVec::new(ptr, len)?;

// Safe conversion from various types
let vecs: Vec<IoVec> = data.as_io_vecs();

// Zero-copy operations with safety
```

Links to [[SPDK Memory Operations]] for underlying DMA concepts.

## RAII Resource Management

SPDK-RS uses Rust's ownership system to ensure proper resource cleanup.

### Block Device Descriptors
```rust
{
    let bdev_desc = BdevDesc::open("nvme0n1", BdevDescOpenMode::ReadWrite)?;
    // Use bdev_desc...
} // Automatically calls spdk_bdev_close() here
```

### I/O Channel Management
```rust  
{
    let channel = bdev.get_io_channel()?;
    // Perform I/O operations...
} // Automatically calls spdk_put_io_channel() here
```

### Thread Lifecycle
```rust
{
    let thread = Thread::new("worker", core_id)?;
    // Use thread...
} // Automatically exits and destroys thread here
```

## Controlled Unsafe Operations

For performance-critical operations that require unsafe access, SPDK-RS provides controlled abstractions.

### `UnsafeRef<T>` - Non-Send References
```rust
// Wrap non-Send types for single-thread usage
let unsafe_ref = UnsafeRef::new(non_send_data);

// Access data safely within same thread
unsafe_ref.with(|data| {
    // Work with non-Send data
});
```

### `UnsafeData<T>` - Owned Unsafe Data
```rust
// Wrapper for owned data that isn't Send/Sync
let unsafe_data = UnsafeData::new(complex_structure);

// Safe access patterns
unsafe_data.get_ref(); // Get reference
```

**Use Cases:**
- FFI pointers from SPDK
- Non-thread-safe data structures
- Performance-critical single-threaded operations

## Error Handling Patterns

SPDK-RS provides comprehensive error handling that bridges C errno patterns to Rust's `Result` type.

### `SpdkError` - Unified Error Type
```rust
pub enum SpdkError {
    BdevNotFound,
    BdevUnregisterFailed(String),
    InvalidParameter,
    // ... more variants
}

// Usage
let result: SpdkResult<BdevDesc> = BdevDesc::open("device", mode);
match result {
    Ok(desc) => { /* use descriptor */ },
    Err(SpdkError::BdevNotFound) => { /* handle missing device */ },
    Err(e) => { /* handle other errors */ },
}
```

### Errno Integration
```rust
// Convert SPDK errno results to Rust Results
pub fn errno_result_from_i32<T>(val: T, errno: i32) -> ErrnoResult<T> {
    if errno == 0 {
        Ok(val)
    } else {
        Err(Errno::from_i32(errno))
    }
}

// Async error handling
pub async fn async_operation() -> Result<(), SpdkError> {
    let (sender, receiver) = oneshot::channel();
    
    unsafe {
        let rc = spdk_operation(done_errno_cb, cb_arg(sender));
        if rc != 0 {
            return Err(SpdkError::from_errno(rc));
        }
    }
    
    receiver.await.map_err(|_| SpdkError::Cancelled)?
}
```

## Type Safety with Generics

SPDK-RS uses Rust's type system to prevent common integration errors.

### Generic Block Device Operations
```rust
pub struct Bdev<BdevData>
where
    BdevData: BdevOps,
{
    inner: NonNull<spdk_bdev>,
    _data: PhantomData<BdevData>,
}

// Type ensures correct operations for device type
impl<T: BdevOps> Bdev<T> {
    pub fn submit_io(&self, io: BdevIo<T>) { /* ... */ }
}
```

### Compile-Time Safety Checks
```rust
// This won't compile if MyBdevOps doesn't implement BdevOps
let bdev: Bdev<MyBdevOps> = BdevBuilder::new()
    .with_ops::<MyBdevOps>()
    .build()?;
```

## Zero-Copy Safety

SPDK-RS maintains zero-copy performance while ensuring memory safety.

### Safe Buffer Sharing
```rust
// Share buffer between operations without copying
let buffer = DmaBuf::alloc(4096, 512)?;
let io_vec = buffer.as_io_vec(); // Zero-copy conversion

// Multiple references, single owner
let slice1 = buffer.as_slice();
let slice2 = buffer.as_slice(); // Safe - multiple immutable refs
```

### Lifetime Management
```rust
// Ensure buffer lives longer than I/O operation
pub async fn write_data<'a>(
    bdev: &Bdev<T>, 
    buffer: &'a DmaBuf
) -> Result<(), SpdkError> {
    let io = bdev.write(buffer.as_io_vec(), offset).await?;
    // Compiler ensures buffer isn't dropped before I/O completes
    Ok(())
}
```

## Performance Characteristics

SPDK-RS safety comes with **zero runtime overhead**:

- **Compile-time checks** - No runtime safety validation
- **Zero-cost abstractions** - Wrappers compile away
- **Inlined operations** - Hot paths fully optimized
- **Direct FFI calls** - No additional indirection

### Benchmarking Safety vs Raw SPDK
```rust
// SPDK-RS safe wrapper - same performance as raw SPDK
let buffer = DmaBuf::alloc(size, alignment)?;
bdev.write(buffer.as_io_vec(), offset).await?;

// Raw SPDK equivalent - same generated assembly
let ptr = spdk_dma_malloc(size, alignment, ptr::null_mut());
spdk_bdev_write(desc, channel, ptr, offset, size, callback, ctx);
```

## Common Safety Patterns

### Resource Initialization
```rust
// Safe initialization with validation
pub fn new_resource() -> Result<Resource, SpdkError> {
    let ptr = unsafe { spdk_create_resource() };
    if ptr.is_null() {
        return Err(SpdkError::AllocationFailed);
    }
    Ok(Resource { inner: NonNull::new(ptr).unwrap() })
}
```

### Callback Safety
```rust
// Safe callback argument passing
pub fn with_callback<F, R>(f: F) -> impl Future<Output = R>
where
    F: FnOnce() -> R,
{
    let (sender, receiver) = oneshot::channel();
    
    let callback = Box::new(move |result| {
        let _ = sender.send(f(result));
    });
    
    unsafe {
        spdk_async_call(trampoline::<F, R>, Box::into_raw(callback).cast());
    }
    
    receiver
}
```

## Best Practices

1. **Use RAII Everywhere** - Let Rust manage resource lifetimes
2. **Prefer Safe APIs** - Use wrappers over raw FFI when possible
3. **Validate at Boundaries** - Check SPDK return values at FFI boundary
4. **Isolate Unsafe** - Keep unsafe blocks small and well-documented
5. **Leverage Type System** - Use generics to prevent misuse

For memory architecture details, see [[SPDK Memory Overview]].

For practical safety examples, see [[SPDK-RS Integration Patterns]].