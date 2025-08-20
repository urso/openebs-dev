---
title: SPDK RPC Method Registry
type: note
permalink: spdk/rpc/spdk-rpc-method-registry
---

# SPDK RPC Method Registry

## Overview

SPDK provides **370+ RPC methods** across **44 implementation files** (`*_rpc.c`), organized by functional area. This comprehensive registry catalogs all available methods with their parameters, state requirements, and source locations.

## Core Framework Methods

### Application Lifecycle
**Source**: `lib/event/app_rpc.c`

- **`framework_start_init`** - Initialize SPDK framework
  - **State**: `SPDK_RPC_STARTUP`
  - **Purpose**: Transition from startup to runtime state
  
- **`framework_get_config`** - Get current configuration
  - **State**: `SPDK_RPC_STARTUP | SPDK_RPC_RUNTIME`
  - **Returns**: Complete SPDK configuration as JSON

- **`framework_wait_init`** - Wait for initialization completion
  - **State**: `SPDK_RPC_STARTUP`
  - **Purpose**: Block until framework is ready

### Built-in System Methods
**Source**: `lib/rpc/rpc.c:370`

- **`rpc_get_methods`** - List available RPC methods
  - **Parameters**:
    - `current` (bool, optional): Show only methods available in current state
    - `include_aliases` (bool, optional): Include deprecated aliases
  - **State**: `SPDK_RPC_STARTUP | SPDK_RPC_RUNTIME`
  - **Alias**: `get_rpc_methods` (deprecated)

- **`spdk_get_version`** - Get SPDK version information
  - **Parameters**: None
  - **Returns**: Version string, major/minor/patch numbers, git commit
  - **State**: `SPDK_RPC_STARTUP | SPDK_RPC_RUNTIME`
  - **Alias**: `get_spdk_version` (deprecated)

### Logging & Debugging  
**Source**: `lib/event/log_rpc.c`

- **`log_set_level`** - Set logging level
- **`log_get_level`** - Get current logging level
- **`log_set_print_level`** - Set print level threshold
- **`log_get_print_level`** - Get print level threshold

**Source**: `lib/trace/trace_rpc.c`

- **`trace_enable_tpoint_group`** - Enable trace point group
- **`trace_disable_tpoint_group`** - Disable trace point group
- **`trace_get_tpoint_group_mask`** - Get enabled trace groups

## Block Device Operations

### Core Bdev Management
**Source**: `lib/bdev/bdev_rpc.c`

- **`bdev_get_bdevs`** - List all block devices
  - **Parameters**: 
    - `name` (string, optional): Filter by specific bdev name
  - **State**: `SPDK_RPC_RUNTIME`
  - **Returns**: Array of bdev information (name, aliases, block_size, num_blocks)

- **`bdev_set_options`** - Configure bdev subsystem parameters
  - **Parameters**:
    - `bdev_io_pool_size` (int, optional): I/O structure pool size
    - `bdev_io_cache_size` (int, optional): Per-thread I/O cache size  
    - `bdev_auto_examine` (bool, optional): Automatic device examination
    - `small_buf_pool_size` (int, optional): Small buffer pool size (8KB)
    - `large_buf_pool_size` (int, optional): Large buffer pool size (64KB)
  - **State**: `SPDK_RPC_STARTUP`
  - **Alias**: `set_bdev_options` (deprecated)

- **`bdev_examine`** - Manually examine a block device
- **`bdev_wait_for_examine`** - Wait for examination completion

### Memory-based Block Devices
**Source**: `module/bdev/malloc/bdev_malloc_rpc.c`

- **`bdev_malloc_create`** - Create RAM-based block device  
  - **Parameters**:
    - `num_blocks` (int, required): Number of blocks
    - `block_size` (int, required): Block size in bytes
    - `name` (string, optional): Custom bdev name
    - `uuid` (string, optional): Custom UUID
  - **State**: `SPDK_RPC_RUNTIME`
  - **Alias**: `construct_malloc_bdev` (deprecated)

- **`bdev_malloc_delete`** - Delete RAM-based block device
  - **Parameters**: `name` (string, required)
  - **State**: `SPDK_RPC_RUNTIME`  
  - **Alias**: `delete_malloc_bdev` (deprecated)

### NVMe Block Devices
**Source**: `module/bdev/nvme/bdev_nvme_rpc.c`

- **`bdev_nvme_attach_controller`** - Attach NVMe controller
  - **Parameters**:
    - `name` (string, required): Controller name
    - `trtype` (string, required): Transport type (PCIe, RDMA, TCP)
    - `traddr` (string, required): Transport address
    - `adrfam` (string, optional): Address family
    - `trsvcid` (string, optional): Transport service ID
    - `subnqn` (string, optional): Subsystem NQN

- **`bdev_nvme_detach_controller`** - Detach NVMe controller
- **`bdev_nvme_get_controllers`** - List attached controllers

