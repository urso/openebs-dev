---
title: SPDK Bdev Null
type: note
permalink: spdk/bdev-backends/spdk-bdev-null
---

# SPDK Bdev Null Backend

The Null bdev backend provides a no-op storage device that discards all writes and returns zeros for reads. It's designed for performance testing, benchmarking SPDK overhead, and measuring application logic without storage bottlenecks.

## Architecture Overview

Null bdev performs minimal operations to measure pure SPDK framework overhead:

```
SPDK Application
       ↓
Null Bdev Module
       ↓
No-op Operations
├── READ  → Return zeros
├── WRITE → Discard data  
└── FLUSH → Immediate completion
```

**Key Characteristics:**
- **Zero Latency**: Immediate I/O completion
- **No Data Storage**: All data discarded, reads return zeros
- **Minimal CPU**: Absolute minimum processing overhead
- **Perfect Baseline**: Measure SPDK framework costs

## Code References

### Core Implementation
- **Main Module**: `module/bdev/null/bdev_null.c`
- **Header**: `module/bdev/null/bdev_null.h`
- **RPC Interface**: `module/bdev/null/bdev_null_rpc.c`
- **Build Config**: `module/bdev/null/Makefile`

### Function Table Implementation
**Location**: `module/bdev/null/bdev_null.c:127-134`
```c
static const struct spdk_bdev_fn_table null_fn_table = {
    .destruct         = bdev_null_destruct,
    .submit_request   = bdev_null_submit_request,
    .io_type_supported = bdev_null_io_type_supported,
    .get_io_channel   = bdev_null_get_io_channel,
    .write_config_json = bdev_null_write_config_json,
};
```

### Key Function Implementations

#### **I/O Type Support** (`module/bdev/null/bdev_null.c:119-125`)
```c
static bool
bdev_null_io_type_supported(void *ctx, enum spdk_bdev_io_type io_type)
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

#### **I/O Processing** (`module/bdev/null/bdev_null.c:65-117`)
```c
static void
bdev_null_submit_request(struct spdk_io_channel *ch, struct spdk_bdev_io *bdev_io)
{
    switch (bdev_io->type) {
    case SPDK_BDEV_IO_TYPE_READ:
        // Zero out the read buffer
        bdev_null_read(bdev_io);
        break;
    case SPDK_BDEV_IO_TYPE_WRITE:
    case SPDK_BDEV_IO_TYPE_UNMAP:
    case SPDK_BDEV_IO_TYPE_WRITE_ZEROES:
    case SPDK_BDEV_IO_TYPE_FLUSH:
    case SPDK_BDEV_IO_TYPE_RESET:
        // Complete immediately - no actual work
        spdk_bdev_io_complete(bdev_io, SPDK_BDEV_IO_STATUS_SUCCESS);
        break;
    default:
        spdk_bdev_io_complete(bdev_io, SPDK_BDEV_IO_STATUS_FAILED);
        break;
    }
}
```

#### **Read Implementation** (`module/bdev/null/bdev_null.c:46-63`)
```c
static void
bdev_null_read(struct spdk_bdev_io *bdev_io)
{
    int iovcnt = bdev_io->u.bdev.iovcnt;
    struct iovec *iov = bdev_io->u.bdev.iovs;
    
    // Zero out all read buffers
    for (int i = 0; i < iovcnt; i++) {
        memset(iov[i].iov_base, 0, iov[i].iov_len);
    }
    
    spdk_bdev_io_complete(bdev_io, SPDK_BDEV_IO_STATUS_SUCCESS);
}
```

## Supported Features

### ✅ **Supported Operations**
- **Basic I/O**: READ (returns zeros), WRITE (discarded), FLUSH, RESET
- **Advanced I/O**: UNMAP, WRITE_ZEROES
- **Configuration**: JSON-RPC management interface
- **Hot-plug**: Dynamic creation and destruction
- **Multiple Instances**: Create multiple null bdevs

### ❌ **Not Supported**
- **Data Persistence**: No data storage (by design)
- **Metadata**: No DIF/DIX support
- **Memory Domains**: No special memory requirements
- **Acceleration Sequences**: No hardware acceleration
- **Advanced Operations**: COMPARE, COMPARE_AND_WRITE, NVMe-specific
- **Zoned Storage**: No ZNS support

### ✅ **Design Goals Achieved**
- **Minimal Overhead**: Absolute minimum CPU usage
- **Immediate Completion**: Zero latency operations
- **Predictable Behavior**: Consistent performance regardless of "data" size
- **Clean Testing**: No side effects or state persistence

## Configuration Examples

### **Basic Null Bdev**
```bash
# Create null bdev with specified size and block size
./scripts/rpc.py bdev_null_create null0 1024 4096

# Parameters:
# null0: Bdev name
# 1024: Size in MB (virtual - no actual storage)
# 4096: Block size in bytes
```

### **Large Null Bdev**
```bash
# Create very large null bdev (no memory cost)
./scripts/rpc.py bdev_null_create null_large 1048576 4096   # 1TB virtual size

