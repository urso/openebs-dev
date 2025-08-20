---
title: SPDK RPC Client Usage
type: note
permalink: spdk/rpc/spdk-rpc-client-usage
---

# SPDK RPC Client Usage

## Python Client Overview

The primary SPDK RPC client is a Python-based tool at `scripts/rpc.py` that provides a command-line interface to all RPC methods. It supports multiple transport types, flexible parameter passing, and both interactive and batch processing modes.

## Basic Command Structure

```bash
./scripts/rpc.py [options] <method_name> [method_parameters]
```

### Global Options

```bash
-s, --server_addr    # RPC socket path or IP address (default: /var/tmp/spdk.sock)
-p, --port          # RPC port number for IP connections (default: 5260)  
-t, --timeout       # Request timeout in seconds (default: 60.0)
-r, --conn_retries  # Connection retry attempts (default: 0)
-v, --verbose       # Set verbose level (INFO, DEBUG, ERROR)
--dry_run          # Display request JSON without sending
--server           # Server mode for scripting
```

## Connection Methods

### Unix Domain Socket (Default)
```bash
# Default socket
./scripts/rpc.py bdev_get_bdevs

# Custom socket path
./scripts/rpc.py -s /tmp/custom.sock bdev_get_bdevs

# Multiple applications
./scripts/rpc.py -s /var/tmp/spdk1.sock bdev_get_bdevs
./scripts/rpc.py -s /var/tmp/spdk2.sock bdev_get_bdevs
```

### TCP/IP Connections  
```bash
# IPv4 connection
./scripts/rpc.py -s 192.168.1.100 -p 5260 bdev_get_bdevs

# IPv6 connection  
./scripts/rpc.py -s "2001:db8::1" -p 5260 bdev_get_bdevs

# Localhost TCP
./scripts/rpc.py -s 127.0.0.1 -p 5260 bdev_get_bdevs
```

### Connection Management
```bash
# Set timeout to 2 minutes
./scripts/rpc.py -t 120.0 bdev_malloc_create 1024 512

# Retry connection 3 times with 0.2s intervals
./scripts/rpc.py -r 3 bdev_get_bdevs

# Combined timeout and retries for slow operations
./scripts/rpc.py -t 300.0 -r 5 bdev_raid_create MyRAID raid0 '["Malloc0", "Malloc1"]'
```

## Parameter Passing

### Simple Parameters
```bash
# Single parameter methods
./scripts/rpc.py framework_start_init
./scripts/rpc.py spdk_get_version
./scripts/rpc.py bdev_get_bdevs
```

### Methods with Parameters
```bash
# Positional parameters (when supported)
./scripts/rpc.py bdev_malloc_create 1024 4096 MyRAMDisk

# JSON parameter object
./scripts/rpc.py bdev_malloc_create -p '{
  "num_blocks": 1024,
  "block_size": 4096,
  "name": "MyRAMDisk"
}'
```

### Complex Parameter Examples
```bash
# Create RAID array with JSON parameters
./scripts/rpc.py bdev_raid_create -p '{
  "name": "MyRAID",
  "raid_level": "raid0", 
  "base_bdevs": ["Malloc0", "Malloc1", "Malloc2"],
  "strip_size_kb": 64
}'

# NVMe-oF subsystem with multiple parameters
./scripts/rpc.py nvmf_create_subsystem -p '{
  "nqn": "nqn.2016-06.io.spdk:cnode1",
  "allow_any_host": true,
  "serial_number": "SPDK00000000000001",
  "model_number": "SPDK Controller"
}'

# Set bdev options during startup
./scripts/rpc.py bdev_set_options -p '{
  "bdev_io_pool_size": 65536,
  "bdev_io_cache_size": 256,
  "bdev_auto_examine": true
}'
```

## Response Handling

