---
title: SPDK Bdev Malloc
type: note
permalink: spdk/bdev-backends/spdk-bdev-malloc
---

# SPDK Bdev Malloc Backend

The Malloc bdev backend creates RAM-based storage devices for development, testing, and high-performance scenarios where data persistence is not required. It provides the fastest possible I/O performance within SPDK's architecture.

## Architecture Overview

Malloc bdevs store all data in system RAM, providing zero-latency access with full SPDK features:

```
SPDK Application
       ↓
Malloc Bdev Module
       ↓
System RAM (allocated buffer)
       ↓
DMA-capable memory (hugepages)
```

**Key Characteristics:**
- **Zero Latency**: RAM access without storage device overhead
- **Full Feature Support**: Metadata, DIF/DIX, memory domains
- **Volatile Storage**: Data lost on restart (unless saved)
- **Perfect for Testing**: Predictable, fast, isolated storage

## Code References

### Core Implementation
- **Main Module**: `module/bdev/malloc/bdev_malloc.c`
- **Header**: `module/bdev/malloc/bdev_malloc.h`
- **RPC Interface**: `module/bdev/malloc/bdev_malloc_rpc.c`
- **Build Config**: `module/bdev/malloc/Makefile`

### Function Table Implementation
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

### Key Function Implementations

#### **I/O Type Support** (`module/bdev/malloc/bdev_malloc.c:651-664`)
```c
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
    case SPDK_BDEV_IO_TYPE_COMPARE:
    case SPDK_BDEV_IO_TYPE_COMPARE_AND_WRITE:
        return true;
    default:
        return false;
    }
}
```

#### **I/O Processing** (`module/bdev/malloc/bdev_malloc.c:457-510`)
Direct memory copy operations using `memcpy()`, `memset()`, and `memcmp()` for maximum performance.

#### **Memory Domain Support** (`module/bdev/malloc/bdev_malloc.c:673-694`)
```c
static int
bdev_malloc_get_memory_domains(void *ctx, struct spdk_memory_domain **domains, 
                              int array_size)
{
    if (array_size < 1) {
        return -ENOMEM;
    }
    
    domains[0] = g_malloc_memory_domain;
    return 1; // Returns DMA-capable memory domain
}
```

## Supported Features

### ✅ **Fully Supported**
- **All Basic I/O**: READ, WRITE, FLUSH, RESET, UNMAP, WRITE_ZEROES
- **Advanced Operations**: COMPARE, COMPARE_AND_WRITE
- **Metadata Support**: Full DIF/DIX protection with separate/interleaved metadata
- **Memory Domains**: DMA-capable memory integration
- **Acceleration Sequences**: Hardware acceleration support
- **Configuration Management**: Complete JSON-RPC interface

### ✅ **Advanced Features**
- **DIF/DIX Protection**: Configurable data integrity fields
- **Metadata Modes**: Both interleaved and separate metadata layouts
- **Zero-Copy Operations**: Direct memory access without intermediate buffers
- **Hot-plug Support**: Dynamic creation and destruction

### ❌ **Not Supported**
- **Zoned Storage**: No ZNS emulation (use zone_block for that)
- **Persistence**: Data is volatile (lost on restart)
- **NVMe Specific**: NVME_ADMIN, NVME_IO operations
- **File Operations**: SEEK_HOLE, SEEK_DATA (not applicable to RAM)

## Configuration Examples

### **Basic Malloc Bdev**
```bash
# Create 1GB malloc bdev with 4K blocks
./scripts/rpc.py bdev_malloc_create -b malloc0 -s 1024 -u 4096

# Parameters:
# -b malloc0: Bdev name
# -s 1024: Size in MB  
# -u 4096: Block size in bytes (default 512)
```

### **Large Malloc Bdev**
```bash
# Create 10GB malloc bdev
./scripts/rpc.py bdev_malloc_create -b malloc_10g -s 10240 -u 4096

# Verify creation and check size
./scripts/rpc.py bdev_get_bdevs -b malloc_10g
```

