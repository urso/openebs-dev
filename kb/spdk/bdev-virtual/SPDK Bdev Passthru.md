---
title: SPDK Bdev Passthru
type: note
permalink: spdk/bdev-virtual/spdk-bdev-passthru
---

# SPDK Bdev Passthru - Virtual Bdev Template

The Passthru bdev is SPDK's template and reference implementation for creating virtual (filter) bdevs. It demonstrates how to stack on top of existing bdevs while maintaining full feature compatibility.

## Architecture Overview

Passthru creates a 1:1 mapping with a base bdev, forwarding all operations while providing hooks for custom functionality:

```
Application
    ↓
Passthru Bdev (vbdev_passthru)
    ↓ (forwards all I/O)  
Base Bdev (any backend)
    ↓
Physical Storage
```

**Key Concept**: Passthru inherits ALL capabilities from its base bdev, making it the perfect template for filter bdevs.

## Code References

### Core Implementation
- **Main Module**: `module/bdev/passthru/vbdev_passthru.c`
- **Header**: `module/bdev/passthru/vbdev_passthru.h`
- **RPC Interface**: `module/bdev/passthru/vbdev_passthru_rpc.c`
- **Build Config**: `module/bdev/passthru/Makefile`

### Function Table Implementation
**Location**: `module/bdev/passthru/vbdev_passthru.c:549-557`
```c
static const struct spdk_bdev_fn_table vbdev_passthru_fn_table = {
    .destruct           = vbdev_passthru_destruct,
    .submit_request     = vbdev_passthru_submit_request,
    .io_type_supported  = vbdev_passthru_io_type_supported,
    .get_io_channel     = vbdev_passthru_get_io_channel,
    .dump_info_json     = vbdev_passthru_dump_info_json,
    .write_config_json  = vbdev_passthru_write_config_json,
    .get_memory_domains = vbdev_passthru_get_memory_domains,
};
```

### Key Function Implementations

#### **I/O Type Support** (Line 541-547)
```c
static bool
vbdev_passthru_io_type_supported(void *ctx, enum spdk_bdev_io_type io_type)
{
    struct vbdev_passthru *pt_node = (struct vbdev_passthru *)ctx;
    
    // Forward capability query to base bdev
    return spdk_bdev_io_type_supported(pt_node->base_bdev, io_type);
}
```

#### **I/O Submission** (Line 194-232)
```c
static void
vbdev_passthru_submit_request(struct spdk_io_channel *ch, struct spdk_bdev_io *bdev_io)
{
    struct vbdev_passthru *pt_node = SPDK_CONTAINEROF(bdev_io->bdev, 
                                                     struct vbdev_passthru, pt_bdev);
    struct pt_io_channel *pt_ch = spdk_io_channel_get_ctx(ch);
    
    // Example of where custom logic can be added
    switch (bdev_io->type) {
    case SPDK_BDEV_IO_TYPE_READ:
        // Could add read-specific processing here
        break;
    case SPDK_BDEV_IO_TYPE_WRITE:
        // Could add write-specific processing here  
        break;
    default:
        break;
    }
    
    // Forward I/O to base bdev
    spdk_bdev_io_resubmit(bdev_io, pt_ch->base_ch);
}
```

## Supported Features

### 🔄 **Inherited from Base Bdev**
All features are passed through to the underlying bdev:
- **I/O Operations**: All types supported by base bdev
- **Metadata**: DIF/DIX support inherited
- **Zoned Storage**: ZNS features inherited  
- **Memory Domains**: Device memory requirements inherited
- **Hot-plug**: Dynamic reconfiguration inherited

### ✅ **Native Virtual Bdev Features**
- **JSON Configuration**: Persistent configuration support
- **Runtime Management**: Create/destroy via RPC
- **Information Reporting**: Custom status and statistics
- **Base Bdev Tracking**: Automatic cleanup on base removal

## Configuration Examples

### **Basic Passthru Creation**
```bash
# Create passthru on existing bdev
./scripts/rpc.py bdev_passthru_create -b nvme0n1 -p pt_nvme0n1

# Verify creation
./scripts/rpc.py bdev_get_bdevs -b pt_nvme0n1
```

### **Stacking Multiple Passthru Bdevs**
```bash
# Create chain: nvme0n1 → pt1 → pt2
./scripts/rpc.py bdev_passthru_create -b nvme0n1 -p pt1_nvme0n1
./scripts/rpc.py bdev_passthru_create -b pt1_nvme0n1 -p pt2_nvme0n1
```

### **Configuration Persistence**
```bash
# Save configuration
./scripts/rpc.py save_config > spdk_config.json

# Configuration will include:
{
  "method": "bdev_passthru_create",
  "params": {
    "base_bdev_name": "nvme0n1",
    "name": "pt_nvme0n1"
  }
}
```

## Development Template Usage

### **Creating Custom Filter Bdevs**

The Passthru module serves as the template for all filter bdevs. Here's how existing modules extend it:

#### **1. Crypto Bdev Pattern**
```c
// module/bdev/crypto/vbdev_crypto.c follows passthru pattern:
static void
vbdev_crypto_submit_request(struct spdk_io_channel *ch, struct spdk_bdev_io *bdev_io)
{
    // Add encryption/decryption logic before/after I/O
    switch (bdev_io->type) {
    case SPDK_BDEV_IO_TYPE_READ:
        crypto_decrypt_then_complete(bdev_io);  // Custom processing
        break;
    case SPDK_BDEV_IO_TYPE_WRITE:
        crypto_encrypt_then_submit(bdev_io);    // Custom processing
        break;
    default:
        spdk_bdev_io_resubmit(bdev_io, base_ch); // Standard passthrough
    }
}
```

