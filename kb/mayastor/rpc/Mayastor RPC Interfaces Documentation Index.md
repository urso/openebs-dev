---
title: Mayastor RPC Interfaces Documentation Index
type: note
permalink: mayastor/rpc/mayastor-rpc-interfaces-documentation-index
---

# Mayastor RPC Interfaces Documentation

This documentation covers the Remote Procedure Call (RPC) interfaces provided by Mayastor components for programmatic control and integration.


## Interface Comparison

| Interface | Component | Network | Port/Path | Primary Use |
|-----------|-----------|---------|-----------|-------------|
| gRPC | IO-Engine | ✅ TCP | `:10124` | Control plane integration |
| JSON RPC | IO-Engine | ❌ Unix | `/var/tmp/mayastor.sock` | SPDK method access |
| REST API | Controller | ✅ HTTP/HTTPS | `:8080`/`:8081` | User-facing management |

## Getting Started

### For Control Plane Integration
Start with **[[Mayastor IO-Engine gRPC API Reference]]** to understand the primary network interface for managing storage pools, replicas, and nexus volumes.

### For User-Facing Management
Use **[[Mayastor Controller REST API Reference]]** for HTTP-based management operations with OpenAPI documentation.

### For SPDK Method Access
Use **[[Mayastor IO-Engine JSON RPC API Reference]]** when you need direct access to SPDK functionality or custom io-engine methods.


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


---

*Last updated: 2025-08-19*