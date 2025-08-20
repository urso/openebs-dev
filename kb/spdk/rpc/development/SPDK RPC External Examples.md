---
title: SPDK RPC External Examples
type: note
permalink: spdk/rpc/development/spdk-rpc-external-examples
---

# SPDK RPC External Examples

## Overview

This document provides complete working examples of custom RPC method implementations from the SPDK codebase. These examples demonstrate real-world patterns for parameter handling, asynchronous operations, and integration with SPDK applications.

## Example 1: External Passthrough Bdev RPC

**Source**: `test/external_code/passthru/vbdev_passthru_rpc.c`
**Purpose**: External module demonstrating custom bdev RPC methods

### Complete Implementation

```c
/*
 * External passthrough bdev RPC methods
 * Demonstrates parameter handling and bdev integration
 */

#include "vbdev_passthru.h"
#include "spdk/rpc.h"
#include "spdk/util.h"
#include "spdk/string.h"
#include "spdk/log.h"

/* Parameter structure for create operation */
struct rpc_bdev_passthru_create {
    char *base_bdev_name;  // Base bdev to wrap
    char *name;            // New passthru bdev name
};

/* Clean up allocated parameters */
static void
free_rpc_bdev_passthru_create(struct rpc_bdev_passthru_create *r)
{
    free(r->base_bdev_name);
    free(r->name);
}

/* JSON parameter decoders */
static const struct spdk_json_object_decoder rpc_bdev_passthru_create_decoders[] = {
    {"base_bdev_name", offsetof(struct rpc_bdev_passthru_create, base_bdev_name), 
     spdk_json_decode_string},
    {"name", offsetof(struct rpc_bdev_passthru_create, name), 
     spdk_json_decode_string},
};

/* RPC method: Create external passthru bdev */
static void
rpc_bdev_passthru_create(struct spdk_jsonrpc_request *request,
                         const struct spdk_json_val *params)
{
    struct rpc_bdev_passthru_create req = {};
    struct spdk_json_write_ctx *w;
    int rc;

    /* Parse and validate parameters */
    if (spdk_json_decode_object(params, rpc_bdev_passthru_create_decoders,
                                SPDK_COUNTOF(rpc_bdev_passthru_create_decoders),
                                &req)) {
        SPDK_DEBUGLOG(vbdev_passthru, "spdk_json_decode_object failed\n");
        spdk_jsonrpc_send_error_response(request, SPDK_JSONRPC_ERROR_INTERNAL_ERROR,
                                         "spdk_json_decode_object failed");
        goto cleanup;
    }

    /* Execute the business logic */
    rc = bdev_passthru_external_create_disk(req.base_bdev_name, req.name);
    if (rc != 0) {
        spdk_jsonrpc_send_error_response(request, rc, spdk_strerror(-rc));
        goto cleanup;
    }

    /* Send success response with created bdev name */
    w = spdk_jsonrpc_begin_result(request);
    spdk_json_write_string(w, req.name);
    spdk_jsonrpc_end_result(request, w);

cleanup:
    free_rpc_bdev_passthru_create(&req);
}

/* Register create method - runtime only */
SPDK_RPC_REGISTER("construct_ext_passthru_bdev", rpc_bdev_passthru_create, SPDK_RPC_RUNTIME)

/* Parameter structure for delete operation */
struct rpc_bdev_passthru_delete {
    char *name;
};

static void
free_rpc_bdev_passthru_delete(struct rpc_bdev_passthru_delete *req)
{
    free(req->name);
}

static const struct spdk_json_object_decoder rpc_bdev_passthru_delete_decoders[] = {
    {"name", offsetof(struct rpc_bdev_passthru_delete, name), spdk_json_decode_string},
};

/* Async callback for delete operation */
static void
rpc_bdev_passthru_delete_cb(void *cb_arg, int bdeverrno)
{
    struct spdk_jsonrpc_request *request = cb_arg;
    
    /* Send boolean response indicating success/failure */
    spdk_jsonrpc_send_bool_response(request, bdeverrno == 0);
}

/* RPC method: Delete external passthru bdev */
static void
rpc_bdev_passthru_delete(struct spdk_jsonrpc_request *request,
                         const struct spdk_json_val *params)
{
    struct rpc_bdev_passthru_delete req = {};

    /* Parse parameters */
    if (spdk_json_decode_object(params, rpc_bdev_passthru_delete_decoders,
                                SPDK_COUNTOF(rpc_bdev_passthru_delete_decoders),
                                &req)) {
        spdk_jsonrpc_send_error_response(request, SPDK_JSONRPC_ERROR_INVALID_PARAMS,
                                         "Invalid parameters");
        goto cleanup;
    }

    /* Start async delete operation - callback completes the RPC */
    bdev_passthru_external_delete_disk(req.name, rpc_bdev_passthru_delete_cb, request);

cleanup:
    free_rpc_bdev_passthru_delete(&req);
}

/* Register delete method */
SPDK_RPC_REGISTER("delete_ext_passthru_bdev", rpc_bdev_passthru_delete, SPDK_RPC_RUNTIME)
```

