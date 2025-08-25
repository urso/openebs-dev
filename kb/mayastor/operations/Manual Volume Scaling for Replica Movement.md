---
title: Manual Volume Scaling for Replica Movement
type: note
permalink: mayastor/operations/manual-volume-scaling-for-replica-movement
---

# Manual Volume Scaling for Replica Movement

Manual volume scaling provides controlled replica movement by temporarily increasing replica count, then reducing it to remove replicas from problematic pools. This approach offers predictive capacity management beyond the automatic ENOSPC recovery.

## Overview

The scaling strategy uses a simple 2-step process:
1. **Scale up** (e.g., 2→3) - Creates new replica on a different pool
2. **Scale down** (e.g., 3→2) - Removes replica from problematic pool

This bypasses the healthy replica constraints that limit automatic capacity management.

## How Manual Scaling Works

### Scale-Up Process
**Code Reference**: `volume/operations_helper.rs:209-238`

```bash
kubectl mayastor scale volume <volume-id> 3
```

**What happens**:
1. **Pool Selection** (line 222): `volume_replica_candidates(registry, &spec_clone)`
2. **Replica Creation** (line 228): `create_volume_replica_with(registry, candidates)`  
3. **Nexus Attachment** (line 234): `attach_to_target(registry, replica)`

**Key difference from automatic operations**:
- **Bypasses control plane health filtering** - skips `ChildInfoFilters::healthy` in scheduling
- **Uses any available pool** - not restricted to pools with only healthy replicas  
- **Still requires I/O engine health checks** - `find_src_replica` demands healthy children

### Scale-Down Process
**Code Reference**: `volume/operations_helper.rs:256-280`

```bash
kubectl mayastor scale volume <volume-id> 2
```

**What happens**:
1. **Replica Selection**: Chooses which replica to remove (typically least preferred)
2. **Nexus Removal** (line 268): `remove_volume_child_candidate(registry, &remove)`
3. **Replica Destruction** (line 274): `destroy_replica(registry, remove.spec())`

## Manual Scaling vs. Automatic Recovery

### Code Path Differences

**Manual Scaling Path**:
- **File**: `operations_helper.rs:209-238`
- **Process**: `volume_replica_candidates()` → `create_volume_replica_with()` → `attach_to_target()`
- **Health Checks**: None - bypasses healthy replica requirements

**Automatic Recovery Path**:  
- **File**: `volume/specs.rs:304` and `volume/scheduling.rs:66`
- **Process**: `healthy_volume_replicas()` → `.filter(ChildInfoFilters::healthy)`
- **Health Checks**: Only uses replicas with `ChildInfo.healthy = true`

### Critical Bypass Mechanism

**Manual Attach Process** (`nexus/operations_helper.rs:32-46`):
```rust
// Adding a replica to a nexus will initiate a rebuild.
// First check that we are able to start a rebuild.
registry.rebuild_allowed().await?;

let request = AddNexusReplica {
    auto_rebuild: true,  // ← Controls whether rebuild is attempted, NOT health requirements
    // ...
};
```

**CORRECTION**: The `auto_rebuild: true` parameter does NOT bypass health checks. It only controls whether a rebuild attempt is made. The I/O engine still requires healthy replicas for any rebuild operation.

## When Manual Scaling Works vs. Fails

### ✅ Manual Scaling Works When:

**Scenario**: Some replicas ENOSPC, others healthy
```bash
# Example: 1 replica ENOSPC, 1 replica healthy
kubectl mayastor scale volume my-vol 3  # ✅ Creates new replica, rebuilds from healthy
kubectl mayastor scale volume my-vol 2  # ✅ Removes ENOSPC replica
```

**Scenario**: All replicas ENOSPC, but pools available
```bash  
# Manual scaling CANNOT work - no healthy source replicas
kubectl mayastor scale volume my-vol 3  # ❌ FAILS - "No rebuild source found"
```

### ❌ Manual Scaling Fails When:

**Scenario**: No pools with available space
```bash
kubectl mayastor scale volume my-vol 3  # ❌ Fails - no candidate pools
# Error: No pools available with sufficient space
```

**Scenario**: All replicas unhealthy (ENOSPC, faulted, etc.)
```bash
# I/O engine requires healthy replicas for rebuild source
kubectl mayastor scale volume my-vol 3  # ❌ FAILS immediately - "No rebuild source found"
```

## Best Practices

### Proactive Scaling Strategy

**Monitor pool capacity**:
```bash
# Check pool utilization regularly
kubectl mayastor get pools -o wide | grep -E "(80|90)%"
```

**Scale before hitting ENOSPC**:
```bash
# When pools reach 80%, proactively move replicas
kubectl mayastor scale volume <vol-1> 3
kubectl mayastor scale volume <vol-1> 2

kubectl mayastor scale volume <vol-2> 3  
kubectl mayastor scale volume <vol-2> 2
```

### Verification Steps

**After scale-up**:
```bash
# Verify new replica is created and rebuilding
kubectl mayastor get volume <volume-id> -o wide
kubectl mayastor get volume <volume-id> -o yaml | grep -A5 replica_topology
```

**After scale-down**:
```bash
# Verify problematic replica was removed
kubectl mayastor get volume <volume-id> -o wide
```

### Pool Management Integration

**Cordon problematic pools**:
```bash
# Prevent new replica placement on nearly full pools
kubectl mayastor cordon pool <nearly-full-pool>
```

**Check available pools**:
```bash  
# Ensure sufficient pools available before scaling
kubectl mayastor get pools --output wide
```

## Scaling Command Reference

### Basic Commands
```bash
# Scale up (add replica)
kubectl mayastor scale volume <volume-id> <new-count>

# Examples
kubectl mayastor scale volume my-volume 3  # 2→3 replicas
kubectl mayastor scale volume my-volume 4  # 3→4 replicas

# Scale down (remove replica)  
kubectl mayastor scale volume my-volume 2  # 3→2 replicas
kubectl mayastor scale volume my-volume 1  # 2→1 replica (single replica - use carefully)
```

### Verification Commands
```bash
# Check current replica count and status
kubectl mayastor get volume <volume-id>

# Detailed replica topology information
kubectl mayastor get volume <volume-id> -o yaml

# Monitor rebuild progress
kubectl mayastor get volume <volume-id> -o wide --watch
```

## Limitations and Considerations

### Volume Availability
- **Brief I/O interruption** may occur during scaling operations
- **Rebuild time** depends on data size and network performance  
- **Multiple concurrent rebuilds** can impact cluster performance

### Pool Requirements  
- **Sufficient pools** with available space required for scale-up
- **Pool distribution** affects replica placement efficiency
- **Network connectivity** between nodes required for rebuild

### Operational Complexity
- **Manual intervention** required for each volume
- **Timing coordination** needed for multiple volume operations  
- **Monitoring required** to verify successful completion

## Integration with Other Operations

### Complementary Operations
- **[[Automatic Capacity Management and ENOSPC Recovery]]** - Handles emergency situations automatically
- **[[Pool Draining and Node Maintenance Operations]]** - For planned maintenance scenarios

### Conflict Prevention
- **Avoid concurrent operations** on same volumes
- **Check for ongoing rebuilds** before initiating scaling
- **Coordinate with maintenance** operations

## Troubleshooting

### Scale-Up Failures
```bash  
# Check available pools
kubectl mayastor get pools -o wide

# Verify volume isn't already scaling  
kubectl mayastor get volume <volume-id> -o yaml | grep -A5 operation

# Check for conflicting operations
kubectl mayastor get volumes | grep -i scaling
```

### Scale-Down Issues
```bash
# Verify sufficient healthy replicas remain
kubectl mayastor get volume <volume-id> -o wide

# Check for ongoing rebuilds
kubectl mayastor get volume <volume-id> -o yaml | grep rebuild
```

### Rebuild Failures
```bash
# Check I/O engine logs
kubectl logs -f <io-engine-pod> -n mayastor

# Monitor nexus status
kubectl mayastor get volume <volume-id> -o yaml | grep -A10 target
```

Manual volume scaling provides powerful, flexible replica movement capabilities that complement OpenEBS Mayastor's automatic capacity management, enabling proactive storage optimization and emergency recovery scenarios.