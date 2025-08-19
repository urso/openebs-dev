---
title: SPDK Bdev RBD
type: note
permalink: spdk/bdev-backends/spdk-bdev-rbd
---

# SPDK Bdev RBD

## Overview

The RBD (RADOS Block Device) backend provides access to Ceph storage clusters, enabling SPDK applications to use distributed, highly available storage. RBD is the block storage interface for Ceph, offering features like thin provisioning, snapshots, and seamless integration with Ceph's distributed architecture.

**Key Capabilities:**
- **Distributed Storage**: Access to Ceph cluster's distributed block storage
- **High Availability**: Automatic replication and failure recovery through Ceph
- **Thin Provisioning**: Efficient storage allocation with UNMAP support
- **Read-Only Support**: Optional read-only access for safe data consumption
- **Advanced Operations**: Compare-and-write for atomic updates (librbd-dependent)
- **Cluster Management**: Support for multiple Ceph clusters and authentication

**When to Use:**
- Distributed storage environments using Ceph clusters
- High availability requirements with automatic failover
- Large-scale storage deployments requiring horizontal scaling
- Cloud-native storage with container orchestration
- Shared storage accessible from multiple SPDK applications

## Code References

**Function Table**: `module/bdev/rbd/bdev_rbd.c:1220-1227`
```c
static const struct spdk_bdev_fn_table rbd_fn_table = {
    .destruct           = bdev_rbd_destruct,
    .submit_request     = bdev_rbd_submit_request,
    .io_type_supported  = bdev_rbd_io_type_supported,
    .get_io_channel     = bdev_rbd_get_io_channel,
    .dump_info_json     = bdev_rbd_dump_info_json,
    .write_config_json  = bdev_rbd_write_config_json,
};
```

**Core Implementation**: `module/bdev/rbd/bdev_rbd.c`
- **I/O Support**: Lines 1196-1218 define supported operations with read-only check
- **Cluster Context**: Lines 26-35 manage Ceph cluster connection pooling
- **Image Structure**: Lines 37-64 define RBD image context and metadata
- **Advanced Features**: Conditional COMPARE_AND_WRITE support based on librbd version

**RPC Interface**: `module/bdev/rbd/bdev_rbd_rpc.c`
- **Creation RPC**: `bdev_rbd_create` for connecting to RBD images
- **Cluster Management**: `bdev_rbd_register_cluster` for authentication setup
- **Configuration**: Lines 12-22 define comprehensive JSON parameters

**Headers**: `module/bdev/rbd/bdev_rbd.h`
- **Public API**: RBD device creation and cluster management functions
- **Ceph Integration**: librbd and librados library interface definitions

## Configuration

### Basic RBD Connection
```json
{
  "method": "bdev_rbd_create",
  "params": {
    "name": "rbd0",
    "pool_name": "rbd_pool",
    "rbd_name": "disk1",
    "block_size": 4096
  }
}
```

### With Authentication
```json
{
  "method": "bdev_rbd_register_cluster",
  "params": {
    "name": "ceph_cluster",
    "user_id": "admin",
    "config": {
      "mon_host": "192.168.1.10:6789,192.168.1.11:6789,192.168.1.12:6789",
      "key": "AQBsr8JXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX=="
    }
  }
},
{
  "method": "bdev_rbd_create",
  "params": {
    "name": "rbd_auth",
    "pool_name": "ssd_pool", 
    "rbd_name": "high_perf_disk",
    "cluster_name": "ceph_cluster",
    "user_id": "admin",
    "block_size": 4096
  }
}
```

### Read-Only Access
```json
{
  "method": "bdev_rbd_create",
  "params": {
    "name": "rbd_readonly",
    "pool_name": "backup_pool",
    "rbd_name": "archive_disk", 
    "read_only": true,
    "user_id": "readonly_user"
  }
}
```

### Multiple Images from Same Pool
```json
{
  "method": "bdev_rbd_create",
  "params": {
    "name": "rbd_disk1",
    "pool_name": "vm_pool",
    "rbd_name": "vm1_disk",
    "user_id": "vm_user"
  }
},
{
  "method": "bdev_rbd_create",
  "params": {
    "name": "rbd_disk2", 
    "pool_name": "vm_pool",
    "rbd_name": "vm2_disk",
    "user_id": "vm_user"
  }
}
```

## Supported I/O Operations

