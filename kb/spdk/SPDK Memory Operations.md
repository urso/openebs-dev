---
title: SPDK Memory Operations
type: note
permalink: spdk/spdk-memory-operations
tags:
- '["spdk"'
- '"memory"'
- '"operations"'
- '"monitoring"'
- '"troubleshooting"'
- '"performance"'
- '"tuning"]'
---

# SPDK Memory Operations

This document covers monitoring, tuning, troubleshooting, and operational best practices for SPDK memory management in production environments.

## Monitoring and Statistics

### Monitor IOBuf Usage

```bash
# Check buffer pool utilization
./scripts/rpc.py iobuf_get_stats

# Key metrics to watch:
# - retry_count: Buffer pool exhaustion (should be 0)
# - pool utilization: Percentage of buffers in use
# - alloc_count vs available_count: Usage patterns
```

### Understanding IOBuf Statistics

**Critical Metrics**:

| Metric | Meaning | Target Value |
|--------|---------|--------------|
| `retry_count` | Buffer pool exhaustion events | **0** (any value > 0 indicates problems) |
| `alloc_count` | Currently allocated buffers | Monitor trends |
| `available_count` | Available buffers in pool | Should remain > 0 |
| `cache_count` | Cached buffers per thread | Normal caching behavior |

**Example Output Interpretation**:
```json
{
  "small_pool": {
    "retry_count": 0,        // ✅ Good - no exhaustion
    "alloc_count": 1024,     // Current usage
    "available_count": 7168  // Available buffers
  },
  "large_pool": {
    "retry_count": 15,       // ❌ Problem - buffer exhaustion
    "alloc_count": 1024,     // Pool fully utilized
    "available_count": 0     // No buffers available
  }
}
```

### System-Level Monitoring

```bash
# Check hugepage allocation
cat /proc/meminfo | grep -i huge

# Monitor NUMA allocation
numastat -m

# Check memory pressure
free -h
```

## Performance Tuning

### Tuning Guidelines

1. **Start conservative** with default or slightly higher values from [[SPDK Memory Configuration]]
2. **Monitor for exhaustion**: Look for `retry_count > 0`
3. **Scale up gradually** if seeing buffer exhaustion
4. **Scale down** if utilization is consistently very low
5. **Consider workload patterns** when adjusting ratios

### Tuning Process

#### Step 1: Baseline Measurement
```bash
# Record initial statistics
./scripts/rpc.py iobuf_get_stats > baseline_stats.json

# Run representative workload
# Monitor for several minutes/hours
```

#### Step 2: Identify Issues
```bash
# Check for buffer exhaustion during/after workload
./scripts/rpc.py iobuf_get_stats

# Look for:
# - retry_count > 0 (indicates exhaustion)
# - Very low available_count consistently
# - High alloc_count relative to pool size
```

#### Step 3: Adjust Configuration
```bash
# If seeing small buffer exhaustion:
./scripts/rpc.py iobuf_set_options --small-pool-count 65536

# If seeing large buffer exhaustion:
./scripts/rpc.py iobuf_set_options --large-pool-count 8192

# Re-test and monitor
```

#### Step 4: Validate Changes
```bash
# Run same workload again
# Verify retry_count remains 0
# Check utilization is reasonable (not too high or too low)
```

### Workload-Specific Tuning

**For Random I/O Workloads**:
- Monitor small buffer utilization more closely
- Increase `--small-pool-count` if seeing exhaustion
- May reduce `--large-pool-count` if consistently unused

**For Sequential I/O Workloads**:
- Monitor large buffer utilization more closely
- Increase `--large-pool-count` if seeing exhaustion
- May reduce `--small-pool-count` if consistently unused

## Troubleshooting

### Buffer Pool Exhaustion

**Symptoms**:
- `retry_count > 0` in `iobuf_get_stats`
- Performance degradation during I/O bursts
- Application timeouts or errors

**Root Cause Analysis**:
```bash
# Check which pool is exhausted
./scripts/rpc.py iobuf_get_stats

# Verify total hugepage allocation
cat /proc/meminfo | grep -i huge

# Check for memory leaks in application
# Monitor alloc_count trends over time
```

**Solutions**:
1. **Increase pool counts** for the exhausted pool type
2. **Check for memory leaks** - alloc_count should stabilize
3. **Verify total hugepage allocation** is sufficient
4. **Review workload patterns** - may need different buffer ratios

**Example Fix**:
```bash
# Small buffer exhaustion
./scripts/rpc.py iobuf_set_options --small-pool-count 131072

# Large buffer exhaustion  
./scripts/rpc.py iobuf_set_options --large-pool-count 16384
```

### Poor Performance

**Symptoms**:
- High latency despite sufficient buffers
- Lower than expected throughput
- Inconsistent performance

