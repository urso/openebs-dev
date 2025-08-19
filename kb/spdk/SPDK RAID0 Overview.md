---
title: SPDK RAID0 Overview
type: note
permalink: spdk/spdk-raid0-overview
tags:
- '["spdk"'
- '"storage"'
- '"raid0"'
- '"overview"'
- '"architecture"]'
---

# SPDK RAID0 Overview

This document provides an overview of SPDK's RAID0 implementation, including its architecture, features, and standards compliance.

## Overview

SPDK's RAID0 implementation is located in `module/bdev/raid/raid0.c` and operates as a pluggable module within the broader RAID framework. It provides high-performance data striping across multiple storage devices with zero redundancy.

## Architecture

### Core Components

- **Striping Engine**: Distributes data across base devices using configurable strip sizes
- **I/O Dispatcher**: Routes read/write operations to appropriate base devices  
- **Channel Management**: Manages per-channel I/O routing and completion
- **Integration Layer**: Plugs into the shared RAID framework via module interface

### Key Implementation Files

- `module/bdev/raid/raid0.c` - RAID0-specific logic (449 lines)
- `module/bdev/raid/bdev_raid.c` - Shared RAID framework (~3978 lines)
- `module/bdev/raid/bdev_raid.h` - Common RAID structures and interfaces
- `test/unit/lib/bdev/raid/raid0.c/raid0_ut.c` - Unit tests

## RAID0 Features Implementation

### ✅ Standard RAID0 Features

| Feature | Implementation | Location |
|---------|----------------|----------|
| **Data Striping** | Round-robin distribution across devices | `raid0_submit_rw_request()` `raid0.c:76-162` |
| **Parallel I/O** | Concurrent operations to multiple devices | Framework handles concurrency `raid0.c:126-148` |
| **Performance Scaling** | Linear scaling with device count | Built into striping algorithm `raid0.c:102-106` |
| **No Redundancy** | Single device failure = array failure | Module constraint system `bdev_raid.c:1546` |
| **100% Storage Efficiency** | Full capacity utilization | `raid0_start():388` `raid0.c:388` |
| **Configurable Strip Size** | User-defined strip sizes | `raid_bdev->strip_size` `raid0.c:92,104` |

### ✅ SPDK-Specific Extensions

| Feature | Purpose | Standards Compliance |
|---------|---------|---------------------|
| **Single Drive RAID0** | Testing/development | ⚠️ Unusual but valid |
| **Superblock Support** | Array persistence across reboots | 🔧 Extension |
| **Memory Domains** | Zero-copy I/O optimization | 🔧 Extension |
| **DIF/DIX Support** | Data integrity protection | 🔧 Extension |
| **Dynamic Resize** | Capacity expansion | 🔧 Extension |
| **RPC Management** | JSON-RPC control interface | 🔧 Extension |

## Module Configuration

```c
static struct raid_bdev_module g_raid0_module = {
    .level = RAID0,
    .base_bdevs_min = 1,
    // NOTE: No base_bdevs_constraint defined!
    .memory_domains_supported = true,
    .dif_supported = true,
    .start = raid0_start,
    .submit_rw_request = raid0_submit_rw_request,
    .submit_null_payload_request = raid0_submit_null_payload_request,
    .resize = raid0_resize,
};
```

### Critical Constraint Analysis

**Missing Constraint Definition**: RAID0 does not specify `base_bdevs_constraint` `raid0.c:437-446`, which defaults to:
- `CONSTRAINT_UNSET` → `min_base_bdevs_operational = num_base_bdevs` `bdev_raid.c:1546`
- **Result**: ALL devices must be operational (zero fault tolerance)

## Striping Algorithm

### Address Translation Logic

```c
// Located in raid0_submit_rw_request() at lines 102-106
pd_strip = start_strip / raid_bdev->num_base_bdevs;
pd_idx = start_strip % raid_bdev->num_base_bdevs;  
offset_in_strip = raid_io->offset_blocks & (raid_bdev->strip_size - 1);
pd_lba = (pd_strip << raid_bdev->strip_size_shift) + offset_in_strip;
```

### I/O Boundary Enforcement

- **Strip Boundary Check**: I/O cannot span strip boundaries `raid0.c:95-100`
- **Optimal I/O Boundary**: Set to strip size for performance `raid0.c:391`
- **Automatic Splitting**: Framework splits oversized I/O requests

## Standards Compliance

### ✅ Core RAID0 Compliance

- **Striping Algorithm**: Matches industry standard implementation
- **Performance Characteristics**: Linear scaling as expected
- **Storage Efficiency**: 100% capacity utilization
- **Fault Tolerance**: Zero redundancy (correct behavior)

### 🔧 Value-Added Extensions

- **Enterprise Features**: Superblock, DIF/DIX, memory domains
- **Management Interface**: Comprehensive RPC API
- **Integration**: Clean module architecture
- **Testing**: Comprehensive unit test coverage

### ⚠️ Edge Cases

- **Single-Drive Mode**: Technically valid but unusual
- **Strip Boundary Enforcement**: More restrictive than some implementations

## Complete SPDK RAID0 Documentation

This overview introduces SPDK's RAID0 implementation. For comprehensive understanding:

### 🔌 **[[SPDK RAID0 Hot-Plug]]** - Dynamic Configuration
- Hot-plug capabilities and critical limitations
- Device addition/removal behavior analysis
- Dynamic resize support and constraints
- Why true expansion is impossible

### 🚀 **[[SPDK RAID0 Performance]]** - Optimization Guide
- Performance characteristics and scaling
- Strip size optimization strategies
- Configuration best practices and tuning
- Monitoring and benchmarking techniques

### ⚠️ **[[SPDK RAID0 Limitations]]** - Critical Constraints
- Fundamental RAID0 limitations and risks
- Implementation-specific constraints
- Appropriate vs inappropriate use cases
- Risk assessment and decision framework

## ⚠️ **Read This First**

Before deploying RAID0, **always review** [[SPDK RAID0 Limitations]] to understand the zero fault tolerance and expansion constraints that may make RAID0 inappropriate for your use case.

## SPDK Architecture Integration

RAID0 operates within SPDK's bdev (block device) architecture:

- **[[SPDK Bdev Overview]]**: Understand how RAID0 fits in the broader storage architecture
- **[[SPDK Bdev Development Guide]]**: Learn about the bdev interface RAID0 implements

## Implementation References

### Core Implementation
- **RAID0 Logic**: module/bdev/raid/raid0.c (main implementation)
- **RAID Framework**: module/bdev/raid/bdev_raid.c (shared infrastructure)
- **Common Structures**: module/bdev/raid/bdev_raid.h
- **Unit Tests**: test/unit/lib/bdev/raid/raid0.c/raid0_ut.c