---
title: SPDK Bdev iSCSI
type: note
permalink: spdk/bdev-backends/spdk-bdev-i-scsi
---

# SPDK Bdev iSCSI

## Overview

The iSCSI backend provides access to remote iSCSI targets, allowing SPDK applications to use storage devices over IP networks. This backend implements an iSCSI initiator that connects to remote iSCSI targets and presents them as local block devices within the SPDK framework.

**Key Capabilities:**
- **Network Storage**: Access remote storage devices via iSCSI protocol
- **Standard Compliance**: Full iSCSI initiator implementation with SCSI command set
- **Connection Management**: Automatic connection handling and recovery
- **Performance Optimization**: Asynchronous I/O with connection pooling
- **Flexible Authentication**: Support for CHAP authentication (when configured)

**When to Use:**
- Accessing remote storage over IP networks (SAN environments)
- Cloud storage backends that expose iSCSI targets
- Storage consolidation and centralized storage management
- Legacy storage systems that primarily offer iSCSI access
- Multi-host shared storage scenarios

## Code References

**Function Table**: `module/bdev/iscsi/bdev_iscsi.c:791-798`
```c
static const struct spdk_bdev_fn_table iscsi_fn_table = {
    .destruct           = bdev_iscsi_destruct,
    .submit_request     = bdev_iscsi_submit_request,
    .io_type_supported  = bdev_iscsi_io_type_supported,
    .get_io_channel     = bdev_iscsi_get_io_channel,
    .dump_info_json     = bdev_iscsi_dump_info_json,
    .write_config_json  = bdev_iscsi_write_config_json,
};
```

**Core Implementation**: `module/bdev/iscsi/bdev_iscsi.c`
- **I/O Support**: Lines 775-790 define supported operations (READ, WRITE, FLUSH, RESET, conditional UNMAP)
- **Connection Handling**: Lines 28-35 define connection and timeout parameters
- **Default Settings**: Line 35 sets default initiator name `iqn.2016-06.io.spdk:init`
- **Timeout Configuration**: Line 32 defines default 30-second timeout

**RPC Interface**: `module/bdev/iscsi/bdev_iscsi_rpc.c`
- **Creation RPC**: `bdev_iscsi_create` for connecting to iSCSI targets
- **Options RPC**: `bdev_iscsi_set_options` for timeout configuration
- **Parameters**: Lines 55-59 define JSON parameters (name, initiator_iqn, url)

**Headers**: `module/bdev/iscsi/bdev_iscsi.h`
- **Public API**: Target connection and configuration functions
- **Structure Definitions**: iSCSI-specific context and options

## Configuration

### Basic iSCSI Target Connection
```json
{
  "method": "bdev_iscsi_create",
  "params": {
    "name": "iscsi0",
    "url": "iscsi://192.168.1.100/iqn.2019-06.io.spdk:target/0",
    "initiator_iqn": "iqn.2019-06.io.spdk:initiator"
  }
}
```

### With Authentication (CHAP)
```json
{
  "method": "bdev_iscsi_create",
  "params": {
    "name": "iscsi_auth",
    "url": "iscsi://username%password@192.168.1.100/iqn.2019-06.io.spdk:target/0",
    "initiator_iqn": "iqn.2019-06.io.spdk:initiator-auth"
  }
}
```

### Multiple LUNs from Same Target
```json
{
  "method": "bdev_iscsi_create",
  "params": {
    "name": "iscsi_lun0",
    "url": "iscsi://192.168.1.100/iqn.2019-06.io.spdk:target/0",
    "initiator_iqn": "iqn.2019-06.io.spdk:initiator"
  }
},
{
  "method": "bdev_iscsi_create", 
  "params": {
    "name": "iscsi_lun1",
    "url": "iscsi://192.168.1.100/iqn.2019-06.io.spdk:target/1", 
    "initiator_iqn": "iqn.2019-06.io.spdk:initiator"
  }
}
```

### Global Options Configuration
```json
{
  "method": "bdev_iscsi_set_options",
  "params": {
    "timeout_sec": 60
  }
}
```

## Supported I/O Operations

