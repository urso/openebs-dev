---
title: SPDK-RS Overview
type: note
permalink: spdk-rs/spdk-rs-overview
---

# SPDK-RS Overview

SPDK-RS is a comprehensive Rust wrapper for the SPDK (Storage Performance Development Kit) C library that provides higher-level, memory-safe abstractions for building high-performance storage applications.

## What SPDK-RS Provides

SPDK-RS goes significantly beyond basic FFI bindings, offering:

### Architecture Layers
1. **FFI Bindings** - Auto-generated with bindgen from SPDK headers
2. **Safe Wrappers** - Type-safe Rust wrappers around SPDK structures  
3. **High-Level APIs** - Ergonomic abstractions with async/await support

### Key Abstractions

**Block Device Operations**
- `Bdev<T>` - Safe wrapper around `spdk_bdev` with generic type safety
- `BdevBuilder` - Builder pattern for creating block devices
- `BdevDesc` - Block device descriptors with RAII cleanup
- Links to: [[SPDK Bdev Overview]] for underlying concepts

**Memory Management**
- `DmaBuf` - Safe DMA buffer management with alignment guarantees
- Zero-copy I/O operations with `IoVec` wrappers
- Automatic cleanup and memory safety
- Links to: [[SPDK Memory Overview]] for memory architecture

**Threading & Concurrency**
- `Thread` - Safe wrapper around SPDK threads with lifecycle management
- `Poller` - Event-driven polling with pause/resume support
- `CurrentThreadGuard` - RAII for thread context switching
- Links to: [[SPDK Coding Patterns for Development]] for reactor concepts

**Async/Await Integration**
- Futures-based async operations using oneshot channels
- `BdevAsyncCallContext` for bridging callback-based SPDK to async Rust
- Non-blocking I/O patterns

## OpenEBS/Mayastor Context

SPDK-RS is specifically designed for the **OpenEBS ecosystem**, particularly the **Mayastor** family of storage products:

- Uses OpenEBS-patched SPDK versions (e.g., `v24.05.x-mayastor` branches)
- Tailored for OpenEBS storage controller requirements
- Tested against OpenEBS-specific SPDK configurations

## Platform Support

- **Operating System**: Linux only
- **Architectures**: x86_64 (Nehalem+) and aarch64 (with crypto)
- **Build System**: Nix for reproducible builds and dependency management

## When to Use SPDK-RS

### Choose SPDK-RS When:
- Building Rust applications that need SPDK performance
- Requiring memory safety guarantees in storage code
- Working within the OpenEBS/Mayastor ecosystem
- Need async/await patterns with SPDK operations
- Want ergonomic APIs with builder patterns

### Use Raw SPDK When:
- Maximum performance is critical (no abstraction overhead)
- Working with non-OpenEBS SPDK versions
- Need features not yet wrapped by spdk-rs
- Building C/C++ applications

## Architecture Overview

```
Rust Application
       ↓
SPDK-RS High-Level APIs (Bdev, Thread, Poller)
       ↓
SPDK-RS Safe Wrappers (Memory Safety, RAII)
       ↓
Auto-Generated FFI Bindings (bindgen)
       ↓
OpenEBS SPDK C Library
       ↓
DPDK & System Libraries
```

The layered approach ensures both safety and performance while maintaining compatibility with SPDK's event-driven architecture.

## Getting Started

For development environment setup, see [[SPDK-RS Build Environment]].

For understanding the threading model, see [[SPDK-RS Threading Model]].

For memory safety patterns, see [[SPDK-RS Safe Wrappers]].

For practical usage examples, see [[SPDK-RS Integration Patterns]].