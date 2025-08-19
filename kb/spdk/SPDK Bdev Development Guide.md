---
title: SPDK Bdev Development Guide
type: note
permalink: spdk/spdk-bdev-development-guide
---

# SPDK Bdev Development Guide

This guide provides comprehensive instructions for implementing custom SPDK bdev modules, including detailed code references, interface definitions, and step-by-step examples.

## Interface Definition

### Core Function Table

Every bdev module must implement the `spdk_bdev_fn_table` interface defined in `include/spdk/bdev_module.h:307-400`:

```c
struct spdk_bdev_fn_table {
    // Required Functions
    int (*destruct)(void *ctx);
    void (*submit_request)(struct spdk_io_channel *ch, struct spdk_bdev_io *);
    bool (*io_type_supported)(void *ctx, enum spdk_bdev_io_type);
    struct spdk_io_channel *(*get_io_channel)(void *ctx);
    
    // Optional Advanced Functions
    int (*dump_info_json)(void *ctx, struct spdk_json_write_ctx *w);
    int (*write_config_json)(void *ctx, struct spdk_json_write_ctx *w);
    int (*get_memory_domains)(void *ctx, struct spdk_memory_domain **domains,
                             int array_size);
    bool (*accel_sequence_supported)(void *ctx, enum spdk_bdev_io_type type);
};
```

## Code References & Examples

### Function Table Implementation Examples

#### 1. **Simple Backend** (Malloc Example)
**Location**: `module/bdev/malloc/bdev_malloc.c:696-704`

```c
static const struct spdk_bdev_fn_table malloc_fn_table = {
    .destruct                 = bdev_malloc_destruct,
    .submit_request          = bdev_malloc_submit_request,
    .io_type_supported       = bdev_malloc_io_type_supported,
    .get_io_channel          = bdev_malloc_get_io_channel,
    .write_config_json       = bdev_malloc_write_json_config,
    .get_memory_domains      = bdev_malloc_get_memory_domains,
    .accel_sequence_supported = bdev_malloc_accel_sequence_supported,
};
```

#### 2. **Filter/Virtual Bdev** (Passthru Example)  
**Location**: `module/bdev/passthru/vbdev_passthru.c:549-557`

```c
static const struct spdk_bdev_fn_table vbdev_passthru_fn_table = {
    .destruct            = vbdev_passthru_destruct,
    .submit_request      = vbdev_passthru_submit_request,
    .io_type_supported   = vbdev_passthru_io_type_supported,
    .get_io_channel      = vbdev_passthru_get_io_channel,
    .dump_info_json      = vbdev_passthru_dump_info_json,
    .write_config_json   = vbdev_passthru_write_config_json,
    .get_memory_domains  = vbdev_passthru_get_memory_domains,
};
```

## Step-by-Step Implementation Guide

### Step 1: Module Structure Setup

Create your module directory following SPDK conventions:
```
module/bdev/[your_module]/
├── Makefile                    # Build configuration
├── bdev_[name].c              # Main implementation  
├── bdev_[name].h              # Public header
└── bdev_[name]_rpc.c          # RPC interface (optional)
```

### Step 2: Define Your Bdev Structure

```c
struct your_bdev {
    struct spdk_bdev      bdev;        // Must be first member
    void                 *your_context; 
    // Add your specific fields...
};
```

**Key Requirements:**
- `struct spdk_bdev` must be the first member
- Initialize all required bdev fields before registration

### Step 3: Implement Required Functions

#### 3.1 **Destruct Function**
**Purpose**: Clean up resources when bdev is unregistered

```c
// Example from module/bdev/malloc/bdev_malloc.c:168-185
static int
bdev_malloc_destruct(void *ctx)
{
    struct malloc_disk *mdisk = ctx;
    
    // Free allocated resources
    spdk_dma_free(mdisk->malloc_buf);
    free(mdisk->malloc_md_buf);
    free(mdisk);
    
    return 0; // Synchronous completion
    // Return 1 for async, then call spdk_bdev_destruct_done()
}
```

#### 3.2 **Submit Request Function** 
**Purpose**: Process I/O operations