**Check List**:
```bash
# 1. Buffer pool sizing vs workload
./scripts/rpc.py iobuf_get_stats

# 2. NUMA node placement
numactl --hardware
numastat -m

# 3. Hugepage allocation across nodes
cat /sys/devices/system/node/node*/meminfo | grep -i huge

# 4. CPU affinity and reactor placement
# Check SPDK reactor configuration
```

**Solutions**:
1. **Adjust buffer ratios** based on workload analysis
2. **Ensure NUMA-local memory allocation**
3. **Review CPU affinity** for SPDK reactors
4. **Check hugepage distribution** across NUMA nodes

### Memory Allocation Failures

**Symptoms**:
- Cannot allocate IOBuf pools during startup
- "Out of memory" errors from SPDK
- Failed initialization

**Diagnostic Steps**:
```bash
# 1. Total hugepage allocation
cat /proc/meminfo | grep -i huge

# 2. Available hugepages per NUMA node
for node in /sys/devices/system/node/node*; do 
  echo "$node:"
  cat $node/meminfo | grep -i huge
  echo
done

# 3. Other memory consumers
ps aux --sort=-%mem | head -10

# 4. Check SPDK memory requirements
# Verify configuration doesn't exceed available memory
```

**Solutions**:
1. **Increase total hugepage allocation**
2. **Ensure balanced allocation across NUMA nodes**
3. **Reduce IOBuf pool sizes** if memory constrained
4. **Check for other memory consumers**

### Common Issues and Solutions

| Issue | Symptoms | Solution |
|-------|----------|----------|
| **Buffer Exhaustion** | retry_count > 0 | Increase pool counts |
| **Memory Waste** | Very low utilization | Reduce pool counts |
| **NUMA Imbalance** | Poor performance on some CPUs | Balance hugepages across nodes |
| **Allocation Failure** | Startup failures | Increase total hugepages |
| **Memory Leaks** | Growing alloc_count | Check application memory management |

## Best Practices

### Initial Configuration

1. **Size hugepages appropriately** for your total memory needs using guidelines in [[SPDK Memory Configuration]]
2. **Start with conservative IOBuf settings**
3. **Monitor usage patterns** during testing
4. **Adjust based on actual workload**

### Production Deployment

1. **Test thoroughly** with representative workloads
2. **Monitor continuously** for buffer exhaustion
3. **Have alerting** on retry_count increases
4. **Document** your configuration choices

### Operational Guidelines

**Daily Operations**:
```bash
# Check for buffer exhaustion
./scripts/rpc.py iobuf_get_stats | grep retry_count

# Monitor hugepage usage
cat /proc/meminfo | grep -i huge
```

**Weekly Reviews**:
- Analyze buffer utilization trends
- Review performance metrics
- Check for memory leaks (growing alloc_count)
- Validate NUMA allocation balance

**Before Major Changes**:
- Record baseline statistics
- Test configuration changes in staging
- Have rollback procedure ready

### Common Mistakes to Avoid

1. **Over-allocating** IOBuf pools (wasting memory)
2. **Under-allocating** total hugepages
3. **Ignoring NUMA topology** in multi-socket systems
4. **Not monitoring** buffer pool utilization
5. **Making large configuration changes** without testing

## Monitoring Automation

### Automated Checks

```bash
#!/bin/bash
# Simple monitoring script
STATS=$(./scripts/rpc.py iobuf_get_stats)
SMALL_RETRY=$(echo $STATS | jq '.small_pool.retry_count')
LARGE_RETRY=$(echo $STATS | jq '.large_pool.retry_count')

if [ "$SMALL_RETRY" -gt 0 ] || [ "$LARGE_RETRY" -gt 0 ]; then
    echo "ALERT: Buffer pool exhaustion detected"
    echo "Small pool retries: $SMALL_RETRY"
    echo "Large pool retries: $LARGE_RETRY"
fi
```

### Integration with Monitoring Systems

Consider integrating IOBuf statistics with your monitoring infrastructure:
- Export metrics to Prometheus/Grafana
- Set up alerts for retry_count > 0
- Track utilization trends over time
- Monitor memory allocation patterns

## Emergency Procedures

### Buffer Exhaustion Recovery

If experiencing severe buffer exhaustion in production:

1. **Immediate**: Increase pool counts for exhausted type
2. **Monitor**: Verify retry_count drops to 0
3. **Investigate**: Check for memory leaks or workload changes
4. **Plan**: Adjust baseline configuration for future

### Memory Pressure Resolution

If running out of hugepages:

1. **Immediate**: Reduce IOBuf pool sizes temporarily
2. **Add memory**: Increase hugepage allocation
3. **Optimize**: Review memory usage across all consumers
4. **Monitor**: Ensure changes don't cause buffer exhaustion

## Implementation References

### Monitoring and Statistics
- **IOBuf Statistics**: lib/thread/iobuf.c (statistics collection)
- **RPC Interface**: scripts/rpc.py (iobuf_get_stats command)
- **Memory Tracking**: lib/env_dpdk/memory.c (hugepage management)