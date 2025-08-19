---
title: SPDK QoS (Quality of Service) Support
type: note
permalink: spdk-research/spdk-qo-s-quality-of-service-support
tags:
- '["spdk"'
- '"qos"'
- '"quality-of-service"'
- '"nvmf"'
- '"bdev"'
- '"rate-limiting"]'
---

# SPDK QoS (Quality of Service) Support

SPDK provides comprehensive QoS functionality at the **block device (bdev) layer**, which means it applies to all storage backends including NVMf targets.

> **Related Documents**: [[SPDK Bdev Overview]] | [[SPDK NVMe-oF Overview]]
## QoS Rate Limit Types

SPDK supports four types of rate limits defined in `include/spdk/bdev.h:148-159`:

1. **`SPDK_BDEV_QOS_RW_IOPS_RATE_LIMIT`** (`rw_ios_per_sec`) - IOPS rate limit for both read and write operations
2. **`SPDK_BDEV_QOS_RW_BPS_RATE_LIMIT`** (`rw_mbytes_per_sec`) - Bandwidth rate limit (MB/s) for both read and write 
3. **`SPDK_BDEV_QOS_R_BPS_RATE_LIMIT`** (`r_mbytes_per_sec`) - Bandwidth rate limit (MB/s) for read operations only
4. **`SPDK_BDEV_QOS_W_BPS_RATE_LIMIT`** (`w_mbytes_per_sec`) - Bandwidth rate limit (MB/s) for write operations only

## Configuration Methods

### Via RPC (Runtime)
```bash
# Set IOPS limit to 20,000 operations per second
rpc.py bdev_set_qos_limit Malloc0 --rw_ios_per_sec 20000

# Set bandwidth limits
rpc.py bdev_set_qos_limit Malloc0 --rw_mbytes_per_sec 100 --r_mbytes_per_sec 50

# Disable limits (set to 0)
rpc.py bdev_set_qos_limit Malloc0 --rw_ios_per_sec 0
```

### Programmatic API
- `spdk_bdev_set_qos_rate_limits()` - Set QoS limits (`include/spdk/bdev.h:509`)
- `spdk_bdev_get_qos_rate_limits()` - Get current QoS limits (`include/spdk/bdev.h:497`)
- `spdk_bdev_get_qos_rpc_type()` - Get QoS type string (`include/spdk/bdev.h:487`)

## Implementation Details

- QoS is implemented with a **token bucket algorithm** with configurable timeslices (`lib/bdev/bdev.c`)
- Minimum granularity: **1000 IOPS** or **1 MB/s** bandwidth
- I/O requests are queued when limits are exceeded and submitted when quotas are available
- QoS operates at the bdev layer (see [[SPDK Bdev Overview]]), so it applies to **all protocols** (NVMf, iSCSI, etc.)
- Uses polling mechanism (`bdev_channel_poll_qos`) to manage quota replenishment

## Key Files

- **Core Implementation**: `lib/bdev/bdev.c` (lines 1745+ for QoS functions)
- **RPC Interface**: `lib/bdev/bdev_rpc.c` (lines 556+ for `bdev_set_qos_limit`)
- **API Headers**: `include/spdk/bdev.h` (lines 147-159, 485+)
- **Test Suite**: `test/iscsi_tgt/qos/qos.sh`
- **Documentation**: `doc/jsonrpc.md` (section on `bdev_set_qos_limit`)

## NVMf Integration

Since QoS is implemented at the bdev layer, it automatically works with **NVMf targets** (see [[SPDK NVMe-oF Overview]]). Any bdev exposed through NVMf will respect the configured QoS limits, providing per-device rate limiting for NVMf namespaces.

## Production Readiness

The QoS functionality is production-ready and includes comprehensive testing that verifies:
- IOPS rate limiting works within 85-105% of configured limits
- Bandwidth rate limiting works within 85-105% of configured limits  
- Limits can be enabled/disabled dynamically
- Read-only and write-only bandwidth limits work correctly

## Internal Architecture

- **Struct**: `spdk_bdev_qos` manages QoS state per bdev
- **Rate Limits**: Array of `spdk_bdev_qos_limit` structures
- **Queuing**: Uses `TAILQ` to queue I/O when limits exceeded
- **Thread Safety**: QoS channel runs on dedicated thread
- **Timeslice Management**: Configurable time windows for quota replenishment