---
title: Mayastor RPC Architecture Overview
type: note
permalink: mayastor/rpc/mayastor-rpc-architecture-overview
---

# Mayastor RPC Architecture Overview

This document provides a technical deep-dive into the Remote Procedure Call (RPC) architecture used by Mayastor components, explaining how the different interfaces work together.

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                            Mayastor RPC Architecture                                │
├─────────────────────┬─────────────────────┬─────────────────────────────────────────┤
│   Mayastor          │   Mayastor          │   SPDK Framework                        │
│   Controller        │   IO-Engine         │                                         │
│                     │                     │                                         │
│ ┌─────────────────┐ │ ┌─────────────────┐ │ ┌─────────────────┐ ┌─────────────────┐ │
│ │   REST API      │ │ │   gRPC Server   │ │ │   JSON RPC      │ │   Native API    │ │
│ │                 │ │ │                 │ │ │   Server        │ │                 │ │
│ │ • HTTP/HTTPS    │ │ │ • TCP :10124    │ │ │                 │ │ • Direct Calls  │ │
│ │ • JWT Auth      │ │ │ • Multiple APIs │ │ │ • Unix Socket   │ │ • C/C++         │ │
│ │ • OpenAPI       │ │ │ • Protocol Buf  │ │ │ • JSON 2.0      │ │ • Performance   │ │
│ └─────────────────┘ │ └─────────────────┘ │ └─────────────────┘ └─────────────────┘ │
│         │           │         │           │         ▲                     ▲         │
└─────────┼───────────┴─────────┼───────────┴─────────┼─────────────────────┼─────────┘
          │                     │                     │                     │
          │                     │ ┌─────────────────┐ │                     │
          │                     └─│   JsonService   │─┘                     │
          │                       │   (gRPC→JSON)   │                       │
          │                       └─────────────────┘                       │
          │                                                                 │
          └─────────────────── Network Clients ──────────────────────────────┘
```

## Component Breakdown

### 1. Mayastor IO-Engine gRPC Server

**Location**: `io-engine/src/grpc/server.rs`

The gRPC server is the primary network interface for io-engine, built using the [tonic](https://github.com/hyperium/tonic) framework.

#### Server Initialization
```rust
pub async fn run(
    node_name: &str,
    node_nqn: &Option<String>, 
    endpoint: std::net::SocketAddr,
    rpc_addr: String,
    api_versions: Vec<ApiVersion>,
) -> Result<(), ()>
```

The server:
1. Binds to the configured network endpoint (default `:10124`)
2. Registers multiple service implementations based on API versions
3. Handles concurrent requests using tokio async runtime
4. Provides service reflection for client discovery

#### Service Registration
```rust
let svc = Server::builder()
    .add_optional_service(enable_v1.map(|_| v1::pool::PoolRpcServer::new(pool_service)))
    .add_optional_service(enable_v1.map(|_| v1::replica::ReplicaRpcServer::new(replica_service)))
    .add_optional_service(enable_v1.map(|_| v1::nexus::NexusRpcServer::new(nexus_service)))
    .add_optional_service(enable_v1.map(|_| v1::json::JsonRpcServer::new(json_service)))
    // ... more services
    .serve(endpoint);
```

### 2. JSON RPC Interface & SPDK Integration

**Location**: `io-engine/src/jsonrpc.rs`

The JSON RPC system provides two access patterns:

#### Direct SPDK Integration
```rust
pub fn jsonrpc_register<P, H, R, E>(name: &str, handler: H)
where
    H: 'static + Fn(P) -> Pin<Box<dyn Future<Output = Result<R, E>>>>,
    P: 'static + for<'de> Deserialize<'de>,
    R: Serialize,
    E: RpcErrorCode + std::error::Error,
{
    // Register with SPDK's RPC system
    unsafe {
        spdk_rpc_register_method(
            name.as_ptr(),
            Some(jsonrpc_handler::<H, P, R, E>),
            handler_ptr,
            SPDK_RPC_RUNTIME,
        );
    }
}
```

#### Custom Method Registration
io-engine registers two custom methods:
- `mayastor_config_export` - Configuration management
- `nexus_share` - Block device sharing

### 3. gRPC to JSON RPC Bridge

**Location**: `io-engine/src/grpc/v1/json.rs`

The JsonService acts as a protocol translator:

```rust
#[tonic::async_trait]
impl JsonRpc for JsonService {
    async fn json_rpc_call(&self, request: Request<JsonRpcRequest>) -> GrpcResult<JsonRpcResponse> {
        let args = request.into_inner();
        let result = self.spdk_jsonrpc_call(&args.method, empty_as_none(&args.params)).await?;
        Ok(Response::new(JsonRpcResponse { result }))
    }
}
```

#### Protocol Translation Flow
1. **gRPC Request**: Client sends `JsonRpcRequest{method, params}`
2. **Deserialization**: Extract method name and JSON parameters
3. **Socket Connection**: Create Unix socket connection to `/var/tmp/mayastor.sock`
4. **JSON RPC Call**: Format and send JSON RPC 2.0 request
5. **Response Processing**: Parse SPDK response and return via gRPC

### 4. Data Flow Analysis

#### Pool Creation Example
```
1. Control Plane          2. gRPC Server           3. Pool Service          4. SPDK/LVS
   │                         │                        │                        │
   ├─ CreatePoolRequest ────►│                        │                        │
   │  {                      │                        │                        │
   │    name: "pool0"        ├─ Deserialize ─────────►│                        │
   │    disks: ["/dev/sdb"]  │                        │                        │
   │  }                      │                        ├─ Validate params      │
   │                         │                        ├─ Create LVS ──────────►│
   │                         │                        │                        ├─ spdk_lvs_create()
   │                         │                        │◄─ LVS handle ──────────┤
   │◄─ Pool response ────────┤◄─ Serialize response ──┤                        │
   │  {                      │                        │                        │
   │    uuid: "..."          │                        │                        │
   │    state: "Online"      │                        │                        │
   │  }                      │                        │                        │
