---
title: OpenAPI Quick Reference
type: note
permalink: development/mayastor-controller/open-api-quick-reference
---

# OpenAPI Quick Reference

## TL;DR

OpenAPI specs in `v0_api_spec.yaml` → `generate-openapi-bindings.sh` → Rust bindings in `openapi/` crate. Edit spec, run generator, import in components.

## File Map

| Purpose | Location | 
|---------|----------|
| **Source Spec** | `mayastor/controller/control-plane/rest/openapi-specs/v0_api_spec.yaml` |
| **Generator** | `mayastor/controller/scripts/rust/generate-openapi-bindings.sh` |
| **Generated Crate** | `mayastor/controller/openapi/` |
| **Build Integration** | `mayastor/controller/openapi/build.rs:4-7` |
| **Component Access** | `*/src/types/v0/openapi.rs` (re-exports) |

## Common Tasks

### Add New Endpoint
1. Edit spec: `v0_api_spec.yaml` (add to `paths:` section)
2. Regenerate: `./scripts/rust/generate-openapi-bindings.sh`
3. Import: Use existing `openapi.rs` re-exports in components

### Regenerate Bindings
```bash
cd mayastor/controller
./scripts/rust/generate-openapi-bindings.sh
```

### Add to Component
```toml
# Cargo.toml
openapi = { path = "../openapi", features = ["tower-client", "rustls_ring"] }
```

```rust
// src/types/v0/openapi.rs
pub use openapi::{apis, clients, models, tower};
```

## Key Script Flags

| Flag | Purpose |
|------|---------|
| `--skip-md5-same` | Skip if generated content unchanged |
| `--spec-changes` | Only regenerate if spec file changed |
| `--skip-git-diff` | Skip git diff check (for build scripts) |
| `--if-rev-changed` | Only run if `paperclip-ng` version changed |

## Generated Crate Features

| Feature | Purpose | Dependencies |
|---------|---------|--------------|
| `tower-client-rls` | Tower HTTP client with rustls | `tower`, `hyper`, `rustls` |
| `actix-server` | Actix web server bindings | `actix-web` |
| `tower-trace` | OpenTelemetry tracing | `tracing-opentelemetry` |

## Automatic Regeneration

Build-time triggers (`controller/openapi/build.rs:16-17`):
- `paperclip-ng` tool changes
- Files in `openapi-specs/` change  
- Building `openapi` crate

## Related Docs

- [[Mayastor Controller REST API Reference]] - API usage
- [[Mayastor Controller Test Architecture]]] - Testing setup