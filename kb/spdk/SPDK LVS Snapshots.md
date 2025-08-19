---
title: SPDK LVS Snapshots
type: note
permalink: spdk/spdk-lvs-snapshots
tags:
- '["spdk"'
- '"storage"'
- '"snapshots"'
- '"cow"'
- '"clones"'
- '"external-snapshots"]'
---

# SPDK LVS Advanced Features: COW and Snapshots

This document covers the advanced features of SPDK's Logical Volume Store system, including copy-on-write (COW), snapshots, clones, and external snapshot capabilities.

## Advanced Features Overview

LVOLs support advanced blobstore features including:

```bash
# Create snapshot
rpc.py bdev_lvol_snapshot <lvol_bdev_name> <snapshot_name>

# Create clone
rpc.py bdev_lvol_clone <snapshot_bdev_name> <clone_name>
```

### Thin Provisioning

LVOLs support thin provisioning by default:
- Space allocated on-demand during writes
- Efficient space utilization
- Transparent to applications

## Copy-on-Write (COW) Implementation

SPDK implements copy-on-write through the blobstore's backing device mechanism, supporting snapshots and clones with deferred allocation.

### Architecture Overview

**Backing Device Chain**:
- Each blob can have a `back_bs_dev` backing device (lib/blob/blobstore.h:130)
- Backing device can be another blob, external storage, or zeroes device
- Chain: Current Blob → Backing Device → (optional) Parent Backing Device

### Read Path for COW

**Allocation Check** (lib/blob/blobstore.h:640-649):
```c
static inline bool
bs_io_unit_is_allocated(struct spdk_blob *blob, uint64_t io_unit)
{
	uint64_t lba = bs_blob_io_unit_to_lba(blob, io_unit);

	if (lba == 0) {
		assert(spdk_blob_is_thin_provisioned(blob));
		return false;
	} else {
		return true;
	}
}
```

**LBA Translation** (lib/blob/blobstore.h:581-599):
```c
static inline uint64_t
bs_blob_io_unit_to_lba(struct spdk_blob *blob, uint64_t io_unit)
{
	uint64_t	lba;
	uint8_t		shift;
	uint64_t	io_units_per_cluster = blob->bs->io_units_per_cluster;

	shift = blob->bs->io_units_per_cluster_shift;
	if (shift != 0) {
		lba = blob->active.clusters[io_unit >> shift];
	} else {
		lba = blob->active.clusters[io_unit / io_units_per_cluster];
	}
	if (lba == 0) {
		return 0;  // Unallocated - will read from backing device
	} else {
		return lba + (io_unit % io_units_per_cluster);
	}
}
```

**Read behavior**:
- **Allocated cluster**: `blob->active.clusters[i] != 0` - Read directly from current blob
- **Unallocated cluster**: `blob->active.clusters[i] == 0` - Automatically read from `blob->back_bs_dev`
- **No backing device**: Return zeros (pure thin provisioning)

### Write Path for COW

**Three write scenarios**:

1. **Already allocated cluster**: Direct write to existing cluster (fast path)
2. **Unallocated cluster, no backing data**: Simple allocation (thin provisioning)
3. **Unallocated cluster, has backing data**: Full copy-on-write operation

**COW Process**:
1. **Cluster allocation**: `bs_claim_cluster()` allocates new physical cluster using the global allocation tracking described in [[SPDK LVS Allocation]]
2. **Backing read**: Read entire cluster from backing device
3. **Data modification**: Merge new write data with backing data
4. **Cluster write**: Write complete cluster to newly allocated space
5. **Metadata update**: Update `blob->active.clusters[i]` with new physical LBA

### Performance Considerations

**Cluster Size Impact**:
- **Larger clusters** (4MB default): Higher COW overhead for partial writes
  - 4KB write triggers 4MB read + 4MB write operation
  - Better for sequential, large-block workloads
