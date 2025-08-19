# SPDK-RS Storage Service Example

Shows storage service patterns using BdevModule for registering custom storage backends and block device implementations.

## Module Registration
**Source:** `src/bdev_module.rs`

Register custom storage modules with SPDK:

```rust
let module = BdevModuleBuilder::new("storage_service")
    .with_module_init::<StorageModule>()
    .register();                           // Register with SPDK subsystem
```

## BdevOps Implementation
**Source:** `src/bdev_ops.rs`

Implement block device operations for custom backend:

```rust
impl BdevOps for StorageService {
    type ChannelData = ();
    fn submit_request(&self, chan: IoChannel, bio: BdevIo) { /* I/O handling */ }
}
```

## Service Lifecycle
**Source:** `src/bdev_module.rs` traits

Handle module initialization and cleanup:

```rust
impl WithModuleInit for StorageModule {
    fn module_init() -> i32 { /* startup logic */ 0 }
}
```