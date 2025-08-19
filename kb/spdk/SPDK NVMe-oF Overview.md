---
title: SPDK NVMe-oF Overview
type: note
permalink: spdk/spdk-nvme-o-f-overview
tags:
- '["spdk"'
- '"nvme-of"'
- '"overview"'
- '"subsystem"'
- '"namespace"'
- '"bdev"]'
---

# SPDK NVMe-oF Overview

This document provides an overview of SPDK's NVMe over Fabrics (NVMe-oF) implementation, covering core concepts of subsystems, namespaces, and block device integration.

## Core Concepts

### NVMe Subsystem

An **NVMe subsystem** represents a virtual NVMe controller that appears as a separate `/dev/nvmeX` device to hosts. Each subsystem:

- Has a unique NQN (NVMe Qualified Name) - like a network address
- Can contain multiple namespaces (up to 32 by default, configurable)
- Appears as one NVMe controller to connecting hosts

### Namespace

A **namespace** is an individual storage volume within a subsystem, appearing as `/dev/nvmeXnY` to hosts where:

- X = controller number (subsystem)  
- Y = namespace number within that controller
- Each namespace maps to an SPDK block device (bdev)

### Example Topology

```
Subsystem "nqn.2016-06.io.spdk:storage1" (appears as nvme0 to host)
├── Namespace 1: 1TB SSD (nvme0n1)
├── Namespace 2: 2TB SSD (nvme0n2)
└── Namespace 3: 500GB NVMe (nvme0n3)
```

## Block Device (Bdev) Association

### How Bdevs Connect to Namespaces

**The association between bdevs and namespaces is done automatically by name matching.**

When you add a namespace to a subsystem, you specify the **bdev name** as a string parameter. SPDK then:

1. **Looks up the bdev** by name using `spdk_bdev_get_by_name()`
2. **Opens the bdev** for I/O operations  
3. **Associates it** with the namespace automatically

### The Process

```c
// 1. Create and register your bdev first
struct spdk_bdev *my_bdev = create_my_custom_bdev();
strcpy(my_bdev->name, "Storage_Volume_1");  // Give it a name
spdk_bdev_register(my_bdev);

// 2. Create NVMe-oF subsystem
struct spdk_nvmf_subsystem *subsystem = spdk_nvmf_subsystem_create(tgt,
    "nqn.2016-06.io.spdk:storage1", SPDK_NVMF_SUBTYPE_NVME, 0);

// 3. Associate bdev with namespace BY NAME
uint32_t nsid = spdk_nvmf_subsystem_add_ns_ext(subsystem,
    "Storage_Volume_1",  // Must match the bdev name exactly
    NULL, 0, NULL);

// The association is now complete:
// - Namespace 1 points to "Storage_Volume_1" bdev
// - Host will see this as /dev/nvme0n1
```

### Key APIs Involved

**Bdev Registration**: `spdk_bdev_register()` in `include/spdk/bdev_module.h:1151`
```c
int spdk_bdev_register(struct spdk_bdev *bdev);
```

**Bdev Lookup**: `spdk_bdev_get_by_name()` in `include/spdk/bdev.h:414`
```c
struct spdk_bdev *spdk_bdev_get_by_name(const char *bdev_name);
```

**Internal Association**: In `lib/nvmf/subsystem.c:2158`, the `spdk_nvmf_subsystem_add_ns_ext()` function:
```c
// Opens the bdev by name and associates it with the namespace
rc = spdk_bdev_open_ext_v2(bdev_name, true, nvmf_ns_event, ns, &open_opts, &ns->desc);
if (rc != 0) {
    SPDK_ERRLOG("Subsystem %s: bdev %s cannot be opened, error=%d\n",
                subsystem->subnqn, bdev_name, rc);
    return 0;
}

// Store the bdev reference in the namespace
ns->bdev = spdk_bdev_desc_get_bdev(ns->desc);
```

### Important Points

- **Name matching is exact** - the bdev name must match the string parameter exactly
- **Bdev must exist first** - the bdev must be registered before adding to a namespace
- **Automatic opening** - SPDK automatically opens the bdev with appropriate flags for I/O
- **Error handling** - if the bdev name doesn't exist, `add_ns_ext()` returns 0 (failure)
- **Reference counting** - SPDK maintains proper reference counts for the bdev
- **Name-based design** - you don't need bdev pointers, just strings (clean for RPCs/config)

## Common Bdev Types

SPDK supports many bdev types that can be used as namespaces:

- **NVMe**: Real NVMe SSDs (`Nvme0n1`, `Nvme1n1`, etc.)
- **Malloc**: RAM-based storage (`Malloc0`, `Malloc1`, etc.)
- **AIO**: File-backed storage (`AIO0`, `AIO1`, etc.)
- **Null**: Testing/benchmarking (`Null0`, `Null1`, etc.)
- **Logical volumes**: LVM-style volumes (`Lvol0`, `Lvol1`, etc.)

Each bdev type has its own creation APIs, but once created and registered with a name, they all work the same way with NVMe-oF namespaces. All bdevs also support QoS rate limiting and bandwidth controls (see [[SPDK QoS (Quality of Service) Support]]) which automatically apply to their corresponding NVMe-oF namespaces.

## Complete SPDK NVMe-oF Documentation

This overview introduces NVMe-oF core concepts. For implementation details:

### 💻 **[[SPDK NVMe-oF Programming]]** - API Implementation
- Creating subsystems and namespaces programmatically
- Subsystem state management and lifecycle
- Complete programming workflows with examples
- Asynchronous operations and callbacks

### 🌐 **[[SPDK NVMe-oF Network]]** - Network Integration
- Transport layer configuration (TCP, RDMA, FC)
- Listener setup and network endpoints
- Two-layer network architecture details
- Network topology and connectivity patterns

## Key Takeaways

1. **Subsystems** are virtual NVMe controllers with unique NQNs
2. **Namespaces** are storage volumes within subsystems, mapped to bdevs by name
3. **Bdev association** is automatic through exact name matching
4. **Multiple namespace types** are supported through the bdev abstraction
5. **Name-based design** simplifies configuration and RPC interfaces

## Implementation References

### Core NVMe-oF APIs
- **Subsystem Creation**: include/spdk/nvmf.h:446 (`spdk_nvmf_subsystem_create()`)
- **Namespace Addition**: include/spdk/nvmf.h:1096 (`spdk_nvmf_subsystem_add_ns_ext()`)
- **Bdev Integration**: lib/nvmf/subsystem.c:2158 (namespace-bdev association)