```

#### JSON RPC Proxy Example
```
1. Control Plane          2. JsonService           3. Unix Socket          4. SPDK RPC
   │                         │                        │                        │
   ├─ JsonRpcRequest ───────►│                        │                        │
   │  {                      │                        │                        │
   │    method: "bdev_get_   ├─ Extract method ─────►│                        │
   │           bdevs"        │    and params          │                        │
   │    params: "{}"         │                        │                        │
   │  }                      ├─ UnixStream::connect   │                        │
   │                         │    (/var/tmp/mayastor  │                        │
   │                         │     .sock) ───────────►│                        │
   │                         │                        ├─ JSON RPC 2.0 ───────►│
   │                         │                        │  {                     │
   │                         │                        │    "method": "bdev_    │
   │                         │                        │              get_bdevs"│
   │                         │                        │    "id": 1             │
   │                         │                        │  }                     │
   │                         │                        │◄─ JSON Response ──────┤
   │◄─ JsonRpcResponse ──────┤◄─ Parse and format ────┤                        │
   │  {                      │                        │                        │
   │    result: "[...]"      │                        │                        │
   │  }                      │                        │                        │
```

## Threading and Concurrency

### SPDK Event Framework Integration
```rust
// RPC handlers run on SPDK's master reactor
Reactors::master().send_future(fut);
```

io-engine integrates with SPDK's single-threaded event framework:
- **Master Reactor**: Handles RPC requests and SPDK operations
- **Worker Reactors**: Handle I/O operations (per CPU core)
- **Thread Safety**: All RPC operations are serialized through the master reactor

### Async/Await Support
```rust
pub fn jsonrpc_register<P, H, R, E>(name: &str, handler: H)
where
    H: 'static + Fn(P) -> Pin<Box<dyn Future<Output = Result<R, E>>>>,
```

The JSON RPC framework supports async handlers, allowing:
- Non-blocking I/O operations
- Concurrent request handling
- Integration with Rust async ecosystem

## Error Handling Architecture

### Error Translation Layers
```
gRPC Status Codes  ←→  JSON RPC Errors  ←→  SPDK Return Codes
     │                        │                      │
     ├─ INVALID_ARGUMENT      ├─ -32602              ├─ -EINVAL
     ├─ NOT_FOUND             ├─ -2 (ENOENT)        ├─ -ENOENT  
     ├─ ALREADY_EXISTS        ├─ -17 (EEXIST)       ├─ -EEXIST
     └─ INTERNAL              └─ -32603              └─ Other errors
```

### Error Propagation
1. **SPDK Level**: Native SPDK functions return error codes
2. **JSON RPC Level**: Errors mapped to JSON RPC 2.0 error format
3. **gRPC Level**: JSON RPC errors translated to gRPC status codes
4. **Client Level**: Clients receive appropriate protocol-specific errors

## Performance Characteristics

### gRPC Server Performance
- **Protocol**: HTTP/2 with Protocol Buffers
- **Concurrency**: Async request handling with tokio
- **Connection**: Persistent connections with multiplexing
- **Overhead**: ~10-50μs per request (excluding business logic)

### JSON RPC Performance  
- **Protocol**: JSON over Unix domain sockets
- **Connection**: Per-request socket creation/teardown
- **Serialization**: JSON parsing overhead
- **Overhead**: ~100-500μs per request (including socket setup)

### Recommendations
- **High Frequency**: Use gRPC native services (Pool, Replica, Nexus)
- **SPDK Access**: Use JSON RPC via gRPC proxy for convenience
- **Low Latency**: Consider direct SPDK native API for critical paths

## Security Architecture

### Current Security Model
- **gRPC**: No authentication (relies on network-level security)
- **JSON RPC**: Unix socket permissions only
- **Access Control**: Kubernetes network policies and RBAC

### Security Boundaries
```
Network Boundary          Process Boundary         Kernel Boundary
      │                        │                        │
      ├─ gRPC :10124          ├─ JSON RPC Socket      ├─ SPDK Userspace
      │  (Network exposed)     │  (Process-local)      │  (Direct hardware)
      │                        │                        │
      └─ Firewall/NetPol      └─ File permissions     └─ Kernel drivers
```

## Future Enhancements

### Planned Improvements
1. **TLS/mTLS**: gRPC server authentication
2. **Rate Limiting**: Per-client request throttling  
3. **Metrics**: Detailed RPC performance monitoring
4. **Streaming**: Support for long-running operations
5. **Health Checks**: Built-in health/readiness endpoints

### Extensibility Points
- **New gRPC Services**: Add services via server builder
- **Custom JSON Methods**: Register via `jsonrpc_register()`
- **Middleware**: Request/response interceptors
- **Protocol Buffers**: Version-aware API evolution

## See Also

- [[Mayastor IO-Engine gRPC API Reference]] - Service definitions
- [[Mayastor IO-Engine JSON RPC API Reference]] - Method details
- [[Mayastor Controller REST API Reference]] - HTTP interface details
- [SPDK Documentation](https://spdk.io/doc/) - Underlying framework details

---

*Architecture based on io-engine source code analysis - components may evolve*