**Always Supported**:
- `READ`: Standard read operations via librbd
- `UNMAP`: Thin provisioning discard operations
- `FLUSH`: Cache flush operations
- `RESET`: Device reset operations

**Write Operations** (disabled in read-only mode):
- `WRITE`: Standard write operations 
- `WRITE_ZEROES`: Efficient zero-fill operations

**Advanced Operations** (library-dependent):
- `COMPARE_AND_WRITE`: Atomic compare-and-write operations
  - Requires `LIBRBD_SUPPORTS_COMPARE_AND_WRITE_IOVEC` in librbd
  - Provides data consistency for concurrent access scenarios

**Implementation Notes**:
- All operations use asynchronous librbd completion callbacks
- Read-only flag disables all write operations at I/O type check
- Connection pooling optimizes cluster resource usage

## Performance Characteristics

### Advantages
- **Distributed Performance**: Parallel access across multiple OSDs
- **Automatic Load Balancing**: Ceph's CRUSH algorithm distributes data
- **Scalability**: Performance scales with cluster size
- **High Availability**: No single point of failure
- **Caching**: Client-side and cluster-side caching benefits

### Performance Considerations
- **Network Dependency**: Performance affected by cluster network topology
- **Consistency Overhead**: Strong consistency guarantees add latency
- **Replication Factor**: Higher replication increases write latency
- **Client Resources**: librbd uses background threads for I/O processing

### Optimization Settings
- **Connection Pooling**: Shared cluster connections reduce setup overhead
- **Block Size**: Align with RBD object size (typically 4MB) for efficiency
- **Cache Configuration**: Tune librbd cache settings via config parameters
- **Network Tuning**: Optimize cluster and client network configurations

## Ceph Integration Features

### Authentication and Security
- **CephX Authentication**: Full support for Ceph's authentication system
- **User Management**: Per-image user credential support
- **Key Management**: Secure key storage and handling
- **Access Control**: Ceph's capability-based permission system

### Advanced Ceph Features
- **Thin Provisioning**: Efficient storage allocation with UNMAP
- **Snapshots**: Access to RBD snapshot functionality (via Ceph tools)
- **Cloning**: Support for RBD clone operations
- **Encryption**: Integration with Ceph's at-rest encryption

### Cluster Management
- **Multi-Cluster**: Support for connections to different Ceph clusters
- **Monitor Discovery**: Automatic monitor endpoint discovery
- **Failover**: Transparent handling of monitor failures
- **Connection Pooling**: Efficient resource sharing across RBD images

## Limitations & Considerations

### Library Dependencies
- **librbd**: Requires Ceph's librbd development libraries
- **librados**: Core RADOS library dependency  
- **Version Compatibility**: Feature availability depends on librbd version
- **Platform Support**: Linux primary platform, limited Windows support

### Operational Constraints
- **Network Requirements**: Stable network connectivity to Ceph cluster
- **Authentication Setup**: CephX keys and user configuration required
- **Monitor Availability**: At least one Ceph monitor must be accessible
- **Resource Usage**: librbd creates background threads for I/O processing

### Performance Considerations
- **Latency**: Network round-trips introduce higher latency than local storage
- **Throughput**: Limited by network bandwidth and cluster configuration
- **Consistency**: Strong consistency requirements may impact performance
- **Cache Behavior**: Client-side caching affects read performance patterns

## Code Navigation

**Primary Files**:
- `module/bdev/rbd/bdev_rbd.c` - Main implementation with Ceph integration
- `module/bdev/rbd/bdev_rbd.h` - Public interface and structure definitions
- `module/bdev/rbd/bdev_rbd_rpc.c` - RPC command handlers for management
- `module/bdev/rbd/Makefile` - Build configuration and Ceph library dependencies

**Key Functions**:
- `bdev_rbd_submit_request()` - I/O submission to librbd
- `bdev_rbd_io_type_supported()` - Capability reporting with read-only checks
- `create_rbd_disk()` - RBD image connection and setup
- `rbd_thread_set_cpumask()` - CPU affinity management for librbd threads

**Dependencies**:
- **librbd**: Ceph RBD block device library for image operations
- **librados**: Ceph RADOS distributed object store library for cluster access

## Build Configuration

```bash
# Enable RBD support with Ceph libraries
./configure --with-rbd

# Specify custom Ceph installation
./configure --with-rbd=/path/to/ceph/install

# Verify library availability
pkg-config --exists librbd librados
```