# Verify creation
./scripts/rpc.py bdev_get_bdevs -b null_large
```

### **Multiple Null Bdevs**
```bash
# Create multiple null bdevs for RAID testing
./scripts/rpc.py bdev_null_create null1 1024 4096
./scripts/rpc.py bdev_null_create null2 1024 4096
./scripts/rpc.py bdev_null_create null3 1024 4096
./scripts/rpc.py bdev_null_create null4 1024 4096

# Use in RAID configuration
./scripts/rpc.py bdev_raid_create -n raid0_null -z 64 -r 0 -b "null1 null2 null3 null4"
```

### **Different Block Sizes**
```bash
# Test with various block sizes
./scripts/rpc.py bdev_null_create null_512 1024 512      # 512B blocks
./scripts/rpc.py bdev_null_create null_4k 1024 4096     # 4KB blocks  
./scripts/rpc.py bdev_null_create null_64k 1024 65536   # 64KB blocks
```

## Performance Characteristics

### **Latency**
- **All Operations**: <0.1μs (function call overhead only)
- **READ**: ~0.1μs (memset() to zero buffers)
- **WRITE**: <0.05μs (immediate completion)
- **Baseline Measurement**: Shows pure SPDK framework overhead

### **IOPS Scaling**
- **Single Thread**: 5M-20M+ IOPS (CPU/memory bandwidth limited)
- **Multi-threaded**: Scales linearly with CPU cores
- **Queue Depth**: No benefit (immediate completion)
- **CPU Bound**: Limited only by CPU speed and memory bandwidth

### **Throughput**
- **Memory Bandwidth**: READ limited by memset() bandwidth
- **CPU Efficiency**: Maximum IOPS per CPU cycle
- **No Storage Overhead**: Perfect baseline for application testing

### **Resource Usage**
- **Memory**: Minimal (~KB per bdev instance)
- **CPU**: Lowest possible overhead
- **No I/O**: No actual storage operations

## Use Cases & Applications

### **✅ Primary Use Cases**
- **Performance Benchmarking**: Measure application logic without storage bottlenecks
- **SPDK Overhead Measurement**: Baseline for framework performance costs
- **Application Profiling**: Isolate application performance from storage
- **Throughput Testing**: Maximum theoretical IOPS/throughput testing
- **Framework Validation**: Test SPDK I/O paths without storage complexity

### **✅ Development & Testing**
- **Unit Testing**: Fast, predictable storage for automated tests
- **Algorithm Development**: Focus on logic without I/O variation
- **Stress Testing**: High-load testing without wearing physical storage
- **RAID Testing**: Test RAID logic with fast, predictable backends
- **Configuration Validation**: Test bdev stacking and configuration

### **✅ Specialized Applications**
- **Simulator Backends**: Provide storage interface for simulators
- **Performance Analysis**: Determine maximum theoretical performance
- **Load Generation**: Generate I/O load for testing other components
- **Baseline Establishment**: Performance comparison reference point

### **❌ Not Suitable For**
- **Production Storage**: No data persistence
- **Data Validation**: Reads always return zeros
- **Functional Testing**: Can't verify data integrity
- **Real Workloads**: No actual storage functionality

## Performance Testing & Benchmarking

### **SPDK Framework Overhead Measurement**
```bash
# Create null bdev for overhead testing
./scripts/rpc.py bdev_null_create null_perf 1024 4096

# Measure pure SPDK overhead
fio --name=spdk_overhead \
    --ioengine=spdk_bdev \
    --thread=1 \
    --group_reporting \
    --direct=1 \
    --verify=0 \
    --iodepth=1 \
    --bs=4k \
    --rw=randread \
    --time_based \
    --runtime=10 \
    --filename=null_perf
```

### **Maximum IOPS Testing**
```bash
# Test maximum theoretical IOPS
fio --name=max_iops \
    --ioengine=spdk_bdev \
    --thread=1 \
    --group_reporting \
    --direct=1 \
    --verify=0 \
    --iodepth=32 \
    --bs=4k \
    --rw=randread \
    --time_based \
    --runtime=30 \
    --filename=null_perf
```

### **Multi-threaded Scaling**
```bash
# Test scaling across multiple threads
for threads in 1 2 4 8; do
    echo "Testing with $threads threads"
    fio --name=scaling_test \
        --ioengine=spdk_bdev \
        --thread=1 \
        --numjobs=$threads \
        --group_reporting \
        --direct=1 \
        --verify=0 \
        --iodepth=16 \
        --bs=4k \
        --rw=randread \
        --time_based \
        --runtime=10 \
        --filename=null_perf
done
```

## Integration Examples

### **RAID Performance Testing**
```bash
# Create null bdevs for RAID testing
for i in {1..4}; do
    ./scripts/rpc.py bdev_null_create null_raid$i 1024 4096