### Usage Examples

```bash
# Create external passthru bdev
./scripts/rpc.py construct_ext_passthru_bdev -p '{
    "base_bdev_name": "Malloc0",
    "name": "PassthruExt0"
}'
# Response: "PassthruExt0"

# Delete external passthru bdev  
./scripts/rpc.py delete_ext_passthru_bdev -p '{
    "name": "PassthruExt0"
}'
# Response: true

# Error case - missing parameter
./scripts/rpc.py construct_ext_passthru_bdev -p '{
    "base_bdev_name": "Malloc0"
}'
# Response: {"jsonrpc": "2.0", "error": {"code": -32603, "message": "spdk_json_decode_object failed"}, "id": 1}
```

### Key Implementation Details

1. **Parameter Structures**: Clean separation of parameters from business logic
2. **Memory Management**: Proper cleanup in all code paths
3. **Error Handling**: Specific error codes and messages
4. **Async Operations**: Callback-based completion for delete operation
5. **State Mask**: Runtime-only methods (requires initialized framework)

## Example 2: Vhost Fuzzing RPC Methods

**Source**: `test/app/fuzz/vhost_fuzz/vhost_fuzz_rpc.c`
**Purpose**: Application-specific RPC methods for fuzzing functionality

### Fuzzing Device Creation

