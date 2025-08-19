---
title: SPDK Bdev Compress
type: note
permalink: spdk/bdev-virtual/spdk-bdev-compress
---

# SPDK Bdev Compress

## Overview

The Compress virtual bdev provides transparent data compression functionality, allowing applications to store data in compressed form while presenting a standard block device interface. This virtual bdev uses SPDK's acceleration framework for hardware-assisted compression when available, and integrates with the reduce library for block-level deduplication and compression.

**Key Capabilities:**
- **Transparent Compression**: Automatic compression and decompression during I/O operations
- **Hardware Acceleration**: Leverages SPDK acceleration framework for optimal performance
- **Multiple Algorithms**: Support for various compression algorithms (LZ4, DEFLATE, etc.)
- **Configurable Levels**: Adjustable compression levels for performance vs. ratio trade-offs
- **Space Efficiency**: Reduces storage requirements through compression and deduplication
- **Virtual Bdev Stacking**: Can be layered with other virtual bdevs

**When to Use:**
- Storage environments where space efficiency is critical
- Workloads with compressible data patterns
- Cost-sensitive deployments requiring reduced storage footprint
- Archive and backup scenarios
- Development/testing environments with space constraints

## Code References

**Function Table**: `module/bdev/compress/vbdev_compress.c:1830-1837`
```c
static const struct spdk_bdev_fn_table vbdev_compress_fn_table = {
    .destruct           = vbdev_compress_destruct,
    .submit_request     = vbdev_compress_submit_request,
    .io_type_supported  = vbdev_compress_io_type_supported,
    .get_io_channel     = vbdev_compress_get_io_channel,
    .dump_info_json     = vbdev_compress_dump_info_json,
    .write_config_json  = NULL,
};
```

**Core Implementation**: `module/bdev/compress/vbdev_compress.c`
- **I/O Support**: Lines 1816-1828 define supported operations (READ, WRITE delegated to base, UNMAP always supported)
- **Compression Parameters**: Lines 24-26 define chunk size (16KB) and backing I/O size (4KB)
- **Algorithm Support**: Lines 60-61 store compression algorithm and level configuration
- **Reduce Integration**: Lines 51-53 integrate with SPDK reduce library for compression

**RPC Interface**: `module/bdev/compress/vbdev_compress_rpc.c`
- **Creation RPC**: `bdev_compress_create` for creating compressed volumes
- **Management RPCs**: `bdev_compress_get_orphans` and `bdev_compress_delete` for lifecycle
- **Volume Operations**: Integration with reduce library for persistent compression metadata

**Headers**: `module/bdev/compress/vbdev_compress.h`
- **Public API**: Compression bdev creation and management functions
- **Configuration Structures**: Algorithm and parameter definitions

## Configuration

### Basic Compression Volume
```json
{
  "method": "bdev_compress_create",
  "params": {
    "base_bdev_name": "malloc0",
    "pm_path": "/tmp/compress_metadata",
    "lb_size": 4096
  }
}
```

### With Specific Algorithm and Level
```json
{
  "method": "bdev_compress_create",
  "params": {
    "base_bdev_name": "nvme0n1",
    "pm_path": "/mnt/pmem/compress_metadata",
    "lb_size": 4096,
    "comp_algo": "DEFLATE",
    "comp_level": 6
  }
}
```

### For High-Performance Workloads
```json
{
  "method": "bdev_compress_create",
  "params": {
    "base_bdev_name": "aio0",
    "pm_path": "/dev/shm/compress_fast",
    "lb_size": 512,
    "comp_algo": "LZ4",
    "comp_level": 1
  }
}
```

### Stacked with Other Virtual Bdevs
```json
{
  "method": "bdev_passthru_create",
  "params": {
    "base_bdev_name": "compress_vol0",
    "passthru_bdev_name": "final_device"
  }
}
```

## Supported I/O Operations

**Delegated Operations** (passed to base bdev):
- `READ`: Reads data with automatic decompression
- `WRITE`: Writes data with automatic compression

**Native Operations**:
- `UNMAP`: Space reclamation with metadata updates

**Unsupported Operations**:
- `RESET`: Not supported due to compression state complexity
- `FLUSH`: Not supported (handled by base bdev)
- `WRITE_ZEROES`: Not supported directly

**Implementation Notes**:
- READ operations involve decompression using acceleration framework
- WRITE operations involve compression before storage to base bdev
- UNMAP operations update both compressed data and reduce metadata