done

# Create RAID0 and test performance
./scripts/rpc.py bdev_raid_create -n raid0_test -z 64 -r 0 -b "null_raid1 null_raid2 null_raid3 null_raid4"

# Test RAID overhead vs individual bdevs
fio --name=raid_overhead --ioengine=spdk_bdev --filename=raid0_test --bs=4k --rw=randread --iodepth=32 --runtime=10 --time_based
```

### **Virtual Bdev Testing**
```bash
# Test virtual bdev overhead
./scripts/rpc.py bdev_null_create null_base 1024 4096
./scripts/rpc.py bdev_passthru_create -b null_base -p passthru_null

# Compare base vs virtual performance
fio --name=base_test --ioengine=spdk_bdev --filename=null_base --bs=4k --rw=randread --iodepth=32 --runtime=10 --time_based
fio --name=virtual_test --ioengine=spdk_bdev --filename=passthru_null --bs=4k --rw=randread --iodepth=32 --runtime=10 --time_based
```

### **Application Performance Baseline**
```bash
# Establish application performance baseline
./scripts/rpc.py bdev_null_create app_baseline 10240 4096

# Run application with null backend to measure non-storage overhead
./your_application --storage-backend=app_baseline --benchmark-mode
```

## Development & Testing

### **Automated Testing**
```bash
# Quick functional test
./scripts/rpc.py bdev_null_create test_null 100 4096
./test/bdev/bdev.sh -b test_null
./scripts/rpc.py bdev_null_delete test_null
```

### **Performance Regression Testing**
```bash
#!/bin/bash
# Script to detect SPDK performance regressions

./scripts/rpc.py bdev_null_create regression_test 1024 4096

# Run baseline test
BASELINE_IOPS=$(fio --name=regression \
    --ioengine=spdk_bdev \
    --filename=regression_test \
    --bs=4k --rw=randread \
    --iodepth=32 --runtime=10 \
    --time_based --group_reporting \
    | grep "read: IOPS" | awk '{print $3}')

echo "Baseline IOPS: $BASELINE_IOPS"
# Compare with historical baseline and alert if significant regression
```

### **Custom Application Testing**
```c
// Example: Using null bdev for application testing
#include "spdk/bdev.h"

void test_application_logic(void)
{
    // Open null bdev for testing
    struct spdk_bdev *bdev = spdk_bdev_get_by_name("test_null");
    
    // Run application logic with predictable, fast storage
    run_performance_test(bdev);
    
    // Results show pure application overhead
}
```

## Memory & Resource Management

### **Resource Usage**
- **Per Bdev**: ~1KB memory overhead
- **No Data Storage**: No proportional memory usage with size
- **CPU Usage**: Minimal per operation
- **No Cleanup**: No persistent state to clean

### **Scalability**
```bash
# Create many null bdevs (very low cost)
for i in {1..100}; do
    ./scripts/rpc.py bdev_null_create null_$i 1024 4096
done

# Check resource usage
ps aux | grep spdk_tgt  # Should show minimal memory increase
```

## Troubleshooting

### **Expected Behavior**
```bash
# All reads return zeros
dd if=/dev/zero of=expected_output bs=4096 count=1
hexdump -C expected_output  # Should be all zeros

# Use with SPDK to verify
./scripts/rpc.py bdev_null_create verify_null 1 4096
# Application reads from verify_null should return all zeros
```

### **Performance Issues**
- **Lower than Expected IOPS**: Check CPU utilization and memory bandwidth
- **High Latency**: Indicates system overhead (context switching, etc.)
- **Memory Bandwidth**: READ operations limited by memset() performance

## Security Considerations

### **Data Security**
- **No Data Storage**: Cannot leak sensitive data
- **Memory Clearing**: READ operations explicitly zero buffers
- **No Persistence**: No data survives process restart
- **Isolation**: Each null bdev instance is independent

### **Testing Security**
- **Safe for Testing**: Cannot damage or expose real data
- **No Side Effects**: Operations don't affect system state
- **Predictable**: Behavior is completely deterministic
## Code Examples

### **Minimal I/O Implementation**
```c
// Example: How null bdev implements minimal overhead I/O
// From module/bdev/null/bdev_null.c

static void
bdev_null_submit_request(struct spdk_io_channel *ch, struct spdk_bdev_io *bdev_io)
{
    // Minimal processing - immediate completion for most operations
    switch (bdev_io->type) {
    case SPDK_BDEV_IO_TYPE_READ:
        bdev_null_read(bdev_io);  // Zero buffers and complete
        break;
    default:
        spdk_bdev_io_complete(bdev_io, SPDK_BDEV_IO_STATUS_SUCCESS);
        break;
    }
}
```

---

The Null bdev backend serves as SPDK's ultimate performance baseline, providing immediate I/O completion with minimal overhead. It's essential for performance analysis, testing, and establishing theoretical maximum performance limits within the SPDK framework.