### **Multiple Malloc Bdevs**
```bash
# Create multiple malloc bdevs for testing
./scripts/rpc.py bdev_malloc_create -b malloc1 -s 512 -u 4096
./scripts/rpc.py bdev_malloc_create -b malloc2 -s 512 -u 4096  
./scripts/rpc.py bdev_malloc_create -b malloc3 -s 512 -u 4096

# List all created bdevs
./scripts/rpc.py bdev_get_bdevs
```

### **Malloc with Metadata**
```bash
# Create malloc bdev with metadata support
./scripts/rpc.py bdev_malloc_create \
    -b malloc_meta \
    -s 1024 \
    -u 4096 \
    -m 8       # 8 bytes metadata per block

# Verify metadata configuration
./scripts/rpc.py bdev_get_bdevs -b malloc_meta
```

## Performance Characteristics

### **Latency** (Typical)
- **Read**: <1μs (memory access only)
- **Write**: <1μs (memcpy operation)
- **FLUSH**: <0.1μs (no-op for RAM)
- **Zero Latency**: Best possible performance in SPDK

### **IOPS Scaling**
- **Single Thread**: 1M-5M+ IOPS (CPU limited)
- **Multi-threaded**: Scales linearly with CPU cores
- **Queue Depth**: Benefits minimal (RAM is always ready)
- **CPU Bound**: Performance limited by CPU speed and memory bandwidth

### **Throughput**
- **Memory Bandwidth**: Limited by system memory bandwidth (~50-100GB/s)
- **CPU Efficiency**: Highest IOPS per CPU cycle
- **Zero Overhead**: No device driver or kernel overhead

### **Memory Usage**
- **Data Storage**: Full allocation (Size MB × 1024 × 1024 bytes)
- **Metadata Storage**: Additional memory if metadata enabled
- **Hugepage Requirement**: Uses SPDK's DMA-capable memory

## Use Cases & Applications

### **✅ Ideal For:**
- **Unit Testing**: Fast, predictable storage for test suites
- **Performance Benchmarking**: Eliminate storage bottlenecks to test application logic
- **Development**: Quick iteration without wear on physical storage
- **Cache Simulation**: Test caching algorithms with fast backend
- **Algorithm Development**: Focus on logic without I/O overhead

### **✅ Specialized Applications:**
- **High-Frequency Trading**: Ultra-low latency temporary storage
- **In-Memory Databases**: Volatile storage with SPDK interface
- **Temporary Storage**: Fast scratch space for computations
- **Testing Frameworks**: Automated testing with clean state

### **❌ Not Suitable For:**
- **Production Data**: No persistence across restarts
- **Large Datasets**: Limited by available RAM
- **Cost-Sensitive Applications**: RAM is expensive per GB
- **Long-term Storage**: Data volatility

## Advanced Configuration

### **DIF/DIX Protection Setup**
```bash
# Create malloc bdev with DIF protection
./scripts/rpc.py bdev_malloc_create \
    -b malloc_dif \
    -s 1024 \
    -u 4096 \
    -m 8 \
    --dif-type 1

# Configure DIF checking
./scripts/rpc.py bdev_malloc_set_dif_check \
    -b malloc_dif \
    --guard-check \
    --app-tag-check \
    --ref-tag-check
```

### **Memory Domain Integration**
```c
// Malloc bdev provides DMA-capable memory domain
// Applications can query this for zero-copy operations
struct spdk_memory_domain *domains[1];
int rc = spdk_bdev_get_memory_domains(bdev, domains, 1);
// domains[0] points to malloc's memory domain
```

### **Acceleration Sequence Support**
```bash
# Malloc bdev supports acceleration sequences for
# hardware-accelerated operations like encryption/compression
# when stacked with crypto or compress bdevs
```

## Testing & Development

### **Performance Testing**
```bash
# Create malloc bdev for performance testing
./scripts/rpc.py bdev_malloc_create -b perf_test -s 1024 -u 4096

# Run FIO performance test
fio --name=malloc_perf \
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
    --filename=perf_test
```

