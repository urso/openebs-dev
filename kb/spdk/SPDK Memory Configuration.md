---
title: SPDK Memory Configuration
type: note
permalink: spdk/spdk-memory-configuration
tags:
- '["spdk"'
- '"memory"'
- '"configuration"'
- '"iobuf"'
- '"hugepages"'
- '"numa"'
- '"tuning"]'
---

# SPDK Memory Configuration

This document provides practical configuration guidance for SPDK hugepages and IOBuf systems across different system sizes and workload types.

## Configuration Examples by System Size

### Small System (2-4GB Hugepages)

Suitable for development, testing, or lightweight production workloads:

```bash
# Conservative configuration
./scripts/rpc.py iobuf_set_options \
  --small-pool-count 8192 \
  --large-pool-count 1024 \
  --small-bufsize 8192 \
  --large-bufsize 131072

# Memory usage: ~196MB per NUMA node
```

**Use cases**: Development environments, small-scale testing, single-application deployments

### Medium System (8GB Hugepages)

Balanced configuration for moderate production workloads:

```bash
# Moderate configuration
./scripts/rpc.py iobuf_set_options \
  --small-pool-count 16384 \
  --large-pool-count 2048 \
  --small-bufsize 8192 \
  --large-bufsize 131072

# Memory usage: ~392MB per NUMA node
```

**Use cases**: Medium-scale production, multi-application environments, moderate I/O workloads

### Large System (16GB Hugepages, 8 cores)

High-performance configurations for demanding production workloads:

#### Balanced Configuration (Recommended)
```bash
./scripts/rpc.py iobuf_set_options \
  --small-pool-count 32768 \
  --large-pool-count 4096 \
  --small-bufsize 8192 \
  --large-bufsize 131072

# Memory usage per NUMA node:
# - Small buffers: 8KB × 32,768 = 256MB
# - Large buffers: 128KB × 4,096 = 512MB
# - Total per NUMA node: ~768MB
# - Total system: ~1.5GB (dual NUMA) or ~768MB (single NUMA)
```

#### High-Throughput Configuration
```bash
# For sequential I/O workloads
./scripts/rpc.py iobuf_set_options \
  --small-pool-count 16384 \
  --large-pool-count 8192 \
  --small-bufsize 8192 \
  --large-bufsize 131072

# Favors large buffers for bulk operations
```

#### High-IOPS Configuration
```bash
# For random I/O workloads
./scripts/rpc.py iobuf_set_options \
  --small-pool-count 65536 \
  --large-pool-count 2048 \
  --small-bufsize 8192 \
  --large-bufsize 131072

# Favors small buffers for many small operations
```

## Workload-Specific Recommendations

### Sequential I/O Workloads

**Characteristics**: Video streaming, backup operations, large file transfers

**Configuration Strategy**:
- **Favor large buffers**: Higher `--large-pool-count`
- **Moderate small buffers**: Standard `--small-pool-count`
- **Rationale**: Large sequential operations benefit from bigger buffers

**Example Configuration**:
```bash
./scripts/rpc.py iobuf_set_options \
  --small-pool-count 16384 \
  --large-pool-count 8192
```

### Random I/O Workloads

**Characteristics**: Database operations, virtualization, transactional workloads

**Configuration Strategy**:
- **Favor small buffers**: Higher `--small-pool-count`
- **Moderate large buffers**: Standard `--large-pool-count`
- **Rationale**: Many small operations need more small buffers

**Example Configuration**:
```bash
./scripts/rpc.py iobuf_set_options \
  --small-pool-count 65536 \
  --large-pool-count 2048
```

### Mixed Workloads

**Characteristics**: General-purpose applications, varied I/O patterns

**Configuration Strategy**:
- **Balanced approach**: Proportional allocation based on expected patterns
- **Monitor usage**: Adjust based on actual patterns observed in [[SPDK Memory Operations]]

**Example Configuration**:
```bash
./scripts/rpc.py iobuf_set_options \
  --small-pool-count 32768 \
  --large-pool-count 4096
```

## Configuration Methods

### Runtime Configuration via RPC

Most flexible approach for dynamic configuration:

```bash
# Set IOBuf options before starting I/O
./scripts/rpc.py iobuf_set_options \
  --small-pool-count 32768 \
  --large-pool-count 4096 \
  --small-bufsize 8192 \
  --large-bufsize 131072

# Verify configuration applied
./scripts/rpc.py iobuf_get_stats
```

### JSON Configuration File

Best for reproducible deployments and automation:

