---
title: SPDK Bdev RAID Overview
type: note
permalink: spdk/bdev-composition/spdk-bdev-raid-overview
---

# SPDK Bdev RAID Overview

SPDK's RAID subsystem provides software-based redundancy and performance scaling by combining multiple block devices into logical arrays. It supports RAID0, RAID1, RAID5f, and concatenation modes with advanced features like hot-plug, superblocks, and dynamic reconfiguration.

## Architecture Overview

The RAID subsystem operates as a composition layer within SPDK's bdev architecture:

```
Applications
    ↓
RAID Bdev (logical array)
    ↓
┌─────────┬─────────┬─────────┐
│ Base    │ Base    │ Base    │
│ Bdev 1  │ Bdev 2  │ Bdev N  │
└─────────┴─────────┴─────────┘
    ↓         ↓         ↓
  Storage   Storage   Storage
  Device    Device    Device
```

**Key Components:**
- **RAID Framework**: Common infrastructure for all RAID levels (`module/bdev/raid/bdev_raid.c`)
- **RAID Modules**: Level-specific implementations (RAID0, RAID1, RAID5f, concat)
- **Superblock System**: Persistent array metadata for reconstruction
- **Hot-plug Support**: Dynamic device addition/removal

## Code References

### Core RAID Framework
- **Main Framework**: `module/bdev/raid/bdev_raid.c` (~4000 lines)
- **Common Header**: `module/bdev/raid/bdev_raid.h`
- **RPC Interface**: `module/bdev/raid/bdev_raid_rpc.c`
- **Superblock**: `module/bdev/raid/bdev_raid_sb.c`

### RAID Level Implementations
- **RAID0**: `module/bdev/raid/raid0.c` (striping)
- **RAID1**: `module/bdev/raid/raid1.c` (mirroring)
- **RAID5f**: `module/bdev/raid/raid5f.c` (distributed parity)
- **Concat**: `module/bdev/raid/concat.c` (concatenation)

### Module Registration
```c
// Each RAID level registers with the framework
static struct raid_bdev_module g_raid0_module = {
    .level = RAID0,
    .base_bdevs_min = 1,
    .memory_domains_supported = true,
    .dif_supported = true,
    .start = raid0_start,
    .submit_rw_request = raid0_submit_rw_request,
    // ...
};
```

## Supported RAID Levels

### **RAID0 - Striping**
- **Purpose**: Performance scaling through parallel I/O
- **Redundancy**: None (zero fault tolerance)
- **Min Devices**: 1 (unusual but supported)
- **Capacity**: Sum of all devices (100% efficiency)
- **Performance**: Linear scaling with device count
- **Use Case**: High-performance applications where data loss is acceptable

**For detailed RAID0 information**: **[[SPDK RAID0 Overview]]**

### **RAID1 - Mirroring** 
- **Purpose**: Data redundancy through exact copies
- **Redundancy**: Survives single device failure
- **Min Devices**: 2
- **Capacity**: Size of smallest device (50% efficiency)
- **Performance**: Read scaling, write overhead
- **Use Case**: High availability with simple redundancy

### **RAID5f - Distributed Parity (Fast Rebuild)**
- **Purpose**: Balanced redundancy and capacity efficiency
- **Redundancy**: Survives single device failure
- **Min Devices**: 3
- **Capacity**: (N-1)/N efficiency (e.g., 66% with 3 drives)
- **Performance**: Good read performance, write penalty due to parity
- **Use Case**: General-purpose storage with good capacity efficiency

### **Concat - Concatenation**
- **Purpose**: Combine devices into larger logical volume
- **Redundancy**: None
- **Min Devices**: 1
- **Capacity**: Sum of all devices (100% efficiency)
- **Performance**: No performance benefit
- **Use Case**: Creating large volumes from smaller devices

## Feature Matrix

| RAID Level | Fault Tolerance | Capacity Efficiency | Read Performance | Write Performance | Use Case |
|------------|-----------------|-------------------|------------------|-------------------|----------|
| **RAID0** | None | 100% | Excellent | Excellent | Performance |
| **RAID1** | 1 device | 50% | Good | Moderate | Availability |
| **RAID5f** | 1 device | (N-1)/N | Good | Moderate | Balanced |
| **Concat** | None | 100% | Base | Base | Capacity |

## Configuration Examples

### **RAID0 (Striping)**
```bash
# Create RAID0 array with 64KB strip size
./scripts/rpc.py bdev_raid_create \
    -n raid0_array \
    -z 64 \
    -r 0 \
    -b "nvme0n1 nvme1n1 nvme2n1"

# Parameters:
# -n raid0_array: Array name
# -z 64: Strip size in KB
# -r 0: RAID level (0)
# -b "...": Base bdev list
```