- **Smaller clusters** (1MB): Lower COW overhead, more metadata
  - 4KB write triggers 1MB read + 1MB write operation
  - Better for random, small-block workloads

**Backing Device Locality**:
- **Local backing device** (same blobstore): Fast local storage reads
- **Remote backing device** (external snapshot): Network latency for backing reads
- **Performance formula**: `COW_latency = backing_read_latency + local_write_latency`

**COW Amplification**:
```
Write Amplification = cluster_size / actual_write_size

Examples:
- 4KB write to 4MB cluster: 1000x amplification
- 1MB write to 4MB cluster: 4x amplification
- 4MB write to 4MB cluster: 1x amplification (no amplification)
```

### Snapshot Chain Performance Impact

**Chain Traversal for Reads**:
SPDK uses the allocation check for backing device delegation (lib/blob/blob_bs_dev.c:226-227):
```c
if (bs_io_unit_is_allocated(blob, lba)) {
    *base_lba = bs_blob_io_unit_to_lba(blob, lba);
    return true;
}
// Falls through to backing device...
```
- Each unallocated read (`lba == 0`) triggers recursive call to backing device
- Chain traversal continues until allocated data is found or base is reached
- **Read latency increases** with chain depth (exact overhead requires measurement)

**Long Chain Considerations**:
```
Read path example:
Clone → Snap1 → Snap2 → Snap3 → Base
  ↓       ↓       ↓       ↓      ↓
Check   Check   Check   Check  Read (data found)
```

## Chain Breaking and Optimization

SPDK provides built-in functionality to break snapshot chain dependencies by copying backing data into the current volume.

### Available Operations

**1. Complete Chain Flattening - "Inflate"**:
- **RPC Command**: `bdev_lvol_inflate <lvol_name>` (module/bdev/lvol/vbdev_lvol_rpc.c:769)
- **Implementation**: `spdk_bs_inflate_blob()` (lib/blob/blobstore.c)
- **Effect**: Allocates **ALL** clusters and copies all data from entire backing chain
- **Result**: Completely independent volume with no backing device dependencies

**2. Single-Level Decoupling - "Decouple Parent"**:
- **RPC Command**: `bdev_lvol_decouple_parent <lvol_name>` (module/bdev/lvol/vbdev_lvol_rpc.c:809)
- **Implementation**: `spdk_bs_blob_decouple_parent()` (lib/blob/blobstore.c)
- **Effect**: Copies data from **immediate parent** only
- **Result**: Removes one level of dependency while maintaining thin provisioning for unallocated clusters

**Usage Examples**:
```bash
# Complete chain flattening - breaks entire chain
rpc.py bdev_lvol_inflate mystore/volume1

# Remove just immediate parent - reduces chain by one level
rpc.py bdev_lvol_decouple_parent mystore/volume1
```

### When to Use Chain Breaking

**Inflate (Complete Flattening)**:
- Performance-critical workloads requiring minimal read latency
- Volumes that will operate independently long-term
- Breaking long chains (>5 levels) for better performance
- Preparing volumes for migration or backup

**Decouple Parent (Selective)**:
- Incrementally reducing chain depth
- Maintaining thin provisioning benefits while improving performance
- Removing specific problematic parent relationships
- Gradual chain optimization during low-usage periods

### Mid-Chain Performance Optimization

**Chain breaking can be applied to any blob in the chain**, enabling strategic performance optimization:

```
Original chain with poor read performance:
Clone-A → Snapshot-B → Snapshot-C → Base-D
   ↓         ↓           ↓          ↓
  Read    Traverse    Traverse   Found (3 levels)

After inflating Snapshot-B:
Clone-A → [Snapshot-B with all C+D data]
   ↓         ↓
  Read    Found (1 level)
```

