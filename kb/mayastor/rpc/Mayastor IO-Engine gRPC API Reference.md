---
title: Mayastor IO-Engine gRPC API Reference
type: note
permalink: mayastor/rpc/mayastor-io-engine-g-rpc-api-reference
---

# Mayastor IO-Engine gRPC API Reference

The Mayastor IO-Engine provides a comprehensive gRPC API for storage management operations. This is the primary network interface used by control planes and management systems.

## Configuration

### Network Settings
- **Default port**: `10124`
- **Default address**: `[::]` (all interfaces)
- **Protocol**: TCP/IP (network-accessible)

### Command Line Options
```bash
io-engine --grpc-ip 0.0.0.0 --grpc-port 10124
# OR (legacy)
io-engine -g 0.0.0.0:10124
```

### Environment Variables
The gRPC endpoint can be configured via command line arguments as shown above.

## API Versions

The io-engine supports both v0 (legacy) and v1 APIs simultaneously. API version is controlled by the `--api-versions` flag.

```bash
io-engine --api-versions V0,V1  # Enable both versions
io-engine --api-versions V1     # Enable only v1 (recommended)
```

## Available Services

### v1 API Services (Recommended)

#### PoolService (`v1.pool.PoolRpc`)
Manages storage pools built on top of block devices.

**Key Methods:**
- `CreatePool()` - Create a new storage pool
- `ListPools()` - List all pools
- `DestroyPool()` - Remove a storage pool
- `ImportPool()` - Import an existing pool

**Example:**
```protobuf
service PoolRpc {
  rpc CreatePool(CreatePoolRequest) returns (Pool);
  rpc ListPools(ListPoolsRequest) returns (ListPoolsResponse);
  rpc DestroyPool(DestroyPoolRequest) returns (google.protobuf.Empty);
}
```

#### ReplicaService (`v1.replica.ReplicaRpc`)
Manages data replicas within pools.

**Key Methods:**
- `CreateReplica()` - Create a new replica
- `ListReplicas()` - List all replicas
- `DestroyReplica()` - Remove a replica
- `ShareReplica()` - Share replica over NVMe-oF
- `UnshareReplica()` - Remove NVMe-oF sharing

#### NexusService (`v1.nexus.NexusRpc`)
Manages nexus volumes that aggregate replicas.

**Key Methods:**
- `CreateNexus()` - Create a nexus volume
- `ListNexuses()` - List all nexuses
- `DestroyNexus()` - Remove a nexus
- `AddChild()` - Add replica as child
- `RemoveChild()` - Remove replica child
- `PublishNexus()` - Expose nexus over NVMe-oF

#### HostService (`v1.host.HostRpc`)
Provides host and node information.

**Key Methods:**
- `GetMayastorInfo()` - Get io-engine instance info
- `Register()` - Register with control plane

#### JsonService (`v1.json.JsonRpc`) 
Proxy for SPDK JSON RPC methods over gRPC.

**Key Methods:**
- `JsonRpcCall()` - Execute SPDK RPC method

**See:** [Mayastor IO-Engine JSON RPC API](mayastor-io-engine-jsonrpc-api#grpc-proxy) for details.

#### BdevService (`v1.bdev.BdevRpc`)
Block device management operations.

#### SnapshotService (`v1.snapshot.SnapshotRpc`)
Snapshot creation and management.

#### StatsService (`v1.stats.StatsRpc`)
Performance statistics and metrics.

#### TestService (`v1.test.TestRpc`)
Testing and diagnostic utilities.

### v0 API Services (Legacy)

#### MayastorService (`v0.mayastor.Mayastor`)
Legacy unified service interface.

#### JsonRpcService (`v0.json_rpc.JsonRpc`)
Legacy JSON RPC proxy.

#### BdevService (`v0.bdev_rpc.BdevRpc`)
Legacy block device operations.

## Client Examples

### Go Client Example
```go
import (
    "context"
    "google.golang.org/grpc"
    poolv1 "mayastor/api/v1/pool"
)

conn, err := grpc.Dial("io-engine:10124", grpc.WithInsecure())
if err != nil {
    log.Fatal(err)
}
defer conn.Close()

client := poolv1.NewPoolRpcClient(conn)
response, err := client.ListPools(context.Background(), &poolv1.ListPoolsRequest{})
```

### Python Client Example
```python
import grpc
from mayastor.v1 import pool_pb2_grpc, pool_pb2

channel = grpc.insecure_channel('io-engine:10124')
client = pool_pb2_grpc.PoolRpcStub(channel)
response = client.ListPools(pool_pb2.ListPoolsRequest())
```

## Error Handling

All gRPC methods return standard gRPC status codes:
- `OK` - Success
- `INVALID_ARGUMENT` - Invalid parameters
- `NOT_FOUND` - Resource not found
- `ALREADY_EXISTS` - Resource already exists
- `INTERNAL` - Internal server error

## Security Considerations

The gRPC server currently does not implement authentication. It should be:
- Protected by network policies in Kubernetes
- Exposed only to trusted control plane components
- Not directly accessible from outside the cluster

## See Also

- [Mayastor IO-Engine JSON RPC API](mayastor-io-engine-jsonrpc-api) - SPDK method access
- [Mayastor RPC Deployment Guide](mayastor-rpc-deployment-guide) - Kubernetes setup
- [Mayastor RPC Architecture Overview](mayastor-rpc-architecture-overview) - Technical internals

---

*Generated from protobuf definitions in `utils/dependencies/apis/io-engine/protobuf/v1/`*