**Source**: `module/bdev/nvme/nvme_rpc.c`

- **`nvme_enable_controller`** - Enable NVMe controller
- **`nvme_disable_controller`** - Disable NVMe controller  
- **`nvme_reset_controller`** - Reset NVMe controller

### RAID Block Devices
**Source**: `module/bdev/raid/bdev_raid_rpc.c`

- **`bdev_raid_create`** - Create RAID array
  - **Parameters**:
    - `name` (string, required): RAID bdev name
    - `raid_level` (string, required): RAID level (raid0, raid1, raid5)
    - `base_bdevs` (array, required): Component bdev names
    - `strip_size_kb` (int, optional): Strip size in KB
  - **State**: `SPDK_RPC_RUNTIME`

- **`bdev_raid_delete`** - Delete RAID array
- **`bdev_raid_get_bdevs`** - List RAID devices
  - **Parameters**: `category` (string, required): "all", "online", "configuring", "offline"

### Logical Volume Management
**Source**: `module/bdev/lvol/vbdev_lvol_rpc.c`

- **`bdev_lvol_create_lvstore`** - Create logical volume store
  - **Parameters**:
    - `bdev_name` (string, required): Base bdev for lvstore
    - `lvs_name` (string, required): Logical volume store name
    - `cluster_sz` (int, optional): Cluster size in bytes

- **`bdev_lvol_create`** - Create logical volume
  - **Parameters**:
    - `lvol_name` (string, required): Logical volume name
    - `size` (int, required): Size in MB
    - `lvs_name` (string, required): Parent lvstore name
    - `thin_provision` (bool, optional): Thin provisioning

- **`bdev_lvol_delete`** - Delete logical volume
- **`bdev_lvol_resize`** - Resize logical volume
- **`bdev_lvol_get_lvstores`** - List logical volume stores
- **`bdev_lvol_get_lvols`** - List logical volumes

### Storage-Class Memory
**Source**: `module/bdev/pmem/bdev_pmem_rpc.c`

- **`bdev_pmem_create`** - Create persistent memory bdev
  - **Parameters**:
    - `pmem_file` (string, required): Path to pmem file
    - `name` (string, required): Bdev name
  - **Alias**: `construct_pmem_bdev` (deprecated)

- **`bdev_pmem_delete`** - Delete persistent memory bdev
- **`bdev_pmem_create_pool`** - Create PMEM pool
- **`bdev_pmem_delete_pool`** - Delete PMEM pool
- **`bdev_pmem_get_pool_info`** - Get PMEM pool information

### Virtual Block Devices

#### Compression
**Source**: `module/bdev/compress/vbdev_compress_rpc.c`

- **`bdev_compress_create`** - Create compression bdev
- **`bdev_compress_delete`** - Delete compression bdev
- **`bdev_compress_get_orphans`** - Get orphaned compress bdevs

#### Encryption  
**Source**: `module/bdev/crypto/vbdev_crypto_rpc.c`

- **`bdev_crypto_create`** - Create encryption bdev
  - **Parameters**:
    - `base_bdev_name` (string, required): Base bdev to encrypt
    - `name` (string, required): Crypto bdev name
    - `crypto_pmd` (string, required): Crypto poll mode driver
    - `key` (string, required): Encryption key
    - `cipher` (string, optional): Cipher algorithm

- **`bdev_crypto_delete`** - Delete encryption bdev

#### Error Injection
**Source**: `module/bdev/error/vbdev_error_rpc.c`

- **`bdev_error_create`** - Create error injection bdev
- **`bdev_error_delete`** - Delete error injection bdev
- **`bdev_error_inject_error`** - Inject specific error types

#### Delay Testing
**Source**: `module/bdev/delay/vbdev_delay_rpc.c`

- **`bdev_delay_create`** - Create delay testing bdev
- **`bdev_delay_delete`** - Delete delay testing bdev
- **`bdev_delay_update_latency`** - Update latency parameters

## Storage Protocol Methods

### NVMe-oF Target
**Source**: `lib/nvmf/nvmf_rpc.c`

- **`nvmf_create_transport`** - Create transport layer
  - **Parameters**:
    - `trtype` (string, required): Transport type (RDMA, TCP, VFIOUSER)
    - `max_queue_depth` (int, optional): Maximum queue depth
    - `max_io_size` (int, optional): Maximum I/O size
    - `in_capsule_data_size` (int, optional): In-capsule data size

- **`nvmf_create_subsystem`** - Create NVMe subsystem
  - **Parameters**:
    - `nqn` (string, required): Subsystem NQN
    - `allow_any_host` (bool, optional): Allow any host access
    - `serial_number` (string, optional): Serial number
    - `model_number` (string, optional): Model number

- **`nvmf_delete_subsystem`** - Delete subsystem
- **`nvmf_subsystem_add_listener`** - Add listener to subsystem
- **`nvmf_subsystem_add_ns`** - Add namespace to subsystem
- **`nvmf_subsystem_add_host`** - Add allowed host
- **`nvmf_get_subsystems`** - List all subsystems

