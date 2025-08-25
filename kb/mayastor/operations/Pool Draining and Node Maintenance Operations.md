---
title: Pool Draining and Node Maintenance Operations
type: note
permalink: mayastor/operations/pool-draining-and-node-maintenance-operations
---

# Pool Draining and Node Maintenance Operations

Pool draining enables planned maintenance by moving volume targets (nexuses) and optionally replicas off specific nodes. This document covers the drain command, its behavior, and integration with node maintenance workflows.

## Understanding Pool Draining

### What Drain Actually Does
The `drain` command moves **volume targets (nexuses)**, not necessarily replicas:

**Code Reference**: `controller/reconciler/node/nexus.rs:200-280`

**Primary function**:
- **Moves I/O endpoints** (nexus) to different nodes
- **Reuses existing replicas** on other nodes where possible  
- **Performs nexus switchover** rather than data migration

**Secondary function** (when needed):
- **May move replicas** if target node has no alternative replica locations

### Drain vs. Replica Movement
**Key distinction**:
- **Drain = Move access point** (nexus switchover)
- **Scaling = Move data** (replica with rebuild)
- **Combination possible** - drain can trigger replica movement when necessary

## Drain Command Usage

### Basic Syntax
```bash
kubectl mayastor drain node <node-id> <label> [--drain-timeout <timeout>]
```

**Parameters**:
- `node-id`: The node to drain volumes from
- `label`: Arbitrary string to identify this drain operation  
- `timeout`: Optional timeout for drain completion

**Label Purpose**:
- **Operation tracking** - Identifies and tracks the specific drain operation
- **State management** - System uses it to manage drain state (draining → drained)
- **Multiple operations** - Allows concurrent drain operations with different labels
- **Cancellation reference** - You can reference the label to monitor or cancel

### Drain State Management

**Code Reference**: `plugin/src/resources/node.rs:555-571`
```rust
let already_has_drain_label: bool = 
    drain_labels_from_state(ds).contains(&label)
```

**Code Reference**: `plugin/src/resources/node.rs:262-263`
```rust
CordonDrainState::drainingstate(state) => state.drainlabels.clone(),
CordonDrainState::drainedstate(state) => state.drainlabels.clone(),
```

**Drain states**:
- **Multiple labels supported** - `drainlabels` is `Vec<String>`
- **Persistent state** - Labels survive through draining → drained transitions  
- **Idempotent operations** - Same label won't trigger duplicate drains

### Example Operations
```bash
# Drain for planned maintenance
kubectl mayastor drain node worker-1 "maintenance-jan-2024"

# Drain for hardware replacement
kubectl mayastor drain node worker-2 "disk-replacement-urgent"

# Check drain status
kubectl mayastor get drain worker-1

# Multiple concurrent drains with different labels
kubectl mayastor drain node worker-1 "maintenance"
kubectl mayastor drain node worker-1 "upgrade-prep"
```

## How Drain Works Internally

### Target Node Selection Logic

**Code Reference**: `controller/reconciler/node/nexus.rs:355-361`
```rust
if target_node == &replica_node {
    // All local already, don't move the target!
    None
} else {
    // Since we're moving the target, move it to the replica node!
    Some(Some(replica_node))
}
```

**Target selection algorithm**:
1. **Prefers nodes with existing replicas** - Minimizes network I/O
2. **Avoids unnecessary moves** - If nexus already on node with replica, no move needed
3. **Intelligent placement** - Chooses optimal target location

### Republish Process

**Code Reference**: `volume/operations.rs:495-496`
```rust
let healthy_replicas_result =
    healthy_volume_replicas(&spec, &older_nexus.as_ref().node, registry).await;
```

**What happens during drain**:
1. **RepublishVolume operation** initiated for each volume on draining node
2. **Healthy replica check** - Ensures target has accessible replicas
3. **Nexus recreation** on new target node
4. **Path updates** - NVMe paths automatically updated

## Drain Behavior Scenarios

### Scenario 1: Simple Nexus Move
**Setup**: Volume has replicas on nodes A and B, nexus on node A
```bash
kubectl mayastor drain node A "maintenance"
```

**Result**: 
- **Nexus moves from A to B** 
- **No replica movement** - existing replica on B is used
- **Fast operation** - just I/O endpoint relocation

### Scenario 2: Replica Movement Required
**Setup**: Volume has single replica on draining node A
```bash
kubectl mayastor drain node A "maintenance" 
```

**Result**:
- **Must move replica first** - no alternative replica locations
- **Slower operation** - involves data rebuild
- **Two-step process** - replica move, then nexus move

### Scenario 3: Multiple Concurrent Drains
**Setup**: Different maintenance operations on same node
```bash
kubectl mayastor drain node worker-1 "os-upgrade"
kubectl mayastor drain node worker-1 "disk-replacement"
```

