---
title: Mayastor HA Research Findings
type: note
permalink: docs/mayastor-ha-research-findings
---

# Mayastor High Availability - Complete Research Findings

## Overview
This document consolidates findings from both official design documentation and source code analysis of Mayastor's High Availability architecture.

## Sources Referenced

### Official Design Documentation
- **Primary HA Design**: `io-engine/doc/design/ha-failover.md` - Complete switchover architecture
- **Path Detection**: `io-engine/doc/design/ha-node-agent.md` - NVMe path failure detection mechanisms

### Source Code Locations
**Data Plane (io-engine)**:
- Nexus lifecycle APIs: `io-engine/src/grpc/v1/nexus.rs`
- NVMe reservations: `io-engine/src/bdev/nexus/nexus_child.rs:507-847`
- Reservation parameters: `io-engine/src/bdev/nexus/nexus_bdev.rs:84-213`
- ANA management: `io-engine/src/subsys/nvmf/subsystem.rs:699-956`
- I/O conflict handling: `io-engine/src/bdev/nexus/nexus_io.rs:685-696`

**Control Plane (controller)**:
- Node health monitoring: `controller/control-plane/agents/src/bin/core/node/watchdog.rs`
- Path failure detection: `controller/control-plane/agents/src/bin/ha/node/detector.rs`
- Switchover orchestration: `controller/control-plane/agents/src/bin/ha/cluster/switchover.rs`
- Volume operations: `controller/control-plane/agents/src/bin/core/volume/operations.rs`
- Nexus scheduling: `controller/control-plane/agents/src/bin/core/controller/scheduling/nexus.rs`

## Architecture Summary

### Deployment Pattern: "On-Demand Nexus Creation"
- **Single Active Instance**: Only one nexus per volume UUID can exist at any time
- **No Standby Instances**: No pre-deployed nexus instances waiting for activation
- **Dynamic Creation**: Control plane creates/destroys nexuses during failover
- **External Orchestration**: Complete lifecycle managed by control plane agents

### Multi-Layer Failure Detection

**1. Node-Level Detection**
- **Source**: `controller/control-plane/agents/src/bin/core/node/watchdog.rs`
- **Mechanism**: gRPC keepalive timeouts
- **Action**: Mark entire io-engine node offline, trigger reconciliation

**2. NVMe Path Detection**
- **Source**: `controller/control-plane/agents/src/bin/ha/node/detector.rs`
- **Official Design**: `io-engine/doc/design/ha-node-agent.md`
- **State Machine**: LIVE → SUSPECTED → FAILED
- **Detection Logic**: NVMe controller in "connecting" state twice consecutively
- **Monitoring Target**: Client node → nexus NVMe-oF connections

**3. I/O-Level Detection**
- **Source**: `io-engine/src/bdev/nexus/nexus_io.rs:685-696`
- **Mechanism**: NVMe reservation conflicts during I/O operations
- **Action**: Immediate nexus self-shutdown (`self.try_self_shutdown_nexus()`)

### Switchover Orchestration (5-Stage Process)

**Official Design**: `io-engine/doc/design/ha-failover.md`
**Implementation**: `controller/control-plane/agents/src/bin/ha/cluster/switchover.rs`

**Stage 1: Init**
- Create switchover request in etcd with volume UUID
- Persistent state for crash recovery

**Stage 2: RepublishVolume** 
- **Controller**: Select new target node via scheduling algorithms
- **Data Plane**: Create new nexus (NVMe reservations prevent dual-active)
- **Controller**: Gracefully shutdown old nexus
- **Data Plane**: Atomic reservation transfer

**Stage 3: ReplacePath**
- **Node Agents**: Update NVMe controller paths on client nodes
- **Integration**: Seamless multipath failover via ANA

**Stage 4: DeleteTarget**
- Destroy shutdown nexus from failed node
- Clean up NVMe subsystem artifacts

**Stage 5: Completion**
- Remove switchover request from etcd
- Generate success/error events

### Split-Brain Prevention Mechanisms

**1. NVMe Reservations**
- **Configuration**: `io-engine/src/bdev/nexus/nexus_bdev.rs:148`
- **Implementation**: `io-engine/src/bdev/nexus/nexus_child.rs:770-847`
- **Type**: WriteExclusiveAllRegs (default)
- **Environment**: `NEXUS_NVMF_RESV_ENABLE=1`
- **Protection**: Prevents multiple nexus instances accessing same storage children

**2. ANA (Asymmetric Namespace Access)**
- **States**: `io-engine/src/bdev/nexus/nexus_bdev.rs:84`
  - OptimizedState (1): Prefer this path
  - NonOptimizedState (2): Use if needed  
  - InaccessibleState (3): Avoid this path
