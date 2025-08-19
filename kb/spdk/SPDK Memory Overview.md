---
title: SPDK Memory Overview
type: note
permalink: spdk/spdk-memory-overview
tags:
- '["spdk"'
- '"memory"'
- '"hugepages"'
- '"iobuf"'
- '"overview"'
- '"numa"]'
---

# SPDK Memory Management Overview

This document provides an overview of SPDK's memory management architecture, focusing on hugepages and the shared I/O buffer (IOBuf) system.

## Overview

SPDK's performance depends heavily on hugepages for efficient memory management. All DMA-capable memory, including shared I/O buffers, is allocated from hugepages to ensure physical address stability and eliminate page faults.

## Memory Allocation Hierarchy

SPDK uses a two-tiered memory allocation strategy:

### 1. Hugepages (Primary)
Used for all DMA-capable memory:
- Shared I/O buffers (IOBuf system)
- NVMe command/completion queues
- Data buffers for storage operations
- Any memory requiring physical address stability

### 2. Regular Memory (Fallback)
Only used when:
- `--no-huge` flag is specified (testing/development)
- Hugepages are unavailable
- Non-DMA memory allocations

## Hugepages and Shared Buffers Relationship

### Are Shared Buffers Allocated from Hugepages?

**Yes, shared buffers are allocated from hugepages.** SPDK's IOBuf system explicitly uses the `SPDK_MALLOC_DMA` flag to ensure all shared I/O buffers come from hugepages:

```c
// From lib/thread/iobuf.c
node->small_pool_base = spdk_malloc(opts->small_bufsize * opts->small_pool_count, 
                                    IOBUF_ALIGNMENT, NULL, numa_id, SPDK_MALLOC_DMA);
```

This design ensures:
- **Physical address stability**: Critical for DMA operations
- **Zero page faults**: Pre-allocated, pinned memory
- **NUMA locality**: Memory allocated on appropriate NUMA nodes
- **Performance predictability**: No dynamic page allocation overhead

## IOBuf System Architecture

### Buffer Pool Types

SPDK's IOBuf system provides two buffer pool types optimized for different I/O patterns:

```c
#define IOBUF_DEFAULT_SMALL_POOL_SIZE    8192
#define IOBUF_DEFAULT_LARGE_POOL_SIZE    1024
#define IOBUF_DEFAULT_SMALL_BUFSIZE      8192     // 8KB
#define IOBUF_DEFAULT_LARGE_BUFSIZE      135168   // 132KB
```

### Default Memory Usage

**Per NUMA node (default pools):**
- Small buffers: 8KB × 8,192 = 64MB
- Large buffers: 132KB × 1,024 = 132MB
- **Total per NUMA node: ~196MB**

**For multi-NUMA systems:**
- Single NUMA: ~196MB total
- Dual NUMA: ~392MB total

### Buffer Pool Purpose

- **Small buffers (8KB)**: Optimized for random I/O, metadata operations, small block transfers
- **Large buffers (132KB)**: Optimized for sequential I/O, bulk data transfers, streaming operations

## NUMA Considerations

### NUMA-Aware Allocation

SPDK allocates buffer pools per NUMA node to maintain memory locality:

- Each NUMA node gets its own independent buffer pools
- Total memory usage = configuration × number of NUMA nodes
- Memory allocated on the same NUMA node as the CPU cores processing I/O

### Checking NUMA Topology

```bash
numactl --hardware
```

Understanding your system's NUMA topology is crucial for proper memory planning and performance optimization.

## Memory Budget Planning

### Typical Allocation Patterns

For a well-configured SPDK system:

**16GB Hugepages System:**
- **IOBuf pools**: 2-4GB (12-25% of total)
- **Application data**: 8-10GB (50-60% of total)
- **NVMe queues/metadata**: 1-2GB (6-12% of total)
- **Reserve/overhead**: 2-4GB (12-25% of total)

**Smaller Systems (scale proportionally):**
- **2GB system**: 256-512MB for IOBuf
- **4GB system**: 512MB-1GB for IOBuf
- **8GB system**: 1-2GB for IOBuf

## Performance Implications

### Why Hugepages Matter

1. **Reduced TLB pressure**: Fewer page table entries needed
2. **Eliminated page faults**: Memory pre-allocated and pinned
3. **Physical address stability**: Critical for DMA operations
4. **NUMA optimization**: Memory allocated on appropriate nodes

### IOBuf System Benefits

1. **Reduced allocation overhead**: Pre-allocated buffer pools
2. **Predictable performance**: No dynamic memory allocation during I/O
3. **Zero-copy operations**: Buffers can be passed between components
4. **NUMA locality**: Buffers allocated on appropriate NUMA nodes

## Complete SPDK Memory Documentation

This overview introduces SPDK's memory management concepts. For practical implementation:

### ⚙️ **[[SPDK Memory Configuration]]** - Setup and Tuning
- System-specific configuration examples
- Workload-based optimization strategies
- JSON configuration and RPC commands
- Memory budget allocation guidelines

### 📊 **[[SPDK Memory Operations]]** - Monitoring and Troubleshooting
- Runtime monitoring and statistics
- Performance tuning techniques
- Common issues and troubleshooting
- Best practices for production deployment

## Key Takeaways

1. **Hugepages are essential** for SPDK performance - shared buffers are allocated from hugepages
2. **NUMA topology matters** - memory pools are created per NUMA node
3. **Buffer sizing affects performance** - small vs large buffer ratios should match workload patterns
4. **Memory planning is critical** - IOBuf pools typically consume 12-25% of total hugepage allocation

## Implementation References

### Core Memory Management
- **IOBuf Implementation**: lib/thread/iobuf.c (buffer pool management)
- **Memory Allocation**: lib/env_dpdk/memory.c (hugepage allocation)
- **NUMA Support**: lib/env_dpdk/init.c (NUMA-aware initialization)