**Result**:
- **Separate drain tracking** - different labels maintain separate state
- **Cumulative effect** - both drains affect same volumes
- **Independent completion** - each drain can complete separately

## Drain Limitations and Considerations

### What Drain Cannot Do
1. **Does not create new replicas** - relies on existing replica distribution
2. **Cannot help single-replica volumes** - if replica is on draining node, manual scaling needed
3. **No selective volume control** - affects ALL volumes on the node
4. **Requires healthy replicas elsewhere** - cannot move if no healthy alternatives

### Volume Requirements for Successful Drain
**Prerequisites**:
- **Multi-replica volumes** - or replica on different node than current nexus
- **Healthy replicas available** on other nodes
- **Accessible target nodes** with capacity for nexus operations
- **Network connectivity** between nodes for I/O path updates

### Performance Impact
- **Brief I/O interruption** during nexus switchover
- **Minimal data movement** - mostly metadata and path updates
- **Network I/O patterns change** - may increase inter-node traffic

## Integration with Node Maintenance

### Pre-Maintenance Checklist
```bash
# 1. Check volumes on target node
kubectl mayastor get volumes -o wide | grep <target-node>

# 2. Verify replica distribution
kubectl mayastor get volumes -o yaml | grep -A10 replica_topology

# 3. Ensure other nodes have capacity
kubectl mayastor get nodes | grep -v <target-node>

# 4. Check for ongoing operations
kubectl mayastor get volumes | grep -v "Online"
```

### Maintenance Workflow
```bash
# Step 1: Initiate drain
kubectl mayastor drain node <target-node> "maintenance-$(date +%Y%m%d)"

# Step 2: Monitor drain progress  
kubectl mayastor get drain <target-node>
kubectl mayastor get volumes -o wide --watch

# Step 3: Verify completion
kubectl mayastor get volumes -o wide | grep -v <target-node>

# Step 4: Proceed with maintenance
# (Node is now safe for maintenance)

# Step 5: Post-maintenance verification
kubectl mayastor get nodes
kubectl mayastor get pools
```

### Emergency Drain
```bash
# Fast drain for urgent maintenance
kubectl mayastor drain node <target-node> "emergency" --drain-timeout 300

# Monitor for issues
kubectl logs -f mayastor-controller -n mayastor | grep -i drain
```

## Troubleshooting Drain Operations

### Common Drain Failures
```bash
# Check for volumes that cannot be moved
kubectl mayastor get volumes -o wide | grep <draining-node>

# Look for single-replica volumes on draining node
kubectl mayastor get volumes -o yaml | grep -B5 -A5 "node.*<draining-node>"

# Check for unhealthy replicas
kubectl mayastor get volumes | grep -v "Online"
```

### Drain Stuck or Slow
```bash  
# Check controller logs
kubectl logs mayastor-controller -n mayastor | grep -A5 -B5 "drain"

# Verify target nodes are healthy
kubectl mayastor get nodes | grep -v <draining-node>

# Check for resource constraints
kubectl top nodes
```

### Partial Drain Completion
```bash
# Identify volumes still on draining node
kubectl mayastor get volumes -o wide | grep <draining-node>

# Manual intervention for stuck volumes
kubectl mayastor scale volume <stuck-volume> $((replicas + 1))
kubectl mayastor scale volume <stuck-volume> $replicas
```

## Best Practices

### Planning Drain Operations
1. **Verify replica distribution** before starting drain
2. **Ensure sufficient target nodes** with capacity
3. **Plan for single-replica volumes** - may need manual scaling first
4. **Schedule during low I/O periods** - minimize application impact

### Monitoring and Verification
```bash
# Before drain
kubectl mayastor get volumes -o wide | grep <target-node> | wc -l

# During drain  
kubectl mayastor get drain <target-node> --watch

# After drain
kubectl mayastor get volumes -o wide | grep <target-node>  # Should be empty
```

### Recovery Planning
```bash
# Keep drain label for potential rollback
kubectl mayastor get drain <target-node>

# Document drain state for troubleshooting
kubectl mayastor get volumes -o yaml > pre-drain-state.yaml
```

## Integration with Other Operations

### Relationship to Other Documents
- **[[Manual Volume Scaling for Replica Movement]]** - Use scaling for volumes that drain cannot handle
- **[[Automatic Capacity Management and ENOSPC Recovery]]** - Drain may trigger capacity management

### Operational Coordination
- **Before scaling** - Check if drain would be more appropriate for maintenance
- **Before manual replica moves** - Consider if drain achieves the same goal more efficiently
- **With capacity management** - Drain may redistribute I/O load and trigger automatic operations

Pool draining provides an efficient, low-impact method for planned maintenance when replica distribution supports it. For scenarios requiring replica data movement, combine drain operations with manual volume scaling for complete maintenance workflows.