```c
#include "spdk/stdinc.h"
#include "spdk/rpc.h"
#include "spdk/util.h"
#include "vhost_fuzz.h"

/* Complex parameter structure with multiple options */
struct rpc_fuzz_vhost_dev_create {
    char    *socket;            // vHost socket path
    bool    is_blk;            // Block device vs SCSI
    bool    use_bogus_buffer;   // Use invalid buffer for testing
    bool    use_valid_buffer;   // Use valid buffer
    bool    valid_lun;         // Valid LUN configuration
    bool    test_scsi_tmf;     // Test SCSI task management
};

/* Comprehensive parameter decoders with optional flags */
static const struct spdk_json_object_decoder rpc_fuzz_vhost_dev_create_decoders[] = {
    {"socket", offsetof(struct rpc_fuzz_vhost_dev_create, socket), 
     spdk_json_decode_string},
    {"is_blk", offsetof(struct rpc_fuzz_vhost_dev_create, is_blk), 
     spdk_json_decode_bool, true},  // optional
    {"use_bogus_buffer", offsetof(struct rpc_fuzz_vhost_dev_create, use_bogus_buffer), 
     spdk_json_decode_bool, true},  // optional
    {"use_valid_buffer", offsetof(struct rpc_fuzz_vhost_dev_create, use_valid_buffer), 
     spdk_json_decode_bool, true},  // optional
    {"valid_lun", offsetof(struct rpc_fuzz_vhost_dev_create, valid_lun), 
     spdk_json_decode_bool, true},  // optional
    {"test_scsi_tmf", offsetof(struct rpc_fuzz_vhost_dev_create, test_scsi_tmf), 
     spdk_json_decode_bool, true},  // optional
};

/* RPC method with complex logic and multiple response types */
static void
spdk_rpc_fuzz_vhost_create_dev(struct spdk_jsonrpc_request *request,
                               const struct spdk_json_val *params)
{
    struct rpc_fuzz_vhost_dev_create req = {};
    struct spdk_json_write_ctx *w;
    int rc;

    /* Decode parameters with default values for optional fields */
    if (params != NULL) {
        if (spdk_json_decode_object(params, rpc_fuzz_vhost_dev_create_decoders,
                                    SPDK_COUNTOF(rpc_fuzz_vhost_dev_create_decoders),
                                    &req)) {
            SPDK_ERRLOG("spdk_json_decode_object failed\n");
            spdk_jsonrpc_send_error_response(request, SPDK_JSONRPC_ERROR_INVALID_PARAMS,
                                             "Invalid parameters");
            return;
        }
    }

    /* Validate parameter combinations */
    if (req.socket == NULL) {
        spdk_jsonrpc_send_error_response(request, -EINVAL, "Socket path required");
        goto cleanup;
    }

    /* Execute fuzzing-specific device creation */
    rc = fuzz_vhost_dev_create(req.socket, req.is_blk, req.use_bogus_buffer,
                               req.use_valid_buffer, req.valid_lun, req.test_scsi_tmf);
    if (rc != 0) {
        spdk_jsonrpc_send_error_response_fmt(request, rc,
                                           "Failed to create fuzzing device: %s",
                                           spdk_strerror(-rc));
        goto cleanup;
    }

    /* Success response with device information */
    w = spdk_jsonrpc_begin_result(request);
    spdk_json_write_object_begin(w);
    spdk_json_write_named_string(w, "socket", req.socket);
    spdk_json_write_named_string(w, "type", req.is_blk ? "block" : "scsi");
    spdk_json_write_named_bool(w, "fuzz_enabled", true);
    spdk_json_write_object_end(w);
    spdk_jsonrpc_end_result(request, w);

cleanup:
    free(req.socket);
}

/* Register as startup method - available during initialization */
SPDK_RPC_REGISTER("fuzz_vhost_create_dev", spdk_rpc_fuzz_vhost_create_dev, SPDK_RPC_STARTUP);
```

### Usage Examples

```bash
# Create basic vhost fuzzing device
./scripts/rpc.py fuzz_vhost_create_dev -p '{
    "socket": "/tmp/vhost.1"
}'

# Create block device with fuzzing options
./scripts/rpc.py fuzz_vhost_create_dev -p '{
    "socket": "/tmp/vhost.1",
    "is_blk": true,
    "use_bogus_buffer": true,
    "valid_lun": false
}'

# Create SCSI device with task management testing
./scripts/rpc.py fuzz_vhost_create_dev -p '{
    "socket": "/tmp/vhost.1", 
    "is_blk": false,
    "test_scsi_tmf": true,
    "valid_lun": true
}'
```

### Response Examples

```json
// Success response
{
  "socket": "/tmp/vhost.1",
  "type": "block",
  "fuzz_enabled": true
}

// Error response - missing socket
{
  "jsonrpc": "2.0",
  "error": {
    "code": -22,
    "message": "Socket path required"
  },
  "id": 1
}
```

## Example 3: Python RPC Plugin

**Source**: `test/rpc/rpc_plugin.py`
**Purpose**: Client-side Python plugin for custom RPC methods

### Plugin Implementation

```python
from rpc.client import print_json

def malloc_create(args):
    """Create malloc bdev with fixed parameters"""
    params = {
        'num_blocks': 256,
        'block_size': 4096
    }
    return args.client.call('bdev_malloc_create', params)

def malloc_delete(args):
    """Delete malloc bdev by name"""
    params = {
        'name': args.name
    }
    return args.client.call('bdev_malloc_delete', params)

def create_malloc(args):
    """Wrapper function that prints result"""
    print_json(malloc_create(args))

def spdk_rpc_plugin_initialize(subparsers):
    """
    Plugin initialization function called by rpc.py
    Must be named exactly 'spdk_rpc_plugin_initialize'
    """
    # Add 'create_malloc' command
    p = subparsers.add_parser('create_malloc', help='Create malloc backend')
    p.set_defaults(func=create_malloc)

    # Add 'delete_malloc' command with arguments
    p = subparsers.add_parser('delete_malloc', help='Delete malloc backend')
    p.add_argument('name', help='malloc bdev name')
    p.set_defaults(func=malloc_delete)
```