**Standard Operations**:
- `READ`: Standard read operations via SCSI READ commands
- `WRITE`: Standard write operations via SCSI WRITE commands
- `FLUSH`: Cache flush operations via SCSI SYNCHRONIZE CACHE
- `RESET`: Device reset operations

**Conditional Operations**:
- `UNMAP`: Thin provisioning unmap via SCSI UNMAP (if target supports it)
  - Automatically detected during connection establishment
  - Controlled by `lun->unmap_supported` flag
  - Uses configurable limits: `BDEV_ISCSI_DEFAULT_MAX_UNMAP_LBA_COUNT` (32768)

**Implementation Notes**:
- Operations translated to appropriate SCSI commands over iSCSI
- Asynchronous I/O with callback-based completion
- Error handling includes SCSI sense data parsing

## Performance Characteristics

### Advantages
- **Network Flexibility**: Access storage over standard IP networks
- **Scalability**: Multiple connections and targets supported
- **Protocol Maturity**: Well-established iSCSI standard with broad compatibility
- **Resource Sharing**: Multiple initiators can access shared storage

### Performance Considerations
- **Network Latency**: Performance heavily dependent on network characteristics
- **Bandwidth Limitation**: Constrained by network throughput capabilities
- **Protocol Overhead**: iSCSI and TCP/IP stack overhead compared to direct storage
- **Connection Management**: Connection establishment and maintenance costs

### Optimization Settings
- **Timeout Configuration**: Default 30 seconds, adjustable via `bdev_iscsi_set_options`
- **Connection Polling**: 500μs polling interval for connections
- **Queue Depth**: Dependent on target capabilities and network configuration
- **Network Tuning**: Consider TCP window size, MTU, and network buffer settings

## Network URL Format

The iSCSI backend uses standard iSCSI URL format:

**Basic Format**:
```
iscsi://[<username>[%<password>]@]<host>[:<port>]/<target-iqn>/<lun>
```

**Components**:
- **Protocol**: `iscsi://` (standard iSCSI protocol identifier)
- **Authentication**: Optional `username%password@` for CHAP authentication
- **Host/Port**: Target IP address and optional port (default 3260)
- **Target IQN**: iSCSI Qualified Name of the target
- **LUN**: Logical Unit Number (typically 0 for single-LUN targets)

**Examples**:
- `iscsi://10.0.0.100/iqn.2019-06.io.target:disk1/0`
- `iscsi://user%pass@storage.example.com:3260/iqn.2019-06.com.example:target1/0`

## Limitations & Considerations

### Protocol Limitations
- **Network Dependency**: Performance and availability tied to network conditions
- **Latency Sensitivity**: Higher latency compared to local storage access
- **Authentication**: CHAP support depends on target configuration
- **Feature Support**: Advanced features depend on target capabilities

### Implementation Constraints
- **Single Connection**: One connection per bdev instance currently
- **Synchronous Discovery**: Connection establishment may block briefly
- **Error Recovery**: Limited automatic error recovery capabilities
- **Multipath**: Does not implement multipath failover at bdev level

### Operational Requirements
- **Network Connectivity**: Stable network connection to iSCSI target required
- **Target Compatibility**: iSCSI target must support required SCSI command set
- **Firewall Configuration**: iSCSI port (typically 3260) must be accessible
- **Authentication Setup**: CHAP credentials must match target configuration

## Code Navigation

**Primary Files**:
- `module/bdev/iscsi/bdev_iscsi.c` - Main implementation with connection management
- `module/bdev/iscsi/bdev_iscsi.h` - Public interface and structure definitions
- `module/bdev/iscsi/bdev_iscsi_rpc.c` - RPC command handlers for configuration
- `module/bdev/iscsi/Makefile` - Build configuration and libiscsi dependencies

**Key Functions**:
- `bdev_iscsi_submit_request()` - I/O submission to iSCSI target
- `bdev_iscsi_io_type_supported()` - Capability reporting with UNMAP detection
- `create_iscsi_lun()` - Target connection and LUN setup
- `bdev_iscsi_readcapacity16()` - Target capacity and feature discovery

**Dependencies**:
- **libiscsi**: Third-party iSCSI initiator library for protocol implementation
- **SCSI Low-Level**: SCSI command construction and parsing utilities