## Performance Characteristics

### Advantages
- **Space Efficiency**: Significant storage reduction for compressible workloads
- **Hardware Acceleration**: Leverages dedicated compression hardware when available
- **Reduced I/O**: Less actual storage I/O due to compression
- **Deduplication**: Eliminate duplicate blocks through reduce library integration

### Performance Considerations
- **CPU Usage**: Compression/decompression requires computational resources
- **Latency Impact**: Additional processing time for compression operations
- **Acceleration Dependency**: Performance varies significantly with hardware availability
- **Memory Usage**: Compression buffers and metadata caching overhead

### Optimization Parameters
- **Chunk Size**: 16KB default optimizes compression ratio vs. granularity
- **Backing I/O Size**: 4KB aligns with typical filesystem block sizes
- **Algorithm Selection**: LZ4 for speed, DEFLATE/ZLIB for ratio
- **Compression Level**: Lower levels favor speed, higher levels favor ratio

## Compression Features

### Algorithm Support
The compress bdev supports multiple compression algorithms through SPDK's acceleration framework:

- **LZ4**: Fast compression with good performance characteristics
- **DEFLATE**: Better compression ratios with moderate performance impact
- **ZLIB**: Similar to DEFLATE with different implementation characteristics
- **Hardware Algorithms**: When supported by acceleration hardware

### Reduce Library Integration
The compress bdev uses SPDK's reduce library for:

- **Block-Level Deduplication**: Eliminate duplicate data blocks
- **Persistent Metadata**: Compression mapping and statistics storage
- **Volume Management**: Create, delete, and examine compressed volumes
- **Space Accounting**: Track compression ratios and space savings

### Metadata Management
- **Persistent Storage**: Metadata stored via `pm_path` parameter
- **Crash Recovery**: Metadata consistency across system restarts
- **Space Tracking**: Compression statistics and block mappings

## Limitations & Considerations

### Operational Constraints
- **Metadata Dependency**: Requires persistent metadata storage path
- **Base Bdev Requirements**: Underlying bdev must support required operations
- **Acceleration Framework**: Performance depends on available acceleration resources
- **Memory Requirements**: Additional memory for compression buffers and metadata

### Performance Impact
- **Latency Overhead**: Compression/decompression adds processing time
- **Throughput Variability**: Performance varies with data compressibility
- **CPU Usage**: Higher CPU utilization compared to uncompressed storage
- **Memory Bandwidth**: Additional memory copies for compression operations

### Operational Limitations
- **Limited I/O Types**: Restricted set of supported I/O operations
- **No Online Resize**: Volume resize requires recreation
- **Metadata Loss**: Metadata corruption can make data inaccessible
- **Hardware Dependency**: Optimal performance requires acceleration hardware

## Code Navigation

**Primary Files**:
- `module/bdev/compress/vbdev_compress.c` - Main implementation with reduce integration
- `module/bdev/compress/vbdev_compress.h` - Public interface and structure definitions
- `module/bdev/compress/vbdev_compress_rpc.c` - RPC command handlers for management
- `module/bdev/compress/Makefile` - Build configuration and reduce library dependencies

**Key Functions**:
- `vbdev_compress_submit_request()` - I/O handling with compression/decompression
- `vbdev_compress_io_type_supported()` - Capability reporting with base bdev delegation
- `vbdev_compress_create()` - Volume creation with reduce library setup
- `vbdev_compress_examine()` - Automatic discovery of existing compressed volumes

**Dependencies**:
- **SPDK Reduce Library**: Block-level compression and deduplication
- **SPDK Acceleration Framework**: Hardware-assisted compression operations
- **Base Bdev**: Underlying storage device for compressed data

## Build Configuration

```bash
# Enable compress bdev support
./configure --with-reduce

# Ensure acceleration framework is available
./configure --with-accel-framework

# For hardware acceleration (Intel QAT example)
./configure --with-qat
```

## Troubleshooting

### Common Issues
- **Metadata Path**: Ensure metadata path is accessible and persistent
- **Acceleration Availability**: Verify acceleration framework initialization
- **Base Bdev Compatibility**: Confirm base bdev supports required operations
- **Space Requirements**: Monitor metadata storage space consumption

### Performance Debugging
- **Compression Ratios**: Monitor actual compression achieved
- **Hardware Utilization**: Check acceleration framework usage statistics
- **Memory Usage**: Track compression buffer allocation
- **I/O Latency**: Measure compression/decompression overhead