### Plugin Usage

```bash
# Load plugin and create malloc bdev
./scripts/rpc.py --plugin rpc_plugin create_malloc
# Output: "Malloc0"

# Delete the created bdev
./scripts/rpc.py --plugin rpc_plugin delete_malloc Malloc0
# Output: true

# Plugin help
./scripts/rpc.py --plugin rpc_plugin create_malloc --help
./scripts/rpc.py --plugin rpc_plugin delete_malloc --help
```

### Advanced Plugin Example

```python
# advanced_plugin.py
from rpc.client import print_json, print_dict
import json

def get_system_info(args):
    """Gather comprehensive system information"""
    client = args.client
    
    # Gather data from multiple RPC calls
    version = client.call('spdk_get_version')
    bdevs = client.call('bdev_get_bdevs')
    methods = client.call('rpc_get_methods', {'current': True})
    
    # Process and combine data
    info = {
        'spdk_version': version['version'],
        'bdev_count': len(bdevs),
        'available_methods': len(methods),
        'bdevs': [{'name': b['name'], 'size_mb': b['num_blocks'] * b['block_size'] // 1024 // 1024} 
                 for b in bdevs]
    }
    
    return info

def stress_test_bdevs(args):
    """Create multiple test bdevs for stress testing"""
    client = args.client
    results = []
    
    for i in range(args.count):
        name = f"StressTest{i}"
        try:
            result = client.call('bdev_malloc_create', {
                'num_blocks': args.blocks,
                'block_size': args.block_size,
                'name': name
            })
            results.append({'name': name, 'status': 'created', 'result': result})
        except Exception as e:
            results.append({'name': name, 'status': 'failed', 'error': str(e)})
    
    return results

def spdk_rpc_plugin_initialize(subparsers):
    # System info command
    p = subparsers.add_parser('get_system_info', 
                             help='Get comprehensive system information')
    p.set_defaults(func=lambda args: print_dict(get_system_info(args)))
    
    # Stress testing command
    p = subparsers.add_parser('stress_test_bdevs',
                             help='Create multiple test bdevs')
    p.add_argument('count', type=int, help='Number of bdevs to create')
    p.add_argument('--blocks', type=int, default=1024, help='Blocks per bdev')
    p.add_argument('--block-size', type=int, default=4096, help='Block size')
    p.set_defaults(func=lambda args: print_dict(stress_test_bdevs(args)))
```

## Build System Integration

### External Module Makefile

**Source**: `test/external_code/Makefile`

```makefile
# Makefile for external SPDK application with custom RPC
SPDK_ROOT_DIR := $(abspath $(CURDIR)/../../..)
include $(SPDK_ROOT_DIR)/mk/spdk.common.mk

# Application configuration
APP = passthru_external
C_SRCS := hello_bdev.c
C_SRCS += vbdev_passthru.c vbdev_passthru_rpc.c

# SPDK library dependencies
SPDK_LIB_LIST = event bdev
SPDK_LIB_LIST += event_bdev
SPDK_LIB_LIST += log rpc jsonrpc thread util

# Linker flags for different build types
ifeq ($(SPDK_LIB_DIR),)
# Static linking
SPDK_LIB_LIST += env_dpdk
LDFLAGS += -Wl,--whole-archive -Wl,--no-as-needed
LDFLAGS += -Wl,--no-whole-archive -Wl,--as-needed
else
# Shared library linking
LDFLAGS += -L$(SPDK_LIB_DIR)
LDFLAGS += -Wl,-rpath=$(SPDK_LIB_DIR)
endif

include $(SPDK_ROOT_DIR)/mk/spdk.app.mk

# Custom targets
.PHONY: test
test: $(APP)
	./$(APP) --wait-for-rpc &
	sleep 1
	./test_rpc.sh
	pkill -f $(APP)

.PHONY: clean
clean:
	$(CLEAN_C) $(APP) $(CLEAN_FILES)
```

### Test Script Example