```json
{
  "subsystems": [
    {
      "subsystem": "iobuf",
      "config": [
        {
          "method": "iobuf_set_options",
          "params": {
            "small_pool_count": 32768,
            "large_pool_count": 4096,
            "small_bufsize": 8192,
            "large_bufsize": 131072
          }
        }
      ]
    }
  ]
}
```

**Usage**:
```bash
# Apply configuration from file
./build/bin/spdk_tgt -c config.json
```

## NUMA-Aware Configuration

### Understanding NUMA Impact

Memory configuration must account for NUMA topology:

```bash
# Check NUMA topology
numactl --hardware
```

### NUMA Configuration Strategies

1. **Total memory usage** = configuration × number of NUMA nodes
2. **Ensure balanced allocation** across NUMA nodes
3. **Allocate hugepages per node** for optimal performance

```bash
# Allocate hugepages on specific NUMA node
HUGENODE=0 HUGEMEM=8192 sudo ./scripts/setup.sh
HUGENODE=1 HUGEMEM=8192 sudo ./scripts/setup.sh
```

### Dual-NUMA Example

For a system with 2 NUMA nodes and 16GB total hugepages:

```bash
# Allocate 8GB per NUMA node
HUGENODE=0 HUGEMEM=8192 sudo ./scripts/setup.sh
HUGENODE=1 HUGEMEM=8192 sudo ./scripts/setup.sh

# Configure IOBuf (will use memory from both nodes)
./scripts/rpc.py iobuf_set_options \
  --small-pool-count 32768 \
  --large-pool-count 4096

# Total memory usage: ~1.5GB (768MB per NUMA node)
```

## Memory Budget Allocation

### Planning Total Hugepage Requirements

For optimal performance, consider this allocation strategy:

**16GB Hugepages System Budget**:
- **IOBuf pools**: 2-4GB (12-25% of total)
- **Application data**: 8-10GB (50-60% of total)
- **NVMe queues/metadata**: 1-2GB (6-12% of total)
- **Reserve/overhead**: 2-4GB (12-25% of total)

### Scaling Guidelines

**2GB System**:
```bash
HUGEMEM=2048 sudo ./scripts/setup.sh
./scripts/rpc.py iobuf_set_options \
  --small-pool-count 4096 \
  --large-pool-count 512
# IOBuf usage: ~256MB
```

**4GB System**:
```bash
HUGEMEM=4096 sudo ./scripts/setup.sh
./scripts/rpc.py iobuf_set_options \
  --small-pool-count 8192 \
  --large-pool-count 1024
# IOBuf usage: ~512MB
```

**8GB System**:
```bash
HUGEMEM=8192 sudo ./scripts/setup.sh
./scripts/rpc.py iobuf_set_options \
  --small-pool-count 16384 \
  --large-pool-count 2048
# IOBuf usage: ~1GB
```

## Configuration Examples

### Development/Testing Setup
```bash
# 2GB hugepages, single NUMA
HUGEMEM=2048 sudo ./scripts/setup.sh

# Conservative IOBuf
./scripts/rpc.py iobuf_set_options \
  --small-pool-count 4096 \
  --large-pool-count 512
```

### Production High-Performance Setup
```bash
# 16GB hugepages, dual NUMA
HUGEMEM=16384 sudo ./scripts/setup.sh

# Generous IOBuf allocation
./scripts/rpc.py iobuf_set_options \
  --small-pool-count 32768 \
  --large-pool-count 4096
```

### Production Balanced Setup
```bash
# 8GB hugepages
HUGEMEM=8192 sudo ./scripts/setup.sh

# Balanced IOBuf for mixed workloads
./scripts/rpc.py iobuf_set_options \
  --small-pool-count 16384 \
  --large-pool-count 2048
```

## Configuration Validation

After applying configuration, verify it's working correctly:

```bash
# Check IOBuf status and allocation
./scripts/rpc.py iobuf_get_stats

# Verify hugepage allocation
cat /proc/meminfo | grep -i huge

# Check NUMA allocation
numastat -m
```

For ongoing monitoring and troubleshooting of your memory configuration, see [[SPDK Memory Operations]] which covers performance monitoring, tuning, and common issues.

## Implementation References

### Configuration APIs
- **RPC Interface**: scripts/rpc.py (iobuf_set_options, iobuf_get_stats)
- **JSON Configuration**: lib/jsonrpc (configuration file processing)
- **Setup Scripts**: scripts/setup.sh (hugepage allocation)