### **Functionality Testing**
```bash
# Test all I/O types
./test/bdev/bdev.sh -b malloc0

# Test metadata functionality
./test/unit/lib/bdev/malloc.c/malloc_ut

# Test with different block sizes
for bs in 512 1024 4096 8192; do
    ./scripts/rpc.py bdev_malloc_create -b test_${bs} -s 100 -u ${bs}
    ./test/bdev/bdev.sh -b test_${bs}
    ./scripts/rpc.py bdev_malloc_delete test_${bs}
done
```

### **Integration Testing**
```bash
# Test with logical volumes
./scripts/rpc.py bdev_malloc_create -b malloc_lvs -s 2048 -u 4096
./scripts/rpc.py bdev_lvol_create_lvstore malloc_lvs lvs0
./scripts/rpc.py bdev_lvol_create -l lvs0 -n vol1 -s 1073741824

# Test with RAID
./scripts/rpc.py bdev_malloc_create -b malloc_r1 -s 512 -u 4096
./scripts/rpc.py bdev_malloc_create -b malloc_r2 -s 512 -u 4096
./scripts/rpc.py bdev_raid_create -n raid0_malloc -z 64 -r 0 -b "malloc_r1 malloc_r2"
```

## Memory Management

### **Allocation Details**
- **Hugepages**: Allocated from SPDK's hugepage pool
- **DMA Alignment**: Memory is DMA-capable and properly aligned
- **Contiguous Allocation**: Single allocation for entire bdev size
- **Metadata Separation**: Additional allocation if metadata enabled

### **Memory Requirements**
```bash
# Calculate memory needed
# Size in MB + metadata overhead + SPDK overhead
# Example: 1GB malloc bdev = ~1024MB + overhead

# Check hugepage usage
cat /proc/meminfo | grep Huge
```

### **Cleanup on Destruction**
```c
// module/bdev/malloc/bdev_malloc.c:168-185
static int
bdev_malloc_destruct(void *ctx)
{
    struct malloc_disk *mdisk = ctx;
    
    spdk_dma_free(mdisk->malloc_buf);      // Free main buffer
    free(mdisk->malloc_md_buf);           // Free metadata buffer
    free(mdisk);                          // Free structure
    
    return 0;
}
```

## Troubleshooting

### **Common Issues**
```bash
# Not enough hugepages
echo 2048 > /proc/sys/vm/nr_hugepages   # Increase hugepages

# Check available hugepages
grep Huge /proc/meminfo

# Memory allocation failure
./scripts/setup.sh   # Ensure proper hugepage setup
```

### **Performance Issues**
```bash
# Check CPU usage - should be low for malloc operations
top -p $(pgrep spdk_tgt)

# Memory bandwidth testing
./app/fio/fio_plugin --test=memory_bandwidth

# NUMA considerations - ensure memory and CPU on same socket
numactl --hardware
```

## Security Considerations

### **Memory Security**
- **Data in RAM**: Sensitive data remains in memory until overwritten
- **No Disk Persistence**: Data doesn't touch persistent storage
- **Memory Dumps**: Data could appear in core dumps or swap
- **Secure Destruction**: Memory is zeroed on bdev destruction

### **Access Control**
- **Process Memory**: Limited to SPDK process memory space
- **No File System**: No file system permissions to manage
- **SPDK Access Control**: Use SPDK's authentication mechanisms

## Code Examples

### **Malloc Bdev Creation**
```c
// Example: Programmatic malloc bdev creation
#include "spdk/bdev.h"

// See module/bdev/malloc/bdev_malloc.c for complete implementation
// Key functions:
// - malloc_disk_setup_pi(): Setup protection information
// - bdev_malloc_submit_request(): Handle I/O via direct memory operations
// - bdev_malloc_get_memory_domains(): Provide DMA-capable memory domain
```

### **DIF/DIX Implementation**
```c
// module/bdev/malloc/bdev_malloc.c:707-759
// Shows complete DIF setup and validation implementation
// Demonstrates metadata handling patterns
```

---

The Malloc bdev backend represents SPDK's fastest storage option, providing zero-latency RAM-based storage with full feature support. It's essential for development, testing, and applications requiring ultra-high performance temporary storage.