### **RAID1 (Mirroring)**
```bash
# Create RAID1 mirror
./scripts/rpc.py bdev_raid_create \
    -n raid1_mirror \
    -r 1 \
    -b "nvme0n1 nvme1n1"

# Data written to both devices
# Reads can come from either device
```

### **RAID5f (Distributed Parity)**
```bash
# Create RAID5f array with 3 devices
./scripts/rpc.py bdev_raid_create \
    -n raid5f_array \
    -z 64 \
    -r 5f \
    -b "nvme0n1 nvme1n1 nvme2n1"

# Survives single device failure
# 2/3 capacity efficiency (66%)
```

### **Concatenation**
```bash
# Combine devices into larger volume
./scripts/rpc.py bdev_raid_create \
    -n concat_vol \
    -r concat \
    -b "ssd0 ssd1 ssd2"

# Logical volume spans all devices sequentially
```

## Advanced Features

### **Superblock Support**
SPDK RAID supports persistent metadata for array reconstruction:

```bash
# Arrays with superblocks survive reboots
./scripts/rpc.py bdev_raid_create \
    -n persistent_array \
    -r 0 \
    -b "nvme0n1 nvme1n1" \
    --superblock

# Array automatically reconstructed on startup
```

### **Hot-plug Operations**
```bash
# Check current RAID status
./scripts/rpc.py bdev_raid_get_bdevs

# Remove failed device (supported by RAID1, RAID5f)
./scripts/rpc.py bdev_raid_remove_base_bdev raid1_array nvme1n1

# Add replacement device
./scripts/rpc.py bdev_raid_add_base_bdev raid1_array nvme3n1

# Monitor rebuild progress
./scripts/rpc.py bdev_raid_get_bdevs -n raid1_array
```

### **Dynamic Resize**
Some RAID levels support capacity expansion:

```bash
# Add device to existing array (limited support)
./scripts/rpc.py bdev_raid_add_base_bdev existing_array new_device

# Note: True expansion is complex and limited
# See individual RAID level documentation for constraints
```

## Performance Characteristics

### **RAID0 Performance**
- **Read IOPS**: Linear scaling (N × base device IOPS)
- **Write IOPS**: Linear scaling (N × base device IOPS)
- **Latency**: Base device latency
- **Throughput**: N × base device throughput

### **RAID1 Performance**  
- **Read IOPS**: Up to 2× base device (load balanced)
- **Write IOPS**: Base device IOPS (must write to both)
- **Latency**: Base device latency
- **Throughput**: Read 2×, Write 1× base device

### **RAID5f Performance**
- **Read IOPS**: (N-1) × base device IOPS (data drives)
- **Write IOPS**: ~0.5× base device (parity overhead)
- **Latency**: Higher for writes (parity calculation)
- **Throughput**: Good read, moderate write

## Use Case Guidelines

### **Choose RAID0 When:**
- **Maximum Performance**: Need highest IOPS/throughput
- **Temporary Data**: Data can be regenerated if lost
- **Development/Testing**: Fast storage for non-critical workloads
- **Cache/Scratch**: Temporary high-speed storage

### **Choose RAID1 When:**
- **High Availability**: Cannot tolerate data loss
- **Simple Redundancy**: Easy to understand and manage
- **Read-Heavy Workloads**: Benefit from read load balancing
- **Critical Small Datasets**: Important data with simple protection

### **Choose RAID5f When:**
- **Balanced Requirements**: Need both capacity and protection
- **Cost Efficiency**: Better capacity utilization than RAID1
- **General Purpose**: Good all-around storage solution
- **Large Arrays**: 3+ devices with mixed workloads

### **Choose Concat When:**
- **Large Volumes**: Need bigger logical volume than single device
- **No Performance Needs**: Sequential access patterns
- **Temporary Aggregation**: Combining smaller devices
- **Legacy Support**: Applications expecting large volumes

## Integration Examples

### **RAID with Virtual Bdevs**
```bash
# Encrypted RAID array
./scripts/rpc.py bdev_crypto_create nvme0n1 crypto0 crypto_aesni_mb AES_XTS
./scripts/rpc.py bdev_crypto_create nvme1n1 crypto1 crypto_aesni_mb AES_XTS
./scripts/rpc.py bdev_raid_create -n encrypted_raid1 -r 1 -b "crypto0 crypto1"
```