### Success Responses
```bash
# Simple string response
$ ./scripts/rpc.py bdev_malloc_create 1024 4096 TestDisk
"TestDisk"

# Object response  
$ ./scripts/rpc.py spdk_get_version
{
  "version": "21.04-pre",
  "fields": {
    "major": 21,
    "minor": 4, 
    "patch": 0,
    "suffix": "-pre"
  }
}

# Array response
$ ./scripts/rpc.py bdev_get_bdevs
[
  {
    "name": "TestDisk",
    "aliases": [],
    "product_name": "Malloc disk",
    "block_size": 4096,
    "num_blocks": 1024,
    "claimed": false
  }
]
```

### Error Responses
```bash
# Method not found
$ ./scripts/rpc.py invalid_method
{
  "jsonrpc": "2.0",
  "error": {
    "code": -32601,
    "message": "Method not found"
  },
  "id": 1
}

# Invalid parameters
$ ./scripts/rpc.py bdev_malloc_create "invalid" "params"
{
  "jsonrpc": "2.0", 
  "error": {
    "code": -32602,
    "message": "Invalid parameters"
  },
  "id": 1
}

# State-based restrictions
$ ./scripts/rpc.py bdev_malloc_create 1024 4096  # During startup
{
  "jsonrpc": "2.0",
  "error": {
    "code": -1,
    "message": "Method may only be called after framework is initialized"
  },
  "id": 1
}
```

## Advanced Usage Patterns

### Server Mode for Scripting
```bash
# Start server mode
./scripts/rpc.py --server

# Each line processed as separate command
bdev_malloc_create 1024 4096 Disk1
**STATUS=0
bdev_malloc_create 1024 4096 Disk2  
**STATUS=0
bdev_get_bdevs
[{"name": "Disk1", ...}, {"name": "Disk2", ...}]
**STATUS=0
invalid_command
**STATUS=1
```

### Bash Integration
```bash
#!/bin/bash
RPC="./scripts/rpc.py"

# Store results in variables
VERSION=$(${RPC} spdk_get_version)
echo "SPDK Version: $(echo $VERSION | jq -r .version)"

# Check command success
if ${RPC} framework_start_init; then
    echo "Framework initialized successfully"
else
    echo "Framework initialization failed"
    exit 1
fi

# Process JSON responses
BDEVS=$(${RPC} bdev_get_bdevs)
COUNT=$(echo "$BDEVS" | jq length)
echo "Found $COUNT block devices"
```

### Coproc Integration
```bash
# Start RPC server as coprocess
coproc RPC_PROC (./scripts/rpc.py --server)

# Send commands via pipe
echo "bdev_get_bdevs" >&${RPC_PROC[1]}
read -r RESPONSE <&${RPC_PROC[0]}
read -r STATUS <&${RPC_PROC[0]}

# Clean shutdown
echo "exit" >&${RPC_PROC[1]}
wait $RPC_PROC_PID
```

### Plugin Usage
```bash
# Load custom plugin  
./scripts/rpc.py --plugin my_custom_plugin custom_method

# Multiple plugins
./scripts/rpc.py --plugin plugin1 --plugin plugin2 method_name

# Plugin with parameters
./scripts/rpc.py --plugin test_plugin create_malloc
./scripts/rpc.py --plugin test_plugin delete_malloc MyMalloc
```

## Debugging and Troubleshooting

### Verbose Output
```bash
# INFO level logging
./scripts/rpc.py -v bdev_get_bdevs

# DEBUG level logging (shows JSON-RPC traffic)
./scripts/rpc.py --verbose DEBUG bdev_malloc_create 1024 4096

# Specific verbose level
./scripts/rpc.py --verbose ERROR bdev_get_bdevs
```

### Dry Run Mode
```bash
# See request JSON without sending
./scripts/rpc.py --dry_run bdev_malloc_create 1024 4096 TestDisk
{
  "jsonrpc": "2.0",
  "method": "bdev_malloc_create", 
  "params": {
    "num_blocks": 1024,
    "block_size": 4096,
    "name": "TestDisk"
  },
  "id": 1
}
```

### Connection Troubleshooting
```bash
# Test connectivity
./scripts/rpc.py rpc_get_methods | head -5

# Check socket permissions
ls -la /var/tmp/spdk.sock
srwxr-xr-x 1 root root 0 Jan 1 12:00 /var/tmp/spdk.sock

# Verify SPDK process is listening
lsof /var/tmp/spdk.sock
COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
spdk_tgt 1234 root    5u  unix 0x...      0t0  ... /var/tmp/spdk.sock
```