**Example optimization workflow**:
```bash
# Before: Clone-A has slow reads due to 3-level chain traversal
# Original: Clone-A → Snapshot-B → Snapshot-C → Base-D

# Inflate intermediate snapshot to reduce traversal
rpc.py bdev_lvol_inflate mystore/snapshot-b

# After: Clone-A now has faster reads (1-level traversal)
# Result: Clone-A → [Snapshot-B with all data]

# Optional cleanup of unused segments (if not shared)
rpc.py bdev_lvol_delete mystore/snapshot-c  # If no other chains use it
rpc.py bdev_lvol_delete mystore/base-d      # If no other chains use it
```

## External Snapshots

SPDK supports using **any bdev as an external snapshot** for LVOL clones, including **LVOLs from other LVS instances**.

### Available Commands

```bash
# Set any bdev (including LVOL from another LVS) as external parent
rpc.py bdev_lvol_set_parent_bdev <lvol_name> <external_bdev_name>

# Create clone using external bdev as base (via application API only)
# Note: bdev_lvol_create_esnap_clone RPC not yet implemented
# Applications can use spdk_lvol_create_esnap_clone() directly
```

### Cross-LVS External Snapshots

**Key capability**: LVOLs can use other LVOLs as external snapshots across different LVS instances.

**Implementation**: `vbdev_lvol_set_external_parent()` (module/bdev/lvol/vbdev_lvol.c:2055)

**Example - Cross-LVS COW Setup**:
```bash
# 1. Create two separate LVS instances
rpc.py bdev_lvol_create_lvstore Malloc0 master_lvs
rpc.py bdev_lvol_create_lvstore Malloc1 clone_lvs

# 2. Create base snapshot in first LVS
rpc.py bdev_lvol_create -l master_lvs base_snapshot 500

# 3. Create clone volume in second LVS
rpc.py bdev_lvol_create -l clone_lvs clone_vol 500

# 4. Set cross-LVS external snapshot relationship
rpc.py bdev_lvol_set_parent_bdev clone_lvs/clone_vol master_lvs/base_snapshot
```

**Result**: `clone_lvs/clone_vol` now has full COW functionality backed by `master_lvs/base_snapshot`

### External Snapshot Architecture

External snapshots work through the `spdk_bs_dev` abstraction layer:

- **Device wrapping**: External bdev automatically wrapped as `spdk_bs_dev` (module/bdev/lvol/vbdev_lvol.c:1931)
- **UUID-based identification**: External snapshots referenced by bdev UUID (module/bdev/lvol/vbdev_lvol.c:2071)
- **Full COW support**: Read/write delegation works transparently via `blob->back_bs_dev` (lib/blob/blobstore.h:130)
- **Flexible backends**: Any bdev type can serve as external snapshot

### Cross-LVS COW Support and Limitations

**SPDK supports COW snapshots across different logical volume stores** via external snapshots, but traditional internal snapshots are limited to single LVS instances.

**Key constraints for traditional snapshots**:
- **Same-LVS requirement**: Traditional `bdev_lvol_snapshot`/`bdev_lvol_clone` operations work within a single LVS
- **Blobstore isolation**: Each LVS is backed by a single blobstore with isolated metadata management
- **RPC validation**: Traditional snapshot commands prevent cross-LVS operations (module/bdev/lvol/vbdev_lvol_rpc.c:611-613)

**Cross-LVS support via external snapshots**:
- **External parent command**: `bdev_lvol_set_parent_bdev` enables cross-LVS COW relationships
- **Full COW functionality**: External LVOLs provide complete snapshot semantics across LVS boundaries

## Critical Limitation: External Snapshot Inflation

**External snapshot inflation always reads the entire external device**, regardless of actual data allocation:

```bash
# WARNING: This will read ALL of external_snapshot, even unallocated space
rpc.py bdev_lvol_inflate clone_lvs/clone_vol  # external_snapshot = 1TB sparse LVOL
# Result: Reads 1TB, allocates 1TB locally (even if only 100GB has real data)
```

**Technical cause**: External `spdk_bs_dev` interface lacks allocation visibility (lib/blob/blobstore.c:7168-7175)