### **RAID with Logical Volumes**
```bash
# LVS on RAID array
./scripts/rpc.py bdev_raid_create -n raid0_base -r 0 -b "nvme0n1 nvme1n1 nvme2n1"
./scripts/rpc.py bdev_lvol_create_lvstore raid0_base raid_lvs
./scripts/rpc.py bdev_lvol_create -l raid_lvs -n vol1 -s 10737418240
```

### **Nested RAID** (Limited Support)
```bash
# RAID1 of RAID0 arrays (complex setup)
./scripts/rpc.py bdev_raid_create -n raid0_1 -r 0 -b "nvme0n1 nvme1n1"
./scripts/rpc.py bdev_raid_create -n raid0_2 -r 0 -b "nvme2n1 nvme3n1"
./scripts/rpc.py bdev_raid_create -n raid10 -r 1 -b "raid0_1 raid0_2"
```

## Management & Monitoring

### **Status Monitoring**
```bash
# List all RAID arrays
./scripts/rpc.py bdev_raid_get_bdevs

# Get detailed array information  
./scripts/rpc.py bdev_raid_get_bdevs -n array_name

# Monitor I/O statistics
./scripts/rpc.py bdev_get_iostat -b array_name
```

### **Health Monitoring**
```bash
# Check for degraded arrays
./scripts/rpc.py bdev_raid_get_bdevs | grep -i degraded

# Monitor base device health
for bdev in nvme0n1 nvme1n1 nvme2n1; do
    ./scripts/rpc.py bdev_get_iostat -b $bdev
done
```

### **Configuration Management**
```bash
# Save RAID configuration
./scripts/rpc.py save_config > raid_config.json

# Configuration includes array definitions and can be reloaded
```

## Limitations & Considerations

### **General Limitations**
- **Base Device Requirements**: All base devices should have similar performance
- **Block Size Alignment**: I/O must align to RAID boundaries  
- **Memory Usage**: Additional memory for RAID metadata and buffers
- **CPU Overhead**: Parity calculations (RAID5f) and data distribution

### **RAID-Specific Limitations**
- **RAID0**: Zero fault tolerance - any device failure destroys array
- **RAID1**: 50% capacity efficiency
- **RAID5f**: Write performance penalty due to parity operations
- **Hot-plug**: Not supported for all RAID levels

### **Performance Considerations**
- **Strip Size**: Affects performance - tune based on workload
- **Device Performance Matching**: Slowest device limits array performance
- **NUMA Placement**: Consider CPU/memory locality for optimal performance

## Troubleshooting

### **Common Issues**
```bash
# Array fails to create
./scripts/rpc.py bdev_get_bdevs  # Verify base bdevs exist
./scripts/rpc.py bdev_raid_get_bdevs  # Check for naming conflicts

# Performance issues
./scripts/rpc.py bdev_get_iostat -b array_name  # Check array performance
./scripts/rpc.py bdev_get_iostat -b base_bdev   # Check base device performance

# Device failures
./scripts/rpc.py bdev_raid_get_bdevs -n array_name  # Check array status
dmesg | grep -i error  # Check for hardware errors
```

### **Recovery Procedures**
```bash
# Degraded array recovery (RAID1, RAID5f)
./scripts/rpc.py bdev_raid_remove_base_bdev array_name failed_device
./scripts/rpc.py bdev_raid_add_base_bdev array_name replacement_device

# Array destruction and recreation
./scripts/rpc.py bdev_raid_delete array_name
# Recreate with corrected configuration
```

## Related Documentation
## Related Documentation

- **[[SPDK RAID0 Overview]]**: Detailed RAID0 implementation and performance characteristics
- **[[SPDK LVS Overview]]**: Alternative composition method using logical volumes
## Best Practices

### **Design Guidelines**
1. **Match Device Performance**: Use similar devices in arrays
2. **Consider Failure Domains**: Place devices across different failure domains
3. **Size Planning**: Account for capacity efficiency of chosen RAID level
4. **Performance Testing**: Validate performance meets requirements

### **Operational Practices**
1. **Monitor Array Health**: Regular status checks and alerts
2. **Plan for Failures**: Have replacement devices and procedures ready
3. **Test Recovery**: Regularly test failure and recovery procedures
4. **Capacity Planning**: Monitor usage and plan for expansion

### **Performance Optimization**
1. **Strip Size Tuning**: Match to application I/O patterns
2. **Queue Depth**: Use appropriate queue depths for underlying devices
3. **CPU Placement**: Consider NUMA topology for RAID processing
4. **Memory Configuration**: Ensure adequate memory for RAID operations

---

SPDK's RAID subsystem provides enterprise-grade software RAID capabilities with the performance benefits of userspace processing. It integrates seamlessly with SPDK's bdev architecture while offering advanced features like persistent metadata, hot-plug support, and comprehensive management interfaces.