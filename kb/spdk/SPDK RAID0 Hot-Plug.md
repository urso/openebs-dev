---
title: SPDK RAID0 Hot-Plug
type: note
permalink: spdk/spdk-raid0-hot-plug
tags:
- '["spdk"'
- '"storage"'
- '"raid0"'
- '"hot-plug"'
- '"resize"'
- '"limitations"]'
---

# SPDK RAID0 Hot-Plug and Resize

This document analyzes SPDK RAID0's hot-plug capabilities and dynamic resize support, including critical limitations and architectural constraints.

## Hot-Plug and Resize Analysis

### Framework Infrastructure

The SPDK RAID framework provides comprehensive hot-plug and resize support:

#### ✅ Available Infrastructure
- **Event Detection**: Automatic device removal/resize detection
- **State Management**: `remove_scheduled`, `is_configured` flags  
- **UUID Tracking**: Device identification across renames/reboots
- **I/O Coordination**: Quiesce/unquiesce during topology changes
- **RPC Interface**: `bdev_raid_add_base_bdev`, `bdev_raid_remove_base_bdev`
- **Superblock Support**: Persistent metadata on member devices

### RAID0 Hot-Plug Reality

#### ⚠️ Critical Device Addition Limitations

| Scenario | Support Level | Notes |
|----------|---------------|-------|
| **Initial Construction** | ✅ Full | Adding devices during array setup |
| **UUID Re-addition** | ✅ Full | Re-adding known devices after restart |
| **Device Replacement** | ✅ Limited | Only to pre-allocated slots with known sizes |
| **Hot Expansion** | ❌ **NOT SUPPORTED** | **Critical architectural limitation** |

##### 🚨 Show-Stopper: The `data_size` Assertion

```c
// From bdev_raid.c:3488-3490
if (raid_bdev->state == RAID_BDEV_STATE_ONLINE) {
    assert(base_info->data_size != 0);  // Prevents true expansion!
    assert(base_info->desc == NULL);
}
```

**Critical Issue**: Adding devices to an ONLINE RAID0 array requires empty slots to have pre-determined `data_size != 0`. True expansion would require adding NEW slots with `data_size == 0`, which triggers the assertion failure.

##### What "Hot-Plug Addition" Actually Supports

1. **Device Replacement**: Adding devices to pre-allocated slots (from superblock)
2. **Spare Addition**: Adding spare devices for rebuild scenarios  
3. **Re-addition**: Re-adding devices that were previously part of the array
4. **❌ NOT Array Expansion**: Cannot add devices beyond original `num_base_bdevs`

##### Why True Expansion is Impossible

- **Fixed Topology**: `num_base_bdevs` set at creation, never changes
- **No Data Redistribution**: No logic to redistribute striped data across new devices
- **Size Constraint**: Empty slots must have known sizes from persistent metadata
- **Missing Infrastructure**: No array resize logic for topology changes

#### ❌ No Meaningful Device Removal Support

```c
// From bdev_raid.c:2204-2207
else if (raid_bdev->min_base_bdevs_operational == raid_bdev->num_base_bdevs) {
    /* This raid bdev does not tolerate removing a base bdev. */
    raid_bdev->num_base_bdevs_operational--;
    raid_bdev_deconfigure(raid_bdev, cb_fn, cb_ctx);  // ARRAY FAILS!
}
```

**Behavior**: ANY single device removal immediately fails the entire array.

### Hot-Plug Comparison with Other RAID Levels

| RAID Level | Constraint | Fault Tolerance | Hot-Remove Behavior |
|------------|------------|-----------------|---------------------|
| **RAID0** | `CONSTRAINT_UNSET` | **None** | ❌ **Immediate failure** |
| **RAID1** | `MIN_BASE_BDEVS_OPERATIONAL, 1` | **N-1 devices** | ✅ Continues with 1 device |
| **RAID5F** | `MAX_BASE_BDEVS_REMOVED, 1` | **1 device** | ✅ Tolerates 1 device loss |

## Dynamic Resize Support

### ✅ Automatic Growth Capability

RAID0 arrays **automatically resize** when underlying devices change size:

```c
// From raid0_resize() at raid0.c:403-435
static bool raid0_resize(struct raid_bdev *raid_bdev) {
    // Find minimum size across all base devices
    min_blockcnt = spdk_min(min_blockcnt, base_bdev->blockcnt - base_info->data_offset);
    
    // Align to strip boundaries  
    base_bdev_data_size = (min_blockcnt >> raid_bdev->strip_size_shift) << raid_bdev->strip_size_shift;
    
    // Calculate new RAID0 total capacity
    blockcnt = base_bdev_data_size * raid_bdev->num_base_bdevs;
}
```

### 📏 Resize Behavior

| Scenario | Behavior | Result |
|----------|----------|---------|
| **All devices grow equally** | ✅ RAID0 grows proportionally | Linear capacity increase |
| **Some devices grow** | ✅ RAID0 grows to smallest common size | Limited by smallest device |
| **Mixed shrink/grow** | ✅ RAID0 adjusts to minimum | May shrink if smallest device shrinks |
| **Strip misalignment** | ⚠️ Rounds down to strip boundary | Slight capacity loss possible |

### 🔄 Resize Process

1. **Event Detection**: Framework detects `SPDK_BDEV_EVENT_RESIZE` from base devices `bdev_raid.c:2389`
2. **Size Calculation**: RAID0 recalculates capacity using minimum device size `raid0.c:411-418`
3. **Boundary Alignment**: New size aligned to strip boundaries for optimal performance `raid0.c:417`
4. **Notification**: Block device layer notified of size change `raid0.c:424`
5. **Superblock Update**: If enabled, persistent metadata updated with new sizes `raid0.c:430-432`

### ⚡ Resize Features

- **Transparent Operation**: No manual intervention required
- **Online Resize**: Works with active I/O (brief pause during resize)
- **Persistent Metadata**: Superblock automatically updated with new capacity
- **Strip Alignment**: Maintains optimal I/O performance after resize

## Key Architectural Reality

The sophisticated hot-plug framework **cannot overcome fundamental RAID0 constraints** detailed in [[SPDK RAID0 Limitations]]:
- Arrays have **fixed topology** (`num_base_bdevs`) set at creation
- **No data redistribution** capability for new stripe layouts  
- Hot-plug infrastructure primarily provides **graceful device replacement** and **catastrophic failure handling**

## Summary

### What Works ✅
- **Device replacement** in pre-allocated slots
- **Automatic resize** when existing devices change size
- **Graceful failure handling** for device removal
- **UUID-based device tracking** across reboots

### What Doesn't Work ❌
- **True hot expansion** beyond original device count
- **Degraded operation** with missing devices
- **Data redistribution** for new stripe layouts
- **Fault tolerance** of any kind

The expansion limitations described here are part of broader RAID0 architectural constraints. For guidance on when these limitations make RAID0 inappropriate for your use case, see [[SPDK RAID0 Limitations]].

## Implementation References

### Hot-Plug Infrastructure
- **Framework**: module/bdev/raid/bdev_raid.c (device management, state handling)
- **Resize Logic**: module/bdev/raid/raid0.c:403-435 (`raid0_resize()` function)
- **Event Handling**: module/bdev/raid/bdev_raid.c:2389 (resize event detection)
- **Constraint Checking**: module/bdev/raid/bdev_raid.c:3488-3490 (device addition assertions)