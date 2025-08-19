---
title: SPDK LVS Allocation
type: note
permalink: spdk/spdk-lvs-allocation
tags:
- '["spdk"'
- '"storage"'
- '"allocation"'
- '"thin-provisioning"'
- '"blobstore"'
- '"disk-layout"]'
---

# SPDK LVS Thin Provisioning and Allocation

This document covers the allocation tracking architecture, disk layout, and thin provisioning implementation in SPDK's Logical Volume Store system.

## Thin Provisioning and Allocation Tracking

### Architecture Overview

LVS leverages blobstore's sophisticated allocation tracking system with two levels:

1. **Global Allocation Tracking (Blobstore Level)**
2. **Per-LVOL Allocation Tracking (Blob Level)**

### Global Allocation Tracking

The blobstore maintains global allocation state:

```c
struct spdk_blob_store {
    spdk_bit_pool *used_clusters;      // Global cluster allocation bitmap
    uint64_t num_free_clusters;        // Available cluster count
    uint64_t total_data_clusters;      // Total data clusters
}
```

### Per-LVOL Allocation Tracking

Each LVOL (blob) tracks its own cluster mappings:

```c
struct spdk_blob_mut_data {
    uint64_t num_clusters;           // Logical size in clusters
    uint64_t *clusters;              // Array: cluster_index → physical_LBA
    uint64_t num_allocated_clusters; // Actually allocated count
}
```

**Key insight**: For thin provisioning, `clusters[i] = 0` means unallocated, non-zero means allocated to that physical LBA.

## Disk Layout

The blobstore disk layout consists of ordered, fixed-position segments. Only the metadata region and data clusters can grow; all other segments have fixed locations determined at creation time.

```
┌─────────────────┐  ← Page 0 of Cluster 0
│   Super Block   │    Contains layout pointers and configuration
├─────────────────┤  ← Fixed location from super block
│ Used Page Mask  │    Metadata page allocation bitmap
├─────────────────┤  ← Fixed location from super block
│Used Cluster Mask│    Global cluster allocation bitmap (persisted)
├─────────────────┤  ← Fixed location from super block
│Used Blob ID Mask│    Blob ID allocation bitmap
├─────────────────┤  ← Fixed start, can grow
│                 │
│ Metadata Region │    Blob metadata pages (contain cluster mappings)
│                 │
├─────────────────┤  ← Remainder of disk
│                 │
│  Data Clusters  │    Actual data storage
│                 │
└─────────────────┘
```

### 1. Super Block

The super block is always located at page 0 and contains the master layout information for the entire blobstore.

**On-Disk Layout** (4KB page):
```
┌─────────────────────────────────────────────────────────────┐
│ Signature: "SPDKBLOB" (8 bytes)                             │
├─────────────────────────────────────────────────────────────┤
│ Version: 3 (4 bytes) | Length (4 bytes) | Clean flag (4b)  │
├─────────────────────────────────────────────────────────────┤
│ Super Blob ID (8 bytes) | Cluster Size (4 bytes)           │
├─────────────────────────────────────────────────────────────┤
│ Used Page Mask: Start (4b) | Length (4b)                   │
├─────────────────────────────────────────────────────────────┤
│ Used Cluster Mask: Start (4b) | Length (4b)                │
├─────────────────────────────────────────────────────────────┤
│ Used Blob ID Mask: Start (4b) | Length (4b)                │
├─────────────────────────────────────────────────────────────┤
│ Metadata Region: Start (4b) | Length (4b)                  │
├─────────────────────────────────────────────────────────────┤
│ Blobstore Type | Total Size (8b) | IO Unit Size (4b)       │
├─────────────────────────────────────────────────────────────┤
│ MD Page Size (4b) | Reserved space (3996 bytes)            │
├─────────────────────────────────────────────────────────────┤
│ CRC32 checksum (4 bytes)                                   │
└─────────────────────────────────────────────────────────────┘
```

### 2. Used Page Mask

Tracks allocation status of metadata pages within the metadata region. Each bit represents one 4KB metadata page.

**On-Disk Layout**:
```
┌─────────────────────────────────────────────────────────────┐
│ Type: USED_PAGES=0 (1 byte) | Length in bits (4 bytes)     │
├─────────────────────────────────────────────────────────────┤
│ Bitmap data: 1 bit per metadata page                       │
│ Bit 0: MD page 0 | Bit 1: MD page 1 | ... | Bit N         │
│ (0 = free, 1 = allocated)                                  │
│                                                             │
│ [Padded to page boundary]                                   │
└─────────────────────────────────────────────────────────────┘
```

### 3. Used Cluster Mask

Tracks allocation status of data clusters. Each bit represents one cluster (default 1MB). This is the primary allocation bitmap for blob data storage.

**On-Disk Layout**:
```
┌─────────────────────────────────────────────────────────────┐
│ Type: USED_CLUSTERS=1 (1 byte) | Length in bits (4 bytes)  │
├─────────────────────────────────────────────────────────────┤
│ Bitmap data: 1 bit per data cluster                        │
│ Bit 0: Cluster 0 | Bit 1: Cluster 1 | ... | Bit N         │
│ (0 = free, 1 = allocated)                                  │
│                                                             │
│ [Spans multiple pages for large blobstores]                │
└─────────────────────────────────────────────────────────────┘
```

### 4. Metadata Region

Variable-size region containing individual blob metadata. Each blob has a linked chain of metadata pages containing extent descriptors and extended attributes.

