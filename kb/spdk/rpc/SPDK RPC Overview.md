---
title: SPDK RPC Overview
type: note
permalink: spdk/rpc/spdk-rpc-overview
---

# SPDK RPC Overview

## What is SPDK RPC?

SPDK implements a **JSON-RPC 2.0 compliant server** that enables dynamic configuration and management of SPDK applications without requiring application restarts. This powerful interface allows external management tools to:

- Configure storage devices and protocols
- Monitor system status and performance
- Manage block devices, logical volumes, and RAID arrays
- Control NVMe-oF, iSCSI, and vHost targets
- Debug and trace system operations

## Key Benefits

- **Dynamic Configuration**: Modify SPDK behavior at runtime
- **Standardized Protocol**: Uses JSON-RPC 2.0 for compatibility
- **Extensive Coverage**: 44+ RPC modules covering all SPDK components
- **Extensible**: Applications can register custom RPC methods
- **Multi-Transport**: Unix domain sockets, TCP, IPv6 support
- **State-Aware**: Different methods available during startup vs runtime

## Architecture Overview

```
┌─────────────────┐    JSON-RPC 2.0    ┌──────────────────┐
│   Client Apps   │ ◄─────────────────► │   SPDK Server    │
│  - scripts/rpc.py │                   │  - lib/rpc/      │
│  - Custom tools │                     │  - lib/jsonrpc/  │
└─────────────────┘                     └──────────────────┘
                                              │
                                              ▼
                                    ┌─────────────────────┐
                                    │   RPC Method        │
                                    │   Registry          │
                                    │  - 370+ methods     │
                                    │  - State management │
                                    │  - Plugin support   │
                                    └─────────────────────┘
```

## Quick Start Examples

### Basic Usage
```bash
# List all available RPC methods
./scripts/rpc.py rpc_get_methods

# Get SPDK version information
./scripts/rpc.py spdk_get_version

# List block devices
./scripts/rpc.py bdev_get_bdevs

# Create a RAM disk
./scripts/rpc.py bdev_malloc_create 1024 4096 MyRAMDisk
```

### Advanced Usage
```bash
# Use custom socket path
./scripts/rpc.py -s /tmp/custom.sock bdev_get_bdevs

# Set timeout and retries
./scripts/rpc.py -t 120.0 -r 3 bdev_malloc_create 1024 512

# Server mode for scripting
./scripts/rpc.py --server
```

## Transport Configuration

- **Default Socket**: `/var/tmp/spdk.sock`
- **File Locking**: Prevents multiple SPDK instances
- **Connection Pool**: Up to 64 concurrent connections
- **Buffer Sizes**: 32KB receive, up to 32MB send
- **Protocols**: Unix domain sockets, TCP/IPv4, IPv6

## Method Categories

### Core Framework
- Application lifecycle management
- Logging and tracing controls
- Subsystem management

### Block Device Ecosystem
- **Core Operations**: Create, delete, examine bdevs
- **Storage Types**: malloc, NVMe, AIO, pmem, virtio
- **Virtual Devices**: RAID, compression, encryption, passthrough
- **Logical Volumes**: LVM-like functionality

### Storage Protocols
- **NVMe-oF**: Target and transport management
- **iSCSI**: Target configuration and portal groups
- **vHost**: vHost-user and vHost-SCSI targets

### Hardware Acceleration
- **Intel I/OAT**: DMA offload engine
- **Intel DSA**: Data Streaming Accelerator

## State Management

RPC methods are controlled by state masks:

- **`SPDK_RPC_STARTUP` (0x1)**: Available during initialization only
- **`SPDK_RPC_RUNTIME` (0x2)**: Available after framework starts
- **Combined**: Methods available in both states

## Navigation

### For Users
- **[[SPDK RPC Client Usage]]** - Practical command-line usage
- **[[SPDK RPC Method Registry]]** - Complete method reference

### For Developers  
- **[[SPDK RPC Architecture]]** - Technical implementation details
- **[[Custom RPC Development Guide]]** - Creating custom methods
- **[[SPDK RPC External Examples]]** - Working code examples

### For Testing
- **[[SPDK RPC Testing Examples]]** - Validation and testing approaches

## Source Code Locations

- **Core Server**: `lib/rpc/rpc.c`
- **JSON-RPC Transport**: `lib/jsonrpc/`
- **Public API**: `include/spdk/rpc.h`
- **Python Client**: `scripts/rpc.py`
- **Method Implementations**: 44 `*_rpc.c` files across SPDK modules
- **Documentation**: `doc/jsonrpc.md`

## Key Concepts

- **Method Registration**: Automatic via `SPDK_RPC_REGISTER` macro
- **Parameter Validation**: JSON schema-based validation
- **Error Handling**: Standard JSON-RPC error codes
- **Asynchronous Operations**: Callback-based completion
- **Plugin Support**: External method registration
- **Deprecation Management**: Alias system for backward compatibility

---

*This overview provides the foundation for understanding SPDK's RPC capabilities. Use the navigation links above to explore specific areas in detail.*