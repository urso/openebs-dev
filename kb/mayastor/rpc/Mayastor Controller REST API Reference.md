---
title: Mayastor Controller REST API Reference
type: note
permalink: mayastor/rpc/mayastor-controller-rest-api-reference
---
s
# Mayastor Controller REST API Reference

The Mayastor Controller provides a REST API for high-level storage management operations. This service acts as the primary HTTP interface for users, administrators, and management tools.

## Implementation

**Framework**: Actix-web (Rust)  
**Location**: `controller/control-plane/rest/`  
**Binary**: `rest`

## Configuration

### Network Settings
- **HTTPS Port**: `8080` (default)
- **HTTP Port**: Optional (e.g., `8081`)
- **Certificates**: Supports custom certs or dummy certificates for development

### Command Line Options
```bash
# Production mode with authentication
rest --https [::]:8080 \
     --cert-file server.crt \
     --key-file server.key \
     --jwk public.jwk

# Development mode
rest --https [::]:8080 \
     --http [::]:8081 \
     --dummy-certificates \
     --no-auth
```

### Key Configuration Parameters
- `--core-grpc` - Connect to control plane core (default: `https://core:50051`)
- `--json-grpc` - Optional connection to JSON gRPC service
- `--jwk <path>` - JSON Web Key file for JWT authentication
- `--no-auth` - Disable authentication (development only)
- `--dummy-certificates` - Use embedded test certificates
- `--workers <num>` - Number of worker threads (default: CPU count)
- `--request-timeout` - Default timeout for backend requests

## Architecture

The REST API acts as a gateway between HTTP clients and the control plane:

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│ HTTP Clients    │    │ Controller      │    │ Control Plane   │
│ • curl          │    │ REST Service    │    │ Core            │
│ • Web UIs       │────│                 │────│                 │
│ • Tools         │HTTP│ • Actix-web     │gRPC│ • Agent Core    │
│                 │    │ • JWT Auth      │    │ • Storage Logic │
└─────────────────┘    └─────────────────┘    └─────────────────┘
                                ↓ (optional)
                       ┌─────────────────┐
                       │ JSON gRPC       │
                       │ (SPDK Access)   │
                       └─────────────────┘
```

## API Specification

### OpenAPI Documentation
The REST API is fully documented with OpenAPI 3.0.3:

- **Specification**: Auto-generated from code
- **Location**: `control-plane/rest/openapi-specs/v0_api_spec.yaml`
- **Base URL**: `/v0`
- **Live Spec**: `GET /v0/api/spec` (when service is running)

### Main Resource Types
Based on the OpenAPI specification, the API provides endpoints for:

- **Nodes** - IO-Engine node management
- **Pools** - Storage pool operations  
- **Volumes** - Volume lifecycle management
- **Replicas** - Replica management
- **Nexuses** - Nexus operations
- **Snapshots** - Snapshot functionality
- **Block Devices** - Device information
- **Children** - Nexus child management

## Authentication

### JWT Authentication
```bash
# With authentication
rest --jwk /path/to/public.jwk --cert-file server.crt --key-file server.key

# Headers required
Authorization: Bearer <jwt_token>
```

### Development Mode
```bash  
# No authentication
rest --no-auth --dummy-certificates
```

## Basic Usage

### Health Endpoints
```bash
# Check if service is running
curl -k https://localhost:8080/liveness

# Check if service and backend are ready
curl -k https://localhost:8080/readiness
```

### API Discovery
```bash
# Get OpenAPI specification
curl -k https://localhost:8080/v0/api/spec

# Example resource listing (with auth)
curl -k -H "Authorization: Bearer $TOKEN" https://localhost:8080/v0/nodes
```

### Development Example
```bash
# In development mode (no auth required)
curl -k https://localhost:8080/v0/nodes
# OR via HTTP port if configured
curl http://localhost:8081/v0/nodes
```

## Integration Points

### Control Plane Connection
The REST service connects to the control plane core via gRPC:
- Default endpoint: `https://core:50051`
- Configurable via `--core-grpc` flag
- Handles service discovery and backend communication

### Optional JSON gRPC Access
If configured with `--json-grpc`, provides HTTP access to SPDK JSON RPC methods:
- Allows REST clients to execute low-level SPDK operations
- Bridges HTTP requests to JSON RPC calls
- Useful for advanced management scenarios

## Error Handling

Standard HTTP status codes are used:
- `2xx` - Success
- `4xx` - Client errors (bad requests, auth failures, not found)
- `5xx` - Server errors (backend failures, internal errors)

Error responses include structured JSON with error details.

## Development Setup

### Test Deployment
The deployer shows typical development configuration:
```bash
rest --dummy-certificates \
     --https rest:8080 \
     --http rest:8081 \
     --workers=1 \
     --no-auth
```

### Health Check Verification
```bash
# Wait for service to be ready
curl -k http://localhost:8081/v0/api/spec
```

## See Also

- [Mayastor IO-Engine gRPC API Reference](mayastor-io-engine-g-rpc-api-reference) - Backend storage operations
- [Mayastor IO-Engine JSON RPC API Reference](mayastor-io-engine-json-rpc-api-reference) - SPDK method access  
- [Mayastor RPC Architecture Overview](mayastor-rpc-architecture-overview) - System design overview
- [OpenAPI Specification](https://github.com/openebs/mayastor/blob/develop/controller/control-plane/rest/openapi-specs/v0_api_spec.yaml) - Complete API reference

---

*Implementation: Actix-web service in `controller/control-plane/rest/`*