**On-Disk Layout** (per metadata page):
```
┌─────────────────────────────────────────────────────────────┐
│ Blob ID (8 bytes) | Sequence Number (4b) | Reserved (4b)   │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│ Descriptors (4072 bytes):                                   │
│  ┌───────────────────────────────────────────────────────┐  │
│  │ Type: EXTENT_PAGE (1b) | Length (4b)                 │  │
│  │ Start Cluster Index (4b)                             │  │
│  │ Physical Cluster LBAs: [LBA0, LBA1, ..., LBA_N]     │  │
│  │ (0 = unallocated for thin provisioning)             │  │
│  └───────────────────────────────────────────────────────┘  │
│  ┌───────────────────────────────────────────────────────┐  │
│  │ Type: XATTR (1b) | Length (4b)                       │  │
│  │ Name Length (2b) | Value Length (2b)                 │  │
│  │ Name String | Value Data                             │  │
│  └───────────────────────────────────────────────────────┘  │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│ Next Page Index (4 bytes) | CRC32 (4 bytes)               │
└─────────────────────────────────────────────────────────────┘
```

### 5. Data Clusters

The remainder of the disk is divided into fixed-size clusters. Each cluster is further divided into pages for I/O operations.

**On-Disk Layout** (per cluster):
```
┌─────────────────────────────────────────────────────────────┐
│ Cluster N (default 1MB = 256 × 4KB pages)                  │
│ ┌─────────────┬─────────────┬─────────────┬─────────────┐   │
│ │   Page 0    │   Page 1    │   Page 2    │     ...     │   │
│ │  (4KB)      │  (4KB)      │  (4KB)      │             │   │
│ └─────────────┴─────────────┴─────────────┴─────────────┘   │
│                                                             │
│ Raw blob data - no special structure                       │
│ Addressed by: cluster_LBA + (page_offset * pages_per_cluster)│
└─────────────────────────────────────────────────────────────┘
```

## Page Size and Cluster Size Configuration

### Page Size Configurability

The metadata page size is **configurable** at blobstore creation time through the `spdk_bs_opts` structure:

```c
struct spdk_bs_opts {
    uint32_t md_page_size;  // Metadata page size (configurable)
    // ... other options
};
```

**Page Size Determination**:
```c
// Page size is the maximum of:
md_page_size = max(device_physical_block_size,
                   SPDK_BS_PAGE_SIZE,      // 4KB default
                   opts->md_page_size);    // User specified
```

**Default**: 4KB (`SPDK_BS_PAGE_SIZE = 0x1000`)
**Minimum**: Device physical block size
**Configurability**: Set via `opts->md_page_size` before calling `spdk_bs_init()`

### Impact on Cluster Sizing

Page size directly affects cluster organization and has **strict constraints**:

**Cluster Size Validation** (lib/blob/blobstore.c:~800):
```c
if (opts->cluster_sz < md_page_size) {
    // ERROR: Cluster size cannot be smaller than page size
    return -EINVAL;
}
```

**Pages per Cluster Calculation**:
```c
bs->pages_per_cluster = bs->cluster_sz / bs->md_page_size;
```

**Impact Examples**:
- **4KB pages, 1MB cluster**: 256 pages per cluster
- **8KB pages, 1MB cluster**: 128 pages per cluster
- **4KB pages, 4MB cluster**: 1024 pages per cluster
- **64KB pages, 1MB cluster**: **INVALID** (cluster < page size)

## Allocation Process for Growing Thin LVOLs

When a thin LVOL needs a new cluster:

1. **I/O hits unallocated region** (`bs_io_unit_is_allocated(blob, io_unit) == false`)
2. **Physical cluster allocation** (lib/blob/blobstore.c:128-142):
   - `bs_claim_cluster()` allocates from global pool using `spdk_bit_pool_allocate_bit()`
   - Updates `blob->active.clusters[cluster_idx] = physical_lba`
   - Increments `blob->active.num_allocated_clusters`
3. **Metadata persistence**: Changes written to metadata region
4. **Global bitmap update**: `used_clusters` bitmap updated on disk

## Allocation Bitmap Size Limits

### Fixed vs Configurable Sizing

The allocation bitmap regions have **hybrid sizing** - they are calculated at creation time but have **built-in growth reserves**:

### Bitmap Size Calculation (at creation)

**Used Page Mask**:
```c
used_page_mask_len = divide_round_up(
    sizeof(struct spdk_bs_md_mask) +          // Header: 5 bytes
    divide_round_up(metadata_pages, 8),       // 1 bit per MD page
    md_page_size                              // Round to page boundary
);
```

**Used Cluster Mask**:
```c
used_cluster_mask_len = divide_round_up(
    sizeof(struct spdk_bs_md_mask) +          // Header: 5 bytes
    divide_round_up(total_clusters, 8),       // 1 bit per cluster
    md_page_size                              // Round to page boundary
);
```

### Growth Reserves and Limits

**Built-in Growth Capacity**:
```c
// Reserve space for maximum possible clusters in metadata region
max_used_cluster_mask_len = divide_round_up(
    sizeof(struct spdk_bs_md_mask) +
    divide_round_up(total_metadata_pages, 8), // All MD pages as clusters
    md_page_size
);

// Use larger of current or reserved size
final_size = max(current_cluster_mask_len, max_used_cluster_mask_len);
```

For understanding how COW operations interact with the allocation system described here, see [[SPDK LVS Snapshots]] which details how snapshot chains leverage the cluster allocation tracking.

## Implementation References

### Allocation Infrastructure
- **Bit Pool API**: include/spdk/bit_pool.h (32-bit cluster allocation)
- **Bit Array API**: include/spdk/bit_array.h (metadata page tracking)
- **Blob Implementation**: lib/blob/blobstore.c (cluster allocation, I/O)
- **Blob Structures**: lib/blob/blobstore.h:156-435 (super block, metadata)