---
title: Mayastor Controller Test Architecture
type: note
permalink: development/mayastor-controller/mayastor-controller-test-architecture
---

# Mayastor Controller Test Architecture

## Overview
The Mayastor controller project has a comprehensive test strategy covering unit tests, integration tests, end-to-end tests, and BDD tests. Tests are self-contained and automatically manage cluster lifecycle.

The mayastor (io-engine) repository gives some instructions on how to use the tests ([doc/test-controller.md](https://github.com/openebs/mayastor/blob/develop/doc/test-controller.md))


## Test Categories

### 1. Core Agent Tests (`control-plane/agents/src/bin/core/tests/`)
Integration tests for the core control plane agent:
- **Volume tests**: Creation, deletion, resizing, snapshots, clones, capacity management, garbage collection, hotspare, switchover, affinity groups
- **Pool tests**: Pool management and operations
- **Node tests**: Node lifecycle and status management  
- **Nexus tests**: Nexus (storage target) creation and management
- **Rebuild tests**: Data rebuild functionality
- **Event tests**: Event handling and propagation
- **Controller tests**: Overall controller behavior
- **Watch tests**: Resource watching and change detection
- **App Node tests**: Application node management

### 2. IO-Engine Tests (`tests/io-engine/tests/`)
Direct integration tests with IO engine components:
- `nexus.rs`: Nexus creation with malloc devices, size validation
- `replicas.rs`: Replica management and operations
- `pools.rs`: Storage pool creation and management
- `rebuild.rs`: Data rebuild and recovery testing
- `reservations.rs`: Storage reservation management
- `allowed_hosts.rs`: Host access control
- `upgrade.rs`: Upgrade scenarios and compatibility

### 3. BDD Tests (`tests/bdd/`) - Behavior Driven Development
Python-based tests using pytest-bdd and Gherkin syntax:

**Volume Operations**: Create, delete, get, publish/unpublish, resize (online/offline), topology, observability, nexus operations, replica management

**Storage Management**: Pool creation, deletion, reconciliation, labeling, node operations, cordoning, draining, labeling, capacity management (thin provisioning)

**Snapshots**: Create, delete, list, garbage collection, restore operations, CSI controller capabilities

**High Availability**: Target switchover, robustness testing, cluster agent, core agent, node agent HA, path replacement scenarios

**CSI (Container Storage Interface)**: Controller and node plugin testing, identity service, capabilities, parameters, volume staging, publishing operations

**Advanced Features**: Volume groups, encryption, garbage collection, health probes, observability features, ANA (Asymmetric Namespace Access) validation

### 4. Other Test Types
- **REST API Tests** (`control-plane/rest/tests/`): v0 REST API endpoints
- **CSI Driver Tests**: Kubernetes CSI driver functionality
- **Plugin Tests**: kubectl plugin resources
- **Utility Tests**: etcd storage backend, NVMe discovery, dependency libraries

## Test Infrastructure

### Deployer and Deployer-Cluster
- **Deployer**: Tool for creating/managing local Docker-based test clusters
- **Deployer-cluster**: Test infrastructure providing `Cluster` struct, client abstractions, test helpers, CSI testing support
- Tests automatically manage cluster lifecycle - no manual deployer setup needed

### Test Execution Scripts
- `scripts/rust/test.sh`: Runs Rust tests for key packages (deployer-cluster, grpc, agents, rest, io-engine-tests, shutdown, csi-driver)
- `scripts/python/test.sh`: Runs Python BDD tests

## Key Points

### No Manual Setup Required
- Tests use `ClusterBuilder::builder().build().await` to automatically start clusters
- Clusters automatically cleaned up when tests complete
- Python BDD tests also manage clusters automatically via `deployer.py` module

### Manual Deployer Usage (Optional)
Only run deployer manually for:
1. Debugging specific components in isolation (`--no-rest` flag)
2. Interactive exploration of REST API
3. Development against persistent cluster

### Example Test Patterns
```rust
#[tokio::test]
async fn create_nexus_malloc() {
    let cluster = ClusterBuilder::builder().build().await.unwrap(); // Auto-starts cluster
    let nexus_client = cluster.grpc_client().nexus();
    // ... test operations ...
    // Cluster auto-cleanup on test completion
}
```

### Test Execution
```bash
# Run Rust integration tests
./scripts/rust/test.sh

# Run Python BDD tests  
./scripts/python/test.sh

# Debug with persistent cluster
CLEAN=false ./scripts/python/test.sh features/volume/create/test_feature.py -k test_name -x
```

## Architecture Benefits
- **Self-contained**: Each test manages its own environment
- **Reproducible**: Isolated clusters ensure consistent test conditions
- **Comprehensive**: Covers unit → integration → end-to-end → acceptance testing
- **Debuggable**: Easy to isolate components and preserve state for debugging