- **Management**: `io-engine/src/subsys/nvmf/subsystem.rs:922`
- **Environment**: `NEXUS_NVMF_ANA_ENABLE=1`
- **Benefit**: Enables intelligent multipath path selection

**3. PTPL (Persistence Through Power Loss)**
- **Detection**: `io-engine/src/bdev/nexus/nexus_child.rs:517`
- **Purpose**: Reservations survive storage device power cycles
- **Configuration**: `MayastorEnvironment::global_or_default().ptpl_dir()`

### Control Plane Architecture

**Core Agent** (`controller/control-plane/agents/src/bin/core/main.rs`):
- Volume/nexus resource management
- Reconciliation loops for desired state convergence
- gRPC APIs for volume republish operations

**HA Cluster Agent** (`controller/control-plane/agents/src/bin/ha/cluster/main.rs`):
- Receives switchover requests from node agents
- Coordinates multi-node switchover operations
- Manages persistent switchover state in etcd

**Node Agents** (`controller/control-plane/agents/src/bin/ha/node/main.rs`):
- Monitor NVMe path health on client nodes
- Report failures to HA cluster agent
- Execute local path replacement operations

### Coordination Mechanisms

**Exactly-Once Guarantees**:
- **Data Plane**: NVMe reservations prevent dual nexus access to storage
- **Control Plane**: Etcd CAS operations for distributed coordination
- **Resource Management**: Atomic operations on volume specifications
- **Workflow**: Write-Ahead Log (WAL) for crash-resistant state machines

**Persistent Workflow Execution**:
- **Design**: `io-engine/doc/design/ha-failover.md` sections 141-162
- **Implementation**: All switchover progress stored in etcd
- **Recovery**: Non-complete WAL entries replayed on HA Cluster Agent restart
- **Worker Architecture**: 4 concurrent worker threads with retry logic

## Multi-Path Integration

### NVMe Path Monitoring Context
The "NVMe path state tracking" monitors **client-side NVMe-oF connections**:

```
Client Node → NVMe-oF Connection → Nexus (on io-engine node) → Storage
              ↑
         This connection is monitored
```

### ANA Integration
- **Same NQN**: Recreated nexus uses identical subsystem NQN for seamless ANA integration
- **Path Transitions**: 
  - Original path: `(LIVE)` → `(FAILED)`
  - New path added: `(FAILED, VALID)`
  - Cleanup: `(VALID)`
- **Client Experience**: NVMe multipath drivers automatically prefer OptimizedState paths

## Failure Scenario Handling

### Clean Node Failure
```
1. Node watchdog detects gRPC timeout
2. HA cluster agent initiates WAL-based switchover
3. Core agent selects new target via scheduling
4. New nexus acquires reservations (old nexus cleanly released)
5. Client paths updated via ANA, old nexus destroyed
```

### Unclean Node Failure/Network Partition
```
1. Path monitoring detects NVMe connection failures (connecting state)
2. Switchover initiated without cleanup on unreachable node
3. New nexus attempts reservation acquisition
4. NVMe preemption handles conflicts (ArgKey vs Holder policies)
5. Success → new nexus serves I/O; Failure → operator escalation
```

### I/O-Level Reservation Conflicts
```
1. Data plane detects reservation conflict during I/O
2. Current nexus immediately self-shutdowns
3. Control plane detects state change via reconciliation
4. Proper cleanup and state convergence ensured
```

## Key Architectural Insights

### Separation of Concerns
- **Data Plane**: Fast, local protection (reservations, self-shutdown)
- **Control Plane**: Orchestration, scheduling, distributed coordination  
- **Client Layer**: Multipath handling, connection management

### Performance Considerations
- **Fast Protection**: NVMe reservations provide immediate split-brain prevention
- **Minimal Disruption**: ANA states enable near-zero-downtime path switching
- **Load Balancing**: Scheduler distributes nexuses across available nodes
- **Concurrent Processing**: Worker pools handle multiple simultaneous switchovers

### Operational Implications
- **Control Plane HA**: Multiple agents with etcd-based leader election
- **Client Requirements**: NVMe multipath-aware drivers for full benefits
- **Storage Limitations**: NVMe reservations only work with NVMe/NVMe-oF backends
- **Monitoring Needs**: Reservation status, switchover metrics, path health

## Research Notes
- **Original Investigation**: Started with io-engine-research-tasks.md
- **HA Deep Dive**: Documented in docs/nexus-ha.md
- **Controller Analysis**: Task agent research of controller codebase
- **Documentation Discovery**: Found official design specs validating findings