---
title: SPDK LVS Operations
type: note
permalink: spdk/spdk-lvs-operations
tags:
- '["spdk"'
- '"storage"'
- '"lvs"'
- '"operations"'
- '"management"'
- '"rpc"]'
---

# SPDK LVS Operations and Management

This document covers the practical aspects of creating, managing, and operating SPDK Logical Volume Stores (LVS) and Logical Volumes (LVOL).

## Creation Workflow

### 1. Create LVS (Storage Pool)

```bash
# Create LVS on a block device
rpc.py bdev_lvol_create_lvstore <base_bdev> <lvs_name> [options]

# Example:
rpc.py bdev_lvol_create_lvstore Malloc0 my_lvs -c 4194304
```

### 2. Create LVOLs (Individual Volumes)

```bash
# Create LVOL within the LVS
rpc.py bdev_lvol_create -l <lvs_name> <lvol_name> <size_mb>

# Examples:
rpc.py bdev_lvol_create -l my_lvs vol1 100
rpc.py bdev_lvol_create -l my_lvs vol2 200
```

### 3. Access LVOLs

LVOLs appear as block devices named `lvs_name/lvol_name`:
- LVOL "vol1" in LVS "my_lvs" appears as bdev "my_lvs/vol1"
- Can be used by any SPDK application or target

## Management and Operations

### RPC Commands

**LVS Management**:
- `bdev_lvol_create_lvstore` - Create LVS
- `bdev_lvol_delete_lvstore` - Delete LVS
- `bdev_lvol_rename_lvstore` - Rename LVS
- `bdev_lvol_grow_lvstore` - Grow LVS

**LVOL Management**:
- `bdev_lvol_create` - Create LVOL
- `bdev_lvol_delete` - Delete LVOL
- `bdev_lvol_resize` - Resize LVOL
- `bdev_lvol_rename` - Rename LVOL
- `bdev_lvol_snapshot` - Create snapshot
- `bdev_lvol_clone` - Create clone

**Information**:
- `bdev_lvol_get_lvstores` - List all LVS
- `bdev_lvol_get_lvols` - List all LVOLs
- `get_bdevs` - List all bdevs (includes LVOLs)

**Additional Advanced Commands** (module/bdev/lvol/vbdev_lvol_rpc.c):
- `bdev_lvol_clone_bdev` - Clone a bdev as an LVOL
- `bdev_lvol_inflate` - Inflate thin-provisioned LVOL (⚠️ reads entire external device for external snapshots)
- `bdev_lvol_decouple_parent` - Decouple parent relationship
- `bdev_lvol_set_read_only` - Set LVOL as read-only
- `bdev_lvol_start_shallow_copy` - Start shallow copy operation
- `bdev_lvol_check_shallow_copy` - Check shallow copy status
- `bdev_lvol_set_parent` - Set parent LVOL
- `bdev_lvol_set_parent_bdev` - Set external parent bdev

### Configuration Persistence

LVS configuration is automatically persisted:
- Metadata stored in blobstore super blob
- Survives system restarts
- Automatic discovery during startup

## Dynamic Growth and Resizing

### Blobstore and LVS Growth

Both blobstore and LVS support dynamic growth after creation:

**Available Functions**:
- `spdk_bs_grow()` / `spdk_bs_grow_live()` - Grow blobstore (lib/blob/blobstore.c)
- `spdk_lvs_grow()` / `spdk_lvs_grow_live()` - Grow LVS (lib/lvol/lvol.c)
- `spdk_lvol_resize()` - Resize individual LVOLs (include/spdk_internal/lvolstore.h:129)

**RPC Interfaces**:
```bash
# Grow LVS to use additional space
rpc.py bdev_lvol_grow_lvstore -l <lvs_name>

# Resize individual LVOL
rpc.py bdev_lvol_resize <lvol_bdev_name> <new_size_mb>
```

### Growth Process

1. **Underlying device** must be resized first (extend file, RAID expansion, etc.)
2. **Call growth function** - SPDK detects new size automatically
3. **Metadata updated** - allocation bitmaps, superblock, cluster counts
4. **New space available** - can create more LVOLs or grow existing ones

### Key Features

- **Live growth supported** - works while LVS is actively serving I/O
- **Thread-safe operation** - properly synchronized
- **Automatic detection** - no manual size specification needed
- **Production tested** - extensive test suites verify operation under load

### Limitations

- **Growth only** - shrinking not supported (prevents data loss)
- **Device dependency** - underlying device must support resize
- **Metadata space** - very large growth may need additional metadata pages

## Best Practices

### LVS Design

1. **Size appropriately**: Consider growth requirements and underlying device capabilities
2. **Choose cluster size carefully**: Balance between performance and space efficiency
3. **Plan for growth**: Ensure underlying storage can be expanded if needed
4. **Use meaningful names**: LVS and LVOL names should be descriptive

### LVOL Management

1. **Thin provisioning**: Default for most workloads, monitor space usage
2. **Snapshots**: Use for backup and testing scenarios - see [[SPDK LVS Snapshots]] for detailed COW implementation and chain management
3. **Clones**: Efficient for template-based deployments
4. **Resize operations**: Can be performed while I/O is active
5. **External snapshot inflation**: Avoid inflating external snapshots with low data density (high sparse ratio) due to storage amplification

### Monitoring

1. **Space utilization**: Monitor both LVS and individual LVOL usage
2. **Performance metrics**: Track I/O patterns and latencies
3. **Growth trends**: Plan capacity expansion proactively

When encountering issues with LVS operations, see [[SPDK LVS Troubleshooting]] for debugging commands and common resolution strategies.

## Implementation References

### Core Implementation
- **RPC Commands**: module/bdev/lvol/vbdev_lvol_rpc.c (154-1658)
- **LVS Management**: lib/lvol/lvol.c (growth and management functions)
- **Public API**: include/spdk/lvol.h (resize and management APIs)