```c
// Template based on module/bdev/malloc/bdev_malloc.c:457-510
static void
bdev_your_submit_request(struct spdk_io_channel *ch, struct spdk_bdev_io *bdev_io)
{
    switch (bdev_io->type) {
    case SPDK_BDEV_IO_TYPE_READ:
        your_bdev_read(ch, bdev_io);
        break;
    case SPDK_BDEV_IO_TYPE_WRITE:
        your_bdev_write(ch, bdev_io);
        break;
    case SPDK_BDEV_IO_TYPE_FLUSH:
        // Implement flush logic or complete immediately
        spdk_bdev_io_complete(bdev_io, SPDK_BDEV_IO_STATUS_SUCCESS);
        break;
    default:
        spdk_bdev_io_complete(bdev_io, SPDK_BDEV_IO_STATUS_FAILED);
        break;
    }
}
```

#### 3.3 **I/O Type Supported Function**
**Purpose**: Advertise supported operations

```c
// Example from module/bdev/malloc/bdev_malloc.c:651-664
static bool
bdev_malloc_io_type_supported(void *ctx, enum spdk_bdev_io_type io_type)
{
    switch (io_type) {
    case SPDK_BDEV_IO_TYPE_READ:
    case SPDK_BDEV_IO_TYPE_WRITE:
    case SPDK_BDEV_IO_TYPE_FLUSH:
    case SPDK_BDEV_IO_TYPE_RESET:
    case SPDK_BDEV_IO_TYPE_UNMAP:
    case SPDK_BDEV_IO_TYPE_WRITE_ZEROES:
        return true;
    default:
        return false;
    }
}
```

#### 3.4 **Get I/O Channel Function**
**Purpose**: Create per-thread I/O context

```c
// Example from module/bdev/malloc/bdev_malloc.c:666-671
static struct spdk_io_channel *
bdev_malloc_get_io_channel(void *ctx)
{
    // Return thread-local channel for optimal performance
    return spdk_get_io_channel(&g_malloc_bdev_head);
}
```

### Step 4: Initialize and Register Your Bdev

```c
// Example initialization pattern
static int
your_bdev_create(const char *name, uint64_t size_bytes, uint32_t block_size)
{
    struct your_bdev *bdev;
    int rc;
    
    bdev = calloc(1, sizeof(*bdev));
    if (!bdev) {
        return -ENOMEM;
    }
    
    // Initialize bdev structure (include/spdk/bdev_module.h:425+)
    bdev->bdev.name = strdup(name);
    bdev->bdev.product_name = "Your Product";
    bdev->bdev.blocklen = block_size;
    bdev->bdev.blockcnt = size_bytes / block_size;
    bdev->bdev.fn_table = &your_fn_table;
    bdev->bdev.ctxt = bdev;
    
    // Set capabilities
    bdev->bdev.write_cache = 0;
    bdev->bdev.max_rw_size = SPDK_BDEV_LARGE_BUF_MAX_SIZE / block_size;
    
    // Register with SPDK
    rc = spdk_bdev_register(&bdev->bdev);
    if (rc) {
        free(bdev->bdev.name);
        free(bdev);
        return rc;
    }
    
    return 0;
}
```

## Advanced Features Implementation

### 1. **Metadata Support**
**Code Reference**: `module/bdev/malloc/bdev_malloc.c:707-759`

```c
// Initialize metadata support
bdev->bdev.md_len = metadata_size;
bdev->bdev.md_interleave = false;  // or true for inline metadata
bdev->bdev.dif_type = SPDK_DIF_TYPE1;
bdev->bdev.dif_pi_format = SPDK_DIF_PI_FORMAT_16;
```

### 2. **Memory Domains** 
**Code Reference**: `module/bdev/malloc/bdev_malloc.c:673-694`

```c
static int
bdev_malloc_get_memory_domains(void *ctx, struct spdk_memory_domain **domains, 
                              int array_size)
{
    // Return memory domain for DMA operations
    if (array_size < 1) {
        return -ENOMEM;
    }
    
    domains[0] = g_malloc_memory_domain;
    return 1; // Number of domains returned
}
```

### 3. **Acceleration Sequence Support**
**Code Reference**: `module/bdev/crypto/vbdev_crypto.c:779`

