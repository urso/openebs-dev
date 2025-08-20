---
title: Mayastor IO-Engine JSON RPC API Reference
type: note
permalink: mayastor/rpc/mayastor-io-engine-json-rpc-api-reference
---

# Mayastor IO-Engine JSON RPC API Reference

The Mayastor IO-Engine provides JSON RPC access to SPDK functionality and custom methods. This interface can be accessed directly via Unix socket or remotely via the gRPC JsonService proxy.

## Access Methods

### 1. Direct Unix Socket Access
- **Socket Path**: `/var/tmp/mayastor.sock`
- **Protocol**: JSON RPC 2.0 over Unix domain socket
- **Network**: Local only (no network access)

### 2. gRPC Proxy Access {#grpc-proxy}
- **Service**: `v1.json.JsonRpc`
- **Method**: `JsonRpcCall()`
- **Network**: Available via gRPC server at `:10124`
- **Use Case**: Remote access to JSON RPC methods

## Configuration

### Unix Socket Path
The socket path is configurable via command line:
```bash
io-engine -r /custom/path/mayastor.sock
# Default: /var/tmp/mayastor.sock
```

### gRPC Proxy Setup
The JsonService is automatically available when gRPC API v1 is enabled:
```bash
io-engine --api-versions V1 --grpc-port 10124
```

## Available Methods

### SPDK Methods (Proxied)

All standard SPDK JSON RPC methods are available. Common examples:

#### Block Device Operations
```json
{
  "method": "bdev_get_bdevs",
  "params": {},
  "id": 1,
  "jsonrpc": "2.0"
}
```

#### NVMe-oF Target Operations
```json
{
  "method": "nvmf_create_subsystem",
  "params": {
    "nqn": "nqn.2019-05.io.openebs:example",
    "allow_any_host": true
  },
  "id": 1,
  "jsonrpc": "2.0"
}
```

#### NVMe-oF Transport Operations
```json
{
  "method": "nvmf_create_transport", 
  "params": {
    "trtype": "TCP"
  },
  "id": 1,
  "jsonrpc": "2.0"
}
```

For a complete list of SPDK methods, refer to the [SPDK JSON RPC documentation](https://spdk.io/doc/jsonrpc.html).

### Custom IO-Engine Methods

#### `mayastor_config_export`
Exports the current io-engine configuration to disk.

**Parameters**: None
**Returns**: Success confirmation

```json
{
  "method": "mayastor_config_export",
  "params": {},
  "id": 1,
  "jsonrpc": "2.0"
}
```

#### `nexus_share`
Shares a block device over NVMe-oF protocol.

**Parameters**:
- `name` (string): Name of the bdev/nexus to share
- `protocol` (string): Protocol type (currently only "nvmf" supported)
- `cntlid_min` (u16): Minimum controller ID
- `cntlid_max` (u16): Maximum controller ID

**Returns**: Share URI

```json
{
  "method": "nexus_share",
  "params": {
    "name": "my-nexus",
    "protocol": "nvmf",
    "cntlid_min": 1,
    "cntlid_max": 100
  },
  "id": 1,
  "jsonrpc": "2.0"
}
```

## Usage Examples

### Direct Unix Socket (Python)
```python
import json
import socket

def json_rpc_call(method, params=None):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect('/var/tmp/mayastor.sock')
    
    request = {
        "method": method,
        "params": params or {},
        "id": 1,
        "jsonrpc": "2.0"
    }
    
    sock.send(json.dumps(request).encode())
    response = sock.recv(4096)
    sock.close()
    
    return json.loads(response.decode())

# List all block devices
result = json_rpc_call("bdev_get_bdevs")
print(result)
```

### gRPC Proxy (Go)
```go
import (
    "context"
    "google.golang.org/grpc"
    jsonv1 "mayastor/api/v1/json"
)

conn, err := grpc.Dial("io-engine:10124", grpc.WithInsecure())
client := jsonv1.NewJsonRpcClient(conn)

response, err := client.JsonRpcCall(context.Background(), &jsonv1.JsonRpcRequest{
    Method: "bdev_get_bdevs",
    Params: "{}",
})
```

### gRPC Proxy (curl via grpc-gateway)
If grpc-gateway is configured:
```bash
curl -X POST http://io-engine:8080/v1/json/rpc \
  -H "Content-Type: application/json" \
  -d '{
    "method": "bdev_get_bdevs",
    "params": "{}"
  }'
```

## Protocol Translation

The gRPC JsonService performs protocol translation:

```
gRPC JsonRpcRequest {     JSON RPC 2.0 {
  method: "bdev_get_bdevs"  "method": "bdev_get_bdevs",
  params: "{}"          →   "params": {},
}                         "id": 1,
                          "jsonrpc": "2.0"
                        }
```

## Error Handling

### JSON RPC Errors
Standard JSON RPC 2.0 error format:
```json
{
  "error": {
    "code": -32600,
    "message": "Invalid Request"
  },
  "id": 1,
  "jsonrpc": "2.0"
}
```

### Common Error Codes
- `-32700`: Parse error
- `-32600`: Invalid Request  
- `-32601`: Method not found
- `-32602`: Invalid params
- `-32603`: Internal error
- `-2` (ENOENT): Resource not found
- `-17` (EEXIST): Resource already exists

### gRPC Proxy Errors
When using gRPC proxy, JSON RPC errors are wrapped in gRPC status:
```
rpc error: code = Internal desc = JSON RPC error: Method not found
```

## Architecture Flow

```
┌─────────────────────┐       ┌─────────────────────┐       ┌─────────────────────┐
│   Client            │ gRPC  │   IO-Engine         │ Unix  │   SPDK              │
│                     │───────│                     │ Sock  │                     │
│ JsonRpcRequest      │ :10124│ JsonService         │───────│ JSON RPC Server     │
│ {                   │       │ json_rpc_call()     │       │ /var/tmp/mayastor.  │
│   method: "...",    │       │   │                 │       │ sock                │
│   params: "..."     │       │   └─spdk_jsonrpc_   │       │                     │
│ }                   │       │     call()          │       │ • SPDK methods      │
└─────────────────────┘       │     └─UnixStream::  │       │ • Custom methods    │
                              │       connect()     │       │                     │
                              └─────────────────────┘       └─────────────────────┘
```

## Security Considerations

- **Unix Socket**: Local access only, protected by filesystem permissions
- **gRPC Proxy**: Inherits security model of gRPC server (currently no authentication)
- **SPDK Methods**: Direct access to low-level storage operations - use carefully

## Troubleshooting

### Common Issues
1. **Socket not found**: Check if io-engine is running and socket path is correct
2. **Permission denied**: Ensure client has read/write access to socket
3. **Method not found**: Verify SPDK method name and ensure required subsystem is initialized

### Debugging
Enable JSON RPC tracing:
```bash
io-engine --log-level=trace
# Look for JSON RPC messages in logs
```

## See Also

- [Mayastor IO-Engine gRPC API Reference](mayastor-io-engine-g-rpc-api-reference#jsonservice) - JsonService details
- [Mayastor RPC Architecture Overview](mayastor-rpc-architecture-overview) - Protocol translation internals
- [SPDK JSON RPC Documentation](https://spdk.io/doc/jsonrpc.html) - Complete SPDK method reference

---

*Implementation: `io-engine/src/jsonrpc.rs` and `io-engine/src/grpc/v1/json.rs`*