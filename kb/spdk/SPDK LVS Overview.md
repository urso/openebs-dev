---
title: SPDK LVS Overview
type: note
permalink: spdk/spdk-lvs-overview
tags:
- '["spdk"'
- '"storage"'
- '"lvs"'
- '"lvol"'
- '"overview"]'
---

# SPDK Logical Volume Store (LVS) and Logical Volumes (LVOL) - Overview

SPDK's logical volume system provides advanced storage management capabilities built on top of the blobstore layer. It implements a two-level hierarchy for efficient storage provisioning and management.

## Core Concepts

### LVS vs LVOL Relationship

**LVS (Logical Volume Store)**:
- Container/pool that manages storage space on a single block device
- Built on top of SPDK's blobstore for advanced storage features
- Has a unique UUID and human-readable name
- Manages space allocation, metadata, and cluster organization
- Defines cluster size (default 4MB) for all volumes within it

**LVOL (Logical Volume)**:
- Individual storage volumes created within an LVS
- Each LVOL exists inside exactly one LVS
- Implemented as SPDK blobs within the blobstore
- Appears as regular SPDK block devices (`spdk_bdev`) to applications
- Named using the convention: `lvs_name/lvol_name`

## Dependencies and Requirements

### Cannot Create LVOL Without LVS

LVOLs have a strict dependency on LVS:
- Every LVOL requires a parent LVS
- LVOLs are implemented as blobs within the LVS's blobstore
- The LVS provides essential infrastructure: space management, cluster allocation, metadata storage

### Blobstore Dependency

LVS cannot be created directly on block devices without blobstore:
- LVS initialization calls `spdk_bs_init()` to create blobstore
- All LVS functionality depends on blobstore features
- The architecture is: bdev → blobstore → LVS → LVOL

### Extensibility

While blobstore itself is a concrete implementation, the extensibility point is at the `spdk_bs_dev` layer:
- Custom storage backends can be implemented via `spdk_bs_dev` interface
- The blobstore and LVS layers above remain unchanged
- Architecture: bdev → bs_dev (interface) → blobstore (concrete) → LVS (concrete)

## Storage Stack Hierarchy

```
Applications (NVMe-oF, iSCSI, etc.)
         ↓
     LVOL (Logical Volumes)
         ↓
     LVS (Logical Volume Store)
         ↓
     Blobstore (Blob Storage System)
         ↓
     Block Devices (BDEV Abstraction)
         ↓
   Storage Hardware (NVMe, AIO, etc.)
```

## SPDK Architecture Integration

LVS operates as a composition bdev within SPDK's unified block device architecture:

- **[[SPDK Bdev Overview]]**: Understand how LVS integrates with the bdev layer

The LVOL module implements the standard `spdk_bdev_fn_table` interface, making logical volumes appear as regular block devices to all SPDK applications.

## Key Data Structures

**Location**: include/spdk_internal/lvolstore.h:88-124

**Constants Location**: include/spdk_internal/lvolstore.h:21 (`SPDK_LVOL_UNIQUE_ID_MAX`)
**UUID Constants**: include/spdk/uuid.h:28 (`SPDK_UUID_STRING_LEN`)

```c
struct spdk_lvol_store {
    struct spdk_bs_dev          *bs_dev;          // lines 90
    struct spdk_blob_store      *blobstore;      // lines 91
    struct spdk_blob            *super_blob;     // lines 92
    spdk_blob_id                super_blob_id;   // lines 93
    struct spdk_uuid            uuid;            // lines 94
    int                         lvol_count;       // lines 95
    int                         lvols_opened;     // lines 96
    TAILQ_HEAD(, spdk_lvol)     lvols;           // lines 97
    TAILQ_HEAD(, spdk_lvol)     pending_lvols;   // lines 98
    // ... additional fields for degraded sets, threading
    char                        name[SPDK_LVS_NAME_MAX];  // lines 103
};

struct spdk_lvol {
    struct spdk_lvol_store      *lvol_store;     // lines 110
    struct spdk_blob            *blob;           // lines 111
    spdk_blob_id                blob_id;         // lines 112
    char                        unique_id[SPDK_LVOL_UNIQUE_ID_MAX];  // lines 113
    char                        name[SPDK_LVOL_NAME_MAX];  // lines 114
    struct spdk_uuid            uuid;            // lines 115
    char                        uuid_str[SPDK_UUID_STRING_LEN];  // lines 116
    struct spdk_bdev            *bdev;           // lines 117
    // ... additional fields for reference counting, degraded handling
};
```

**Constants**: include/spdk/lvol.h:40-41
- `SPDK_LVS_NAME_MAX = 64` (including null terminator)
- `SPDK_LVOL_NAME_MAX = 64` (including null terminator)

## Complete SPDK LVS Documentation

This overview introduces SPDK's Logical Volume Store system. For detailed information on specific aspects:

### 📋 **[[SPDK LVS Operations]]** - Practical Usage
- RPC commands for creating and managing LVS and LVOLs
- Dynamic growth and resizing procedures
- Configuration management and persistence
- Best practices for deployment

### 💾 **[[SPDK LVS Allocation]]** - Storage Engine Details  
- Thin provisioning architecture and implementation
- Disk layout and bitmap structures
- Page size and cluster size configuration
- Allocation tracking mechanisms

### 🔄 **[[SPDK LVS Snapshots]]** - Advanced Features
- Copy-on-write (COW) implementation
- Snapshot and clone operations
- External snapshots and cross-LVS support
- Chain optimization and performance strategies

### ⚙️ **[[SPDK LVS Internals]]** - Implementation Details
- In-memory data structures and algorithms
- Performance characteristics and optimization
- Growth constraints and scaling architecture
- Code references and internal APIs

### 🔧 **[[SPDK LVS Troubleshooting]]** - Operations Guide
- Size limits and scalability constraints
- Common issues and debugging techniques
- Performance tuning and monitoring
- Best practices for large deployments

## Implementation References

### Core Implementation
- **LVS/LVOL Logic**: lib/lvol/lvol.c (main implementation)
- **Data Structures**: include/spdk_internal/lvolstore.h:88-124
- **Public API**: include/spdk/lvol.h
- **RPC Commands**: module/bdev/lvol/vbdev_lvol_rpc.c (154-1658)