```bash
#!/bin/bash
# test_rpc.sh - Test external RPC methods

RPC_CMD="../../../scripts/rpc.py"

# Test framework startup
${RPC_CMD} framework_start_init

# Create base bdev
MALLOC=$(${RPC_CMD} bdev_malloc_create 1024 4096)
echo "Created malloc bdev: $MALLOC"

# Test custom RPC method
PASSTHRU=$(${RPC_CMD} construct_ext_passthru_bdev -p "{
    \"base_bdev_name\": \"$MALLOC\",
    \"name\": \"PassthruExt0\"
}")
echo "Created passthru bdev: $PASSTHRU"

# Verify bdev exists
${RPC_CMD} bdev_get_bdevs | jq ".[] | select(.name==\"PassthruExt0\")"

# Clean up
${RPC_CMD} delete_ext_passthru_bdev -p "{\"name\": \"PassthruExt0\"}"
${RPC_CMD} bdev_malloc_delete "$MALLOC"

echo "Test completed successfully"
```

## Testing Patterns

### Unit Test Integration

```c
// Custom RPC method unit tests
#include "spdk/stdinc.h"
#include "CUnit/Basic.h"
#include "spdk/rpc.h"

static void
test_custom_rpc_registration(void)
{
    // Test that our methods are properly registered
    CU_ASSERT(spdk_rpc_is_method_allowed("my_custom_method", SPDK_RPC_RUNTIME) == 0);
    CU_ASSERT(spdk_rpc_is_method_allowed("my_custom_method", SPDK_RPC_STARTUP) == -EPERM);
}

static void  
test_parameter_validation(void)
{
    // Test parameter validation logic
    struct my_rpc_params params = {};
    const char *json = "{\"name\":\"test\",\"value\":42}";
    
    // Parse JSON and validate
    CU_ASSERT(parse_and_validate_params(json, &params) == 0);
    CU_ASSERT_STRING_EQUAL(params.name, "test");
    CU_ASSERT_EQUAL(params.value, 42);
}

int main(void)
{
    CU_pSuite suite = NULL;
    
    if (CU_initialize_registry() != CUE_SUCCESS) {
        return CU_get_error();
    }
    
    suite = CU_add_suite("Custom RPC Tests", NULL, NULL);
    if (suite == NULL) {
        CU_cleanup_registry();
        return CU_get_error();
    }
    
    if (CU_add_test(suite, "test_registration", test_custom_rpc_registration) == NULL ||
        CU_add_test(suite, "test_validation", test_parameter_validation) == NULL) {
        CU_cleanup_registry();
        return CU_get_error();
    }
    
    CU_basic_set_mode(CU_BRM_VERBOSE);
    CU_basic_run_tests();
    CU_cleanup_registry();
    
    return CU_get_error();
}
```

## Common Patterns Summary

### Parameter Handling
1. **Structure Definition**: Clean parameter structs with appropriate types
2. **JSON Decoders**: Use SPDK's decoder framework for validation  
3. **Memory Management**: Always clean up allocated parameters
4. **Optional Parameters**: Mark optional fields in decoder array
5. **Validation**: Check parameter combinations and ranges

### Response Generation
1. **Simple Responses**: Use convenience functions for common types
2. **Object Responses**: Build complex JSON objects with proper nesting
3. **Error Responses**: Use appropriate error codes and descriptive messages
4. **Async Responses**: Handle completion via callbacks

### State Management
1. **State Masks**: Choose appropriate startup/runtime availability
2. **Method Interactions**: Consider dependencies between methods
3. **Error States**: Handle partial failure scenarios gracefully

### Integration
1. **Build System**: Proper library dependencies and linking
2. **Testing**: Comprehensive test coverage including error cases
3. **Documentation**: Clear usage examples and parameter descriptions

---

**Related Documentation:**
- **[[Custom RPC Development Guide]]** - Complete development patterns and APIs
- **[[SPDK RPC Architecture]]** - Implementation details and data structures
- **[[SPDK RPC Testing Examples]]** - Testing methodologies

**Key Source Files:**
- `test/external_code/passthru/vbdev_passthru_rpc.c` - Complete external bdev example
- `test/app/fuzz/vhost_fuzz/vhost_fuzz_rpc.c` - Application-specific methods
- `test/rpc/rpc_plugin.py` - Python plugin examples