### iSCSI Target
**Source**: `lib/iscsi/iscsi_rpc.c`

- **`iscsi_create_target_node`** - Create iSCSI target
  - **Parameters**:
    - `target_name` (string, required): Target IQN
    - `alias_name` (string, optional): Target alias
    - `pg_tags` (array, required): Portal group tags
    - `ig_tags` (array, required): Initiator group tags
    - `bdev_name_suffix` (string, optional): LUN suffix

- **`iscsi_delete_target_node`** - Delete iSCSI target
- **`iscsi_create_portal_group`** - Create portal group
- **`iscsi_create_initiator_group`** - Create initiator group
- **`iscsi_get_target_nodes`** - List target nodes

### vHost Target
**Source**: `lib/vhost/vhost_rpc.c`

- **`vhost_create_scsi_controller`** - Create vHost-SCSI controller
  - **Parameters**:
    - `ctrlr` (string, required): Controller name/socket path
    - `cpumask` (string, optional): CPU affinity mask

- **`vhost_create_blk_controller`** - Create vHost-block controller
- **`vhost_delete_controller`** - Delete vHost controller
- **`vhost_scsi_controller_add_target`** - Add SCSI target
- **`vhost_get_controllers`** - List vHost controllers

## Hardware Acceleration

### Intel I/OAT DMA Engine
**Source**: `module/accel/ioat/accel_engine_ioat_rpc.c`

- **`ioat_scan_accel_engine`** - Scan for I/OAT devices
  - **Parameters**: `whitelist` (bool, optional): Use whitelist mode
  - **State**: `SPDK_RPC_STARTUP | SPDK_RPC_RUNTIME`

### Intel DSA (Data Streaming Accelerator)  
**Source**: `module/accel/idxd/accel_engine_idxd_rpc.c`

- **`idxd_scan_accel_engine`** - Scan for DSA devices
  - **Parameters**: 
    - `config_kernel_mode` (bool, optional): Use kernel driver
  - **State**: `SPDK_RPC_STARTUP | SPDK_RPC_RUNTIME`

## Networking & Sockets

**Source**: `lib/sock/sock_rpc.c`

- **`sock_impl_get_opts`** - Get socket implementation options
- **`sock_impl_set_opts`** - Set socket implementation options
- **`sock_set_default_impl`** - Set default socket implementation

## Method State Distribution

### Startup-Only Methods (SPDK_RPC_STARTUP)
- Framework configuration methods
- Subsystem initialization 
- Global option setting
- Hardware device scanning

### Runtime-Only Methods (SPDK_RPC_RUNTIME)  
- Block device operations
- Storage protocol management
- Dynamic reconfiguration
- Performance monitoring

### Always Available (STARTUP | RUNTIME)
- System information queries
- Method introspection
- Logging controls
- Status monitoring

## Usage Examples

### Method Discovery
```bash
# List all available methods
./scripts/rpc.py rpc_get_methods

# List only current state methods  
./scripts/rpc.py rpc_get_methods -p '{"current": true}'

# Include deprecated aliases
./scripts/rpc.py rpc_get_methods -p '{"include_aliases": true}'
```

### Block Device Operations
```bash
# Create RAM disk
./scripts/rpc.py bdev_malloc_create 1024 4096 MyRAMDisk

# List all block devices
./scripts/rpc.py bdev_get_bdevs

# Get specific bdev info
./scripts/rpc.py bdev_get_bdevs -p '{"name": "MyRAMDisk"}'
```

### Storage Protocols
```bash
# Create NVMe-oF subsystem
./scripts/rpc.py nvmf_create_subsystem nqn.2016-06.io.spdk:cnode1

# Add namespace to subsystem
./scripts/rpc.py nvmf_subsystem_add_ns nqn.2016-06.io.spdk:cnode1 MyRAMDisk

# Create transport
./scripts/rpc.py nvmf_create_transport -p '{"trtype": "TCP"}'
```

## Deprecated Method Aliases

Many methods have deprecated aliases for backward compatibility:

- `construct_malloc_bdev` → `bdev_malloc_create`
- `delete_malloc_bdev` → `bdev_malloc_delete`  
- `get_rpc_methods` → `rpc_get_methods`
- `get_spdk_version` → `spdk_get_version`
- `set_bdev_options` → `bdev_set_options`

**Warning Behavior**: First use of deprecated alias prints warning, subsequent uses are silent.

---

**Related Documentation:**
- **[[SPDK RPC Architecture]]** - Implementation details for method registration
- **[[SPDK RPC Client Usage]]** - Practical usage examples  
- **[[Custom RPC Development Guide]]** - Creating custom methods

**Source File Summary:**
- **44 RPC implementation files** (`*_rpc.c`)
- **370+ total methods** across all modules
- **Complete coverage** of SPDK functionality