```c
static bool
vbdev_crypto_sequence_supported(void *ctx, enum spdk_bdev_io_type type)
{
    // Return true if this I/O type can use acceleration sequences
    return type == SPDK_BDEV_IO_TYPE_READ || type == SPDK_BDEV_IO_TYPE_WRITE;
}
```

## Module Registration

Every bdev module must register itself using the `SPDK_BDEV_MODULE_REGISTER` macro:

```c
// Example from module/bdev/malloc/bdev_malloc.c:1086-1093
static struct spdk_bdev_module malloc_if = {
    .name = "malloc",
    .module_init = bdev_malloc_initialize,
    .module_fini = bdev_malloc_finish,
    .get_ctx_size = bdev_malloc_get_ctx_size,
    .examine_config = bdev_malloc_examine,
    .config_json = bdev_malloc_config_json
};

SPDK_BDEV_MODULE_REGISTER(malloc, &malloc_if)
```

## Error Handling Patterns

### I/O Completion
```c
// Success
spdk_bdev_io_complete(bdev_io, SPDK_BDEV_IO_STATUS_SUCCESS);

// Failure
spdk_bdev_io_complete(bdev_io, SPDK_BDEV_IO_STATUS_FAILED);

// Specific error codes
spdk_bdev_io_complete_nvme_status(bdev_io, cdw0, sct, sc);
```

### Resource Cleanup
```c
// Always clean up on error paths
if (error_condition) {
    spdk_bdev_unregister(&bdev->bdev, NULL, NULL);
    free(bdev->name);
    free(bdev);
    return error_code;
}
```

## Testing Your Implementation

### 1. **Basic Functionality**
```bash
# Create test bdev
./scripts/rpc.py bdev_your_create test_bdev 1024

# Verify registration  
./scripts/rpc.py bdev_get_bdevs -b test_bdev

# Run basic I/O test
./test/bdev/bdev.sh
```

### 2. **Performance Testing**
```bash
# Use FIO for performance validation
./app/fio/fio_plugin path/to/fio/config
```

### 3. **Error Injection**
Use the error bdev to test failure scenarios:
```bash
./scripts/rpc.py bdev_error_create base_bdev error_bdev
```

## Real-World Examples

### **Physical Backend**: AIO
**Location**: `module/bdev/aio/bdev_aio.c:814-822`
- File-based storage backend
- Linux AIO integration
- Simple but complete implementation

### **Filter Bdev**: Crypto  
**Location**: `module/bdev/crypto/vbdev_crypto.c:772-780`
- Encryption/decryption layer
- Stacks on any base bdev
- Integrates with SPDK accel framework

### **RAID Implementation**: RAID0
**Location**: `module/bdev/raid/raid0.c`
- Multi-bdev composition
- Stripe-based I/O distribution
- Complex initialization and management

## Best Practices

### **Performance Optimization**
1. **Use per-thread I/O channels** - Avoid locking
2. **Minimize memory allocations** in I/O path
3. **Leverage SPDK's memory pools** for frequent allocations
4. **Align to optimal I/O boundaries** when possible

### **Error Handling**
1. **Always complete I/O requests** - Never leave them hanging
2. **Use appropriate error codes** for different failure types  
3. **Clean up resources** in all error paths
4. **Test failure scenarios** thoroughly

### **Integration**
1. **Follow SPDK naming conventions** for consistency
2. **Implement RPC interface** for management
3. **Support hot-plug operations** when applicable
4. **Document configuration options** clearly

## Next Steps

- **[[SPDK Bdev Capability Matrix]]**: Compare your implementation with existing modules
- **Backend Examples**: Study specific implementations for your use case
  - **NVMe Backend**: High-performance NVMe implementation (`module/bdev/nvme/`)
  - **Passthru Template**: Virtual bdev development pattern (`module/bdev/passthru/`)
- **Advanced Topics**: Explore memory domains, acceleration sequences, and performance optimization

---

This guide provides the foundation for implementing high-performance, SPDK-native storage backends. The key to success is understanding the async, polled-mode architecture and leveraging SPDK's zero-copy I/O capabilities.