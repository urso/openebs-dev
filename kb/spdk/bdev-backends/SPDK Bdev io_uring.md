---
title: SPDK Bdev io_uring
type: note
permalink: spdk/bdev-backends/spdk-bdev-io-uring
---

# SPDK Bdev io_uring

## Overview

The io_uring backend provides high-performance asynchronous I/O access to files and block devices using Linux's modern io_uring interface. This backend leverages the kernel's io_uring API to achieve excellent performance with reduced context switching and improved scalability compared to traditional Linux AIO.

**Key Capabilities:**
- **High Performance**: Uses Linux io_uring for efficient asynchronous I/O operations
- **Zoned Storage Support**: Optional ZNS (Zoned Namespace) support for zoned block devices
- **File & Block Device**: Supports both regular files and raw block devices
- **Direct I/O**: Attempts O_DIRECT for optimal performance with fallback support
- **Modern Linux Interface**: Leverages the latest kernel I/O submission/completion mechanism

**When to Use:**
- Modern Linux environments (kernel 5.1+) seeking maximum I/O performance
- High-throughput workloads requiring efficient asynchronous I/O
- Applications needing zoned storage device support
- File-based storage with performance requirements beyond traditional AIO

## Code References

**Function Table**: `module/bdev/uring/bdev_uring.c:731-738`
```c
static const struct spdk_bdev_fn_table uring_fn_table = {
    .destruct           = bdev_uring_destruct,
    .submit_request     = bdev_uring_submit_request,
    .io_type_supported  = bdev_uring_io_type_supported,
    .get_io_channel     = bdev_uring_get_io_channel,
    .dump_info_json     = bdev_uring_dump_info_json,
    .write_config_json  = bdev_uring_write_json_config,
};
```

**Core Implementation**: `module/bdev/uring/bdev_uring.c`
- **I/O Support**: Lines 722-730 define supported operations (READ, WRITE, optional ZNS)
- **Device Opening**: Lines 84-105 handle file/device access with O_DIRECT optimization
- **io_uring Setup**: Lines 612-625 configure the io_uring queue with depth 512
- **ZNS Operations**: Lines 415-453 provide zoned storage management (optional)

**RPC Interface**: `module/bdev/uring/bdev_uring_rpc.c`
- **Creation RPC**: `bdev_uring_create` for dynamic bdev instantiation
- **Configuration**: Lines 29-34 define JSON parameters (name, filename, block_size, uuid)

**Headers**: `module/bdev/uring/bdev_uring.h`
- **Public API**: Device creation and configuration functions
- **Zoned Support**: Conditional compilation for ZNS features

## Configuration

### Basic Setup
```json
{
  "method": "bdev_uring_create",
  "params": {
    "name": "uring0",
    "filename": "/dev/nvme0n1",
    "block_size": 4096
  }
}
```

### File-based Storage
```json
{
  "method": "bdev_uring_create", 
  "params": {
    "name": "uring_file",
    "filename": "/mnt/storage/data.img",
    "block_size": 512
  }
}
```

### With UUID (for identification)
```json
{
  "method": "bdev_uring_create",
  "params": {
    "name": "uring_uuid",
    "filename": "/dev/sdb",
    "block_size": 4096,
    "uuid": "12345678-1234-1234-1234-123456789abc"
  }
}
```

### Build Configuration
```bash
# Enable io_uring support (requires liburing)
./configure --with-uring

# Enable ZNS support (optional)
./configure --with-uring --enable-uring-zns
```

## Performance Characteristics

### Advantages
- **Low Latency**: Reduced kernel crossings compared to Linux AIO
- **High Throughput**: Efficient batching of I/O operations  
- **Scalability**: Better performance under high queue depth
- **Modern Design**: Built for contemporary Linux kernel optimization

### Considerations
- **Linux Specific**: Requires Linux kernel 5.1+ with io_uring support
- **Library Dependency**: Needs liburing development libraries
- **Hardware Direct**: O_DIRECT preferred but falls back for compatibility
- **Memory Usage**: Fixed queue depth of 512 entries per thread

### Performance Tuning
- Use raw block devices for maximum performance
- Ensure liburing is recent version for optimal features
- Consider system-wide io_uring limits and settings
- Monitor with `SPDK_URING_QUEUE_DEPTH` (currently fixed at 512)

## Supported I/O Operations

**Basic Operations**:
- `READ`: Standard read operations
- `WRITE`: Standard write operations

**Zoned Storage Operations** (with `CONFIG_URING_ZNS`):
- `GET_ZONE_INFO`: Retrieve zone information and status
- `ZONE_MANAGEMENT`: Zone reset, open, close, finish operations

**Implementation Notes**:
- I/O operations use the uring submission/completion queue mechanism
- Zoned operations utilize Linux block device ioctls (BLKREPORTZONE, etc.)
- Error handling includes proper cleanup and status reporting

## Limitations & Considerations

### System Requirements
- **Kernel Version**: Linux 5.1+ for basic io_uring, 5.4+ recommended
- **liburing**: Required development library for io_uring interface
- **Zoned Storage**: Linux 5.9+ for complete ZNS support

### Implementation Constraints  
- **Fixed Queue Depth**: 512 entries per I/O channel (not tunable at runtime)
- **No Polling Mode**: IORING_SETUP_IOPOLL disabled for compatibility
- **File Limitations**: Some file types may not support O_DIRECT

### Operational Notes
- Direct I/O attempted first, falls back to buffered I/O if needed
- Zoned storage features require compile-time enablement
- Performance depends on underlying storage device characteristics

## Code Navigation

**Primary Files**:
- `module/bdev/uring/bdev_uring.c` - Main implementation with I/O handling
- `module/bdev/uring/bdev_uring.h` - Public interface and structure definitions
- `module/bdev/uring/bdev_uring_rpc.c` - RPC command handlers for management
- `module/bdev/uring/Makefile` - Build configuration and dependencies

**Key Functions**:
- `bdev_uring_submit_request()` - I/O submission to io_uring
- `bdev_uring_io_type_supported()` - Capability reporting  
- `create_uring_bdev()` - Device instantiation and setup
- `bdev_uring_zone_management_op()` - ZNS zone operations (optional)