## Common Usage Patterns

### Development Workflow
```bash
# 1. Start SPDK application with RPC enabled
./build/bin/spdk_tgt --wait-for-rpc

# 2. Initialize framework (transitions from STARTUP to RUNTIME)
./scripts/rpc.py framework_start_init

# 3. Create test devices
./scripts/rpc.py bdev_malloc_create 1024 4096 TestDisk1
./scripts/rpc.py bdev_malloc_create 2048 4096 TestDisk2

# 4. Set up storage protocols
./scripts/rpc.py nvmf_create_transport -p '{"trtype": "TCP"}'
./scripts/rpc.py nvmf_create_subsystem nqn.2016-06.io.spdk:cnode1
./scripts/rpc.py nvmf_subsystem_add_ns nqn.2016-06.io.spdk:cnode1 TestDisk1

# 5. Monitor and manage
./scripts/rpc.py bdev_get_bdevs
./scripts/rpc.py nvmf_get_subsystems
```

### Production Monitoring
```bash
#!/bin/bash
RPC_CMD="./scripts/rpc.py -t 30.0 -r 3"

# Health check function
check_spdk_health() {
    # Test RPC connectivity
    if ! $RPC_CMD rpc_get_methods >/dev/null 2>&1; then
        echo "ERROR: RPC server not responding"
        return 1
    fi
    
    # Check framework status
    VERSION=$(${RPC_CMD} spdk_get_version)
    echo "SPDK Version: $(echo $VERSION | jq -r .version)"
    
    # Monitor bdev count
    BDEV_COUNT=$(${RPC_CMD} bdev_get_bdevs | jq length)
    echo "Active block devices: $BDEV_COUNT"
    
    return 0
}

check_spdk_health
```

### Configuration Management
```bash
# Export current configuration
./scripts/rpc.py framework_get_config > spdk_config.json

# Batch operations from file
while IFS= read -r cmd; do
    echo "Executing: $cmd"
    eval "./scripts/rpc.py $cmd"
done < commands.txt

# Conditional operations
if ./scripts/rpc.py bdev_get_bdevs | jq -e '.[] | select(.name=="TestDisk")' > /dev/null; then
    echo "TestDisk exists, skipping creation"
else
    echo "Creating TestDisk"
    ./scripts/rpc.py bdev_malloc_create 1024 4096 TestDisk
fi
```

## Client Implementation Details

### Python Client Architecture
**Source**: `scripts/rpc/client.py:38`

```python
class JSONRPCClient:
    def __init__(self, addr, port=None, timeout=60.0, **kwargs):
        # Auto-detect transport type (Unix/IPv4/IPv6)
        # Setup connection with retry logic
        # Configure logging and timeouts

    def call(self, method, params=None):
        # Format JSON-RPC 2.0 request
        # Send over transport
        # Handle response/error parsing
        # Return result or raise JSONRPCException
```

### Transport Auto-Detection
**Source**: `scripts/rpc/client.py:17`

```python
def get_addr_type(addr):
    try:
        socket.inet_pton(socket.AF_INET, addr)   # Try IPv4
        return socket.AF_INET
    except:
        pass
    try:
        socket.inet_pton(socket.AF_INET6, addr)  # Try IPv6  
        return socket.AF_INET6
    except:
        pass
    if os.path.exists(addr):                     # Unix socket file
        return socket.AF_UNIX
    return None
```

---

**Related Documentation:**
- **[[SPDK RPC Method Registry]]** - Complete method reference with parameters
- **[[SPDK RPC Architecture]]** - Transport layer implementation details  
- **[[SPDK RPC Testing Examples]]** - Test automation examples
- **[[Custom RPC Development Guide]]** - Creating Python plugins

**Key Files:**
- `scripts/rpc.py` - Main client interface
- `scripts/rpc/client.py` - Core client implementation
- `scripts/rpc/` - Method-specific modules