#### **2. Delay Bdev Pattern**
```c
// module/bdev/delay/vbdev_delay.c adds latency injection:
static void
vbdev_delay_submit_request(struct spdk_io_channel *ch, struct spdk_bdev_io *bdev_io)
{
    // Add delay before submitting I/O
    uint64_t delay_us = calculate_delay(bdev_io->type);
    if (delay_us > 0) {
        schedule_delayed_submission(bdev_io, delay_us);
    } else {
        spdk_bdev_io_resubmit(bdev_io, base_ch);
    }
}
```

### **Custom Filter Development Steps**

#### **Step 1: Copy Passthru Template**
```bash
# Start with passthru as template
cp -r module/bdev/passthru module/bdev/your_filter
# Rename files and update Makefile
```

#### **Step 2: Modify I/O Processing**
```c
// Customize vbdev_your_filter_submit_request():
static void
vbdev_your_filter_submit_request(struct spdk_io_channel *ch, struct spdk_bdev_io *bdev_io)
{
    struct vbdev_your_filter *filter_node = /* get context */;
    
    // Add your custom logic here:
    switch (bdev_io->type) {
    case SPDK_BDEV_IO_TYPE_WRITE:
        if (your_custom_condition(bdev_io)) {
            your_custom_processing(bdev_io);
            return;
        }
        break;
    }
    
    // Default: forward to base bdev
    spdk_bdev_io_resubmit(bdev_io, base_ch);
}
```

#### **Step 3: Add Custom RPC Interface**  
```c
// Add management functions in your_filter_rpc.c
static void
rpc_bdev_your_filter_create(struct spdk_jsonrpc_request *request, 
                           const struct spdk_json_val *params)
{
    // Parse parameters and create filter bdev
    your_filter_create(base_name, filter_name, custom_params);
}
```

## Performance Characteristics

### **Overhead Analysis**
- **CPU Overhead**: <1% for simple passthrough
- **Memory Overhead**: ~1KB per bdev instance
- **Latency Impact**: <0.1μs additional per I/O
- **IOPS Impact**: Negligible for straightforward forwarding

### **Scaling Behavior**
- **Multi-threading**: Inherits base bdev threading model
- **Memory Usage**: Linear with number of instances
- **Performance**: Scales with base bdev performance

## Real-World Applications

### **1. Monitoring and Logging**
```c
// Add I/O statistics collection
static void
monitoring_submit_request(struct spdk_io_channel *ch, struct spdk_bdev_io *bdev_io)
{
    record_io_start(bdev_io);  // Custom monitoring
    
    // Set completion callback to record end time
    bdev_io->internal.orig_cb = bdev_io->internal.cb;
    bdev_io->internal.cb = monitoring_io_complete;
    
    spdk_bdev_io_resubmit(bdev_io, base_ch);
}
```

### **2. Data Transformation**
```c
// Example: Compression filter
static void
compression_submit_request(struct spdk_io_channel *ch, struct spdk_bdev_io *bdev_io)
{
    switch (bdev_io->type) {
    case SPDK_BDEV_IO_TYPE_WRITE:
        compress_and_submit(bdev_io);  // Compress before write
        break;
    case SPDK_BDEV_IO_TYPE_READ:
        submit_and_decompress(bdev_io); // Read then decompress
        break;
    default:
        spdk_bdev_io_resubmit(bdev_io, base_ch);
    }
}
```

### **3. Caching Layer**
```c
// Example: Write-through cache
static void
cache_submit_request(struct spdk_io_channel *ch, struct spdk_bdev_io *bdev_io)
{
    switch (bdev_io->type) {
    case SPDK_BDEV_IO_TYPE_READ:
        if (cache_lookup(key)) {
            complete_from_cache(bdev_io);
        } else {
            submit_and_cache(bdev_io);
        }
        break;
    case SPDK_BDEV_IO_TYPE_WRITE:
        cache_invalidate(key);
        spdk_bdev_io_resubmit(bdev_io, base_ch);
        break;
    }
}
```

## Testing and Validation

### **Functional Testing**
```bash
# Test basic functionality
./scripts/rpc.py bdev_passthru_create -b malloc0 -p pt_malloc0
./test/bdev/bdev.sh -i pt_malloc0

# Test feature inheritance
./scripts/rpc.py bdev_get_bdevs -b pt_malloc0  # Should match base capabilities
```

### **Performance Testing**
```bash
# Compare performance with base bdev
./app/fio/fio_plugin configs/test_passthru.fio
```

### **Error Handling**
```bash
# Test base bdev removal handling
./scripts/rpc.py bdev_malloc_delete malloc0  # Should cleanup passthru automatically
```

## Limitations and Considerations

### **Design Constraints**
- **No Feature Addition**: Cannot add capabilities base bdev lacks
- **Synchronous Processing**: I/O path should be non-blocking
- **Memory Management**: Must handle buffer ownership correctly
- **Error Propagation**: Must properly forward error conditions

### **Performance Considerations**
- **Hot Path Optimization**: Minimize processing in submit_request
- **Memory Allocations**: Avoid in I/O path
- **Callback Chains**: Can impact latency if deep

## Quick Reference

### **Common Patterns**
```c
// Forward all capabilities
spdk_bdev_io_type_supported(base_bdev, io_type);

// Forward I/O with custom completion
spdk_bdev_io_resubmit(bdev_io, base_ch);

// Custom processing then forward
your_custom_logic(bdev_io);
spdk_bdev_io_resubmit(bdev_io, base_ch);

// Complete I/O without forwarding
spdk_bdev_io_complete(bdev_io, SPDK_BDEV_IO_STATUS_SUCCESS);
```

---

The Passthru bdev demonstrates SPDK's elegant virtual bdev architecture, enabling powerful storage functionality through simple, composable layers. It serves as both a useful debugging tool and the foundation for all filter bdev implementations.