```c
case SPDK_BLOBID_EXTERNAL_SNAPSHOT:
    /*
     * It would be better to rely on back_bs_dev->is_zeroes(), to determine which
     * clusters require allocation. Until there is a blobstore consumer that
     * uses esnaps with an spdk_bs_dev that implements a useful is_zeroes() it is not
     * worth the effort.
     */
    ctx->allocate_all = true;  // Forces full device read/allocation
    break;
```

**Practical implications**:
- **Storage explosion**: Full device capacity allocated locally regardless of actual data
- **Network overhead**: Entire external device read over network/cross-device connection
- **Time penalty**: Inflation time scales with total device size, not actual data size
- **Cost impact**: Sparse 10TB external snapshot becomes 10TB thick-provisioned local volume

**Alternatives and workarounds**:
- **Use `bdev_lvol_decouple_parent`**: Single-level optimization when possible
- **Application-level migration**: Implement custom data transfer for selective copying
- **Design considerations**: Use dense external snapshots (high data-to-capacity ratio)
- **Avoid inflation**: Keep external snapshot relationship for sparse external devices

## Cross-LVS Topologies

External snapshots enable sophisticated multi-LVS architectures:

### Master-Clone Architecture
```
┌─────────────────┐    ┌─────────────────┐
│   Master LVS    │    │    Clone LVS    │
│                 │    │                 │
│ golden_image ←──┼────┼── vm_clone1     │
│              ←──┼────┼── vm_clone2     │
│              ←──┼────┼── vm_clone3     │
└─────────────────┘    └─────────────────┘
```

**Benefits**:
- **Centralized snapshots**: Single source of truth for base images
- **Space efficiency**: Multiple clones share base data via COW
- **Easy updates**: Update master image, clones inherit changes after COW

### Tiered Storage Architecture
```
┌─────────────────┐    ┌─────────────────┐
│  Fast NVMe LVS  │    │ Slower SATA LVS │
│                 │    │                 │
│ active_vm1   ←──┼────┼── archive_snap1 │
│ active_vm2   ←──┼────┼── archive_snap2 │
│ temp_workload ←─┼────┼── cold_backup   │
└─────────────────┘    └─────────────────┘
```

**Benefits**:
- **Performance optimization**: Active data on fast storage
- **Cost efficiency**: Snapshots on slower, cheaper storage
- **Transparent access**: COW provides seamless data access

## Optimization Strategies

### Application-Level

- **Cluster-aligned writes**: Minimize COW overhead by writing full clusters
- **Sequential allocation**: Write to new areas first to avoid COW
- **Batch operations**: Group small writes to same cluster

### Configuration-Level

- **Cluster size tuning**: Balance COW overhead vs. metadata overhead
- **Backing device placement**: Keep frequently accessed backing devices local

### Chain Management

- **Monitor chain depth**: Track snapshot chain lengths in production
- **Periodic flattening**: Use `bdev_lvol_inflate` for heavily used volumes
- **Selective decoupling**: Use `bdev_lvol_decouple_parent` to optimize specific chain levels
- **Base device optimization**: Ensure shared base snapshots use high-performance storage

For RPC commands to create and manage snapshots described in this document, see [[SPDK LVS Operations]]. When troubleshooting snapshot chain performance issues, see [[SPDK LVS Troubleshooting]] for debugging techniques and optimization strategies.

## Implementation References

### COW and Snapshot Implementation
- **COW read path** (lib/blob/blob_bs_dev.c:226-240)
- **External snapshot setup**: `vbdev_lvol_set_external_parent()` (module/bdev/lvol/vbdev_lvol.c:2055-2090)
- **Chain breaking**: `spdk_bs_inflate_blob()` and `spdk_bs_blob_decouple_parent()` (lib/blob/blobstore.c)
- **Backing device creation**: `vbdev_lvol_esnap_dev_create()` (module/bdev/lvol/vbdev_lvol.c:1895-1943)