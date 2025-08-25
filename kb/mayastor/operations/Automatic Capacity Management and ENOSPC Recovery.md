---
title: Automatic Capacity Management and ENOSPC Recovery
type: note
permalink: mayastor/operations/automatic-capacity-management-and-enospc-recovery
---

# Automatic Capacity Management and ENOSPC Recovery

OpenEBS Mayastor includes built-in automatic capacity management that moves replicas when pools run out of space. This document explains how the system automatically handles ENOSPC (No Space) errors in thin-provisioned environments.

## How Automatic Recovery Works

### Detection Phase
The system continuously monitors for pools with ENOSPC errors through the pool reconciler:

**Code Reference**: `controller/control-plane/agents/src/bin/core/controller/reconciler/pool/capacity.rs:25-29`
```rust
let pools = unfiltered_enospc_pools(registry).await;
```

**What it detects**:
- Scans all nexus children for `ENOSPC` error state
- Groups by pool to find pools with space-exhausted replicas  
- Builds `ENoSpcPool` list of problematic pools

**Code Reference**: `controller/control-plane/agents/src/bin/core/controller/scheduling/pool.rs:67-89`

The detection looks at **NexusChild** states, not just pool capacity metrics. This means it's triggered by **actual I/O failures** due to space exhaustion.

### Selection Phase
When ENOSPC pools are detected, the system selects which replicas to move:

**Code Reference**: `capacity.rs:34-50`
```rust
let largest_replica = pool_wrapper
    .move_replicas()
    .into_iter()
    .filter_map(|r| /* find matching ENOSPC replica */)
    .max_by(|(a, _), (b, _)| match (&a.space, &b.space) {
        (Some(space_a), Some(space_b)) => {
            space_a.allocated_bytes.cmp(&space_b.allocated_bytes)  // Selects largest consumer
        }
        _ => std::cmp::Ordering::Equal,
    })
```

**Selection Algorithm**:
1. Gets actual space usage from the I/O engine for each replica
2. Compares `allocated_bytes` (actual thin-provisioned usage, not logical size)
3. Selects largest consumer to maximize space recovery per move operation

### Movement Phase
The system performs the actual replica movement:

**Code Reference**: `capacity.rs:69-74`
```rust
let replica = volume
    .move_replica(
        registry,
        &MoveReplicaRequest::from(eno_replica).with_delete(true),
    )
    .await?;
```

**What happens**:
1. Creates new replica on a pool with available space
2. Rebuilds/syncs data from remaining healthy replicas
3. Removes old replica (`.with_delete(true)`) after successful sync
4. Updates nexus to use new replica location
5. Logs successful move with old/new pool information

## Safety Mechanisms

### Volume Safety
**Code Reference**: `capacity.rs:21-23`
```rust
/// A pre-condition for the replica faulting is that the volume to which the replica belongs to
/// should retain "enough" remaining healthy replicas! For example, we can't fault the last replica
/// of a volume as we can't rebuild from "thin" air.
```

The system will **NOT** move replicas if it would compromise data availability:
- Won't move the last replica of a volume
- Checks replica count before moving
- Ensures data availability throughout the process

### Error Handling
**Node offline tolerance** (capacity.rs:52-54): Skips if can't reach node
**Graceful degradation**: Continues with other pools if one fails
**Operation guards**: Prevents concurrent operations on same resources

## Configuration and Tuning

### Reconciliation Frequency
The automatic policy runs as part of the main reconciliation loop:

**Code Reference**: `controller/reconciler/pool/mod.rs:59`
```rust
capacity::remove_larger_replicas(registry).await
```

**Default behavior**:
- Runs every reconciliation cycle (~5-10 seconds)
- Reactive only - triggers on actual ENOSPC errors
- No proactive capacity thresholds

### Policy Controls
The current system is policy-driven with these built-in behaviors:

1. **Space Threshold Policy**: Automatically triggers when pools hit ENOSPC
2. **Size-Based Priority**: Moves largest replicas first for maximum space recovery  
3. **Multi-Replica Safety**: Won't move the last replica of a volume
4. **Automatic Pool Selection**: Chooses destination pools with sufficient free space

## When Automatic Recovery Cannot Help

### All Replicas ENOSPC Scenario
When ALL replicas of a volume have ENOSPC errors:

**Code Reference**: `nexus/operations.rs:541-543`
```rust
nexus.error_span(|| {
    tracing::error!("No healthy replicas found - manual intervention required")
});
return Err(SvcError::NoOnlineReplicas { id: nexus.name });
```

**What happens**:
1. `healthy_volume_replicas()` returns error - No healthy replicas found
2. `NoHealthyReplicas` error is thrown  
3. `remove_larger_replicas()` SKIPS the volume - Cannot move without healthy source
4. Volume enters degraded/failed state
5. Manual intervention required

**Why it fails**:
- Automatic system requires healthy replicas to rebuild from
- ENOSPC replicas marked as `ChildInfo.healthy = false`
- System safety mechanisms prevent data loss

## Monitoring Automatic Operations

### Commands to Monitor
```bash
# Check for pools with ENOSPC issues
kubectl mayastor get pools -o wide

# Monitor volume replica distribution  
kubectl mayastor get volumes -o wide

# Watch replica movement logs
kubectl logs -f mayastor-controller -n mayastor | grep "remove_larger_replicas"
```

### Log Messages to Watch For
- `"Successfully moved replica from pool X to pool Y"`
- `"No healthy replicas found - manual intervention required"`
- `"Cannot move replica - would compromise volume availability"`

## Integration with Other Operations

This automatic capacity management works alongside:
- [[Manual Volume Scaling for Replica Movement]] - For predictive control
- [[Pool Draining and Node Maintenance Operations]] - For planned maintenance

The automatic policy handles **emergency situations (ENOSPC)**, while manual operations provide **predictive control** for optimal performance.

## Limitations

1. **Reactive Only**: Waits for actual ENOSPC before moving (not predictive)
2. **No Custom Pool Selection**: System chooses destination pools automatically
3. **Requires Healthy Replicas**: Cannot move if all replicas are unhealthy
4. **Single Pool Recovery**: Processes one pool at a time during reconciliation cycles
5. **No User Control**: Cannot pause, prioritize, or customize the movement process

For scenarios requiring more control, see [[Manual Volume Scaling for Replica Movement]].