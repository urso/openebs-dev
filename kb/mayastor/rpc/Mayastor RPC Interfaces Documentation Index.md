---
title: Mayastor RPC Interfaces Documentation Index
type: note
permalink: mayastor/rpc/mayastor-rpc-interfaces-documentation-index
---

# Mayastor RPC Interfaces Documentation

This documentation covers the Remote Procedure Call (RPC) interfaces provided by Mayastor components for programmatic control and integration.

## Quick Reference

- **[Mayastor IO-Engine gRPC API](mayastor-io-engine-g-rpc-api-reference)** - Network-accessible service APIs for storage operations
- **[Mayastor IO-Engine JSON RPC API](mayastor-io-engine-json-rpc-api-reference)** - SPDK proxy and custom methods via Unix socket
- **[Mayastor Controller REST API](mayastor-controller-rest-api-reference)** - HTTP/HTTPS interface for storage management
- **[Mayastor RPC Architecture Overview](mayastor-rpc-architecture-overview)** - Technical deep-dive into RPC communication flow

## Interface Comparison

| Interface | Component | Network | Port/Path | Primary Use |
|-----------|-----------|---------|-----------|-------------|
| gRPC | IO-Engine | ✅ TCP | `:10124` | Control plane integration |
| JSON RPC | IO-Engine | ❌ Unix | `/var/tmp/mayastor.sock` | SPDK method access |
| REST API | Controller | ✅ HTTP/HTTPS | `:8080`/`:8081` | User-facing management |

## Getting Started

### For Control Plane Integration
Start with **[Mayastor IO-Engine gRPC API](mayastor-io-engine-g-rpc-api-reference)** to understand the primary network interface for managing storage pools, replicas, and nexus volumes.

### For User-Facing Management
Use **[Mayastor Controller REST API](mayastor-controller-rest-api-reference)** for HTTP-based management operations with OpenAPI documentation.

### For SPDK Method Access
Use **[Mayastor IO-Engine JSON RPC API](mayastor-io-engine-json-rpc-api-reference)** when you need direct access to SPDK functionality or custom io-engine methods.

### For Understanding Internals
Read **[Mayastor RPC Architecture Overview](mayastor-rpc-architecture-overview)** to understand how the different RPC interfaces work together.

## Component Architecture

```
┌─────────────────────┐    ┌─────────────────────┐    ┌─────────────────────┐
│   Mayastor          │    │   Mayastor          │    │   SPDK              │
│   Controller        │    │   IO-Engine         │    │   Framework         │
│                     │    │                     │    │                     │
│ ┌─────────────────┐ │    │ ┌─────────────────┐ │    │ ┌─────────────────┐ │
│ │   REST API      │ │    │ │   gRPC Server   │ │    │ │   JSON RPC      │ │
│ │   HTTP/HTTPS    │ │    │ │   TCP :10124    │ │    │ │   Unix Socket   │ │
│ │ :8080/:8081     │ │    │ │   Multiple APIs │ │    │ │   SPDK + Custom │ │
│ │   JWT Auth      │ │    │ │   Protocol Buf  │ │    │ │   Methods       │ │
│ └─────────────────┘ │    │ └─────────────────┘ │    │ └─────────────────┘ │
└─────────────────────┘    │ ┌─────────────────┐ │    └─────────────────────┘
          ▲                │ │   JsonService   │ │             ▲
          │                │ │   (gRPC→JSON)   │ │             │
          │                │ └─────────────────┘ │─────────────┘
          │                └─────────────────────┘
          │
    ┌─────────────┐
    │ HTTP Clients│
    │ • Web UIs   │
    │ • curl      │ 
    │ • Tools     │
    └─────────────┘
```

## Related Documentation

- [Mayastor Architecture Overview](../../architecture/mayastor-overview)
- [Kubernetes Integration Guide](../../kubernetes/integration-guide)

---

*Last updated: 2025-08-19*