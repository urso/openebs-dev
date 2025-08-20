---
title: Custom RPC Development Guide
type: note
permalink: spdk/rpc/development/custom-rpc-development-guide
---

# Custom RPC Development Guide

## Overview

SPDK applications can register custom RPC methods using the same infrastructure that built-in methods use. This enables applications to expose application-specific management interfaces while leveraging SPDK's robust JSON-RPC transport, parameter validation, and error handling.

## Registration API

### Handler Function Signature

```c
// include/spdk/rpc.h:82
typedef void (*spdk_rpc_method_handler)(struct spdk_jsonrpc_request *request,
                                        const struct spdk_json_val *params);
```

### Registration Functions

```c
// Direct registration - include/spdk/rpc.h:93
void spdk_rpc_register_method(const char *method, 
                              spdk_rpc_method_handler func,
                              uint32_t state_mask);

// Convenience macro - include/spdk/rpc.h:124
#define SPDK_RPC_REGISTER(method, func, state_mask) \
static void __attribute__((constructor(1000))) rpc_register_##func(void) \
{ \
    spdk_rpc_register_method(method, func, state_mask); \
}

// Deprecated alias registration - include/spdk/rpc.h:102
void spdk_rpc_register_alias_deprecated(const char *method, const char *alias);
```

## Basic RPC Method Template

```c
#include "spdk/rpc.h"
#include "spdk/util.h"
#include "spdk/log.h"

// Parameter structure
struct my_rpc_params {
    char *name;
    uint32_t value;
    bool enabled;
};

// Parameter cleanup
static void
free_my_rpc_params(struct my_rpc_params *params)
{
    free(params->name);
}

// JSON parameter decoders
static const struct spdk_json_object_decoder my_rpc_decoders[] = {
    {"name", offsetof(struct my_rpc_params, name), spdk_json_decode_string},
    {"value", offsetof(struct my_rpc_params, value), spdk_json_decode_uint32},
    {"enabled", offsetof(struct my_rpc_params, enabled), spdk_json_decode_bool, true}, // optional
};

// RPC method implementation
static void
my_custom_rpc_method(struct spdk_jsonrpc_request *request,
                     const struct spdk_json_val *params)
{
    struct my_rpc_params req = {};
    struct spdk_json_write_ctx *w;
    int rc;

    // 1. Parameter parsing (if method accepts parameters)
    if (params != NULL) {
        if (spdk_json_decode_object(params, my_rpc_decoders,
                                    SPDK_COUNTOF(my_rpc_decoders), &req)) {
            SPDK_ERRLOG("spdk_json_decode_object failed\n");
            spdk_jsonrpc_send_error_response(request, 
                                           SPDK_JSONRPC_ERROR_INVALID_PARAMS,
                                           "Invalid parameters");
            return;
        }
    }

    // 2. Business logic implementation
    rc = my_application_operation(req.name, req.value, req.enabled);
    if (rc != 0) {
        spdk_jsonrpc_send_error_response(request, rc, spdk_strerror(-rc));
        goto cleanup;
    }

    // 3. Success response
    w = spdk_jsonrpc_begin_result(request);
    spdk_json_write_object_begin(w);
    spdk_json_write_named_string(w, "result", "success");
    spdk_json_write_named_string(w, "name", req.name);
    spdk_json_write_named_uint32(w, "processed_value", req.value);
    spdk_json_write_object_end(w);
    spdk_jsonrpc_end_result(request, w);

cleanup:
    free_my_rpc_params(&req);
}

// Register the method
SPDK_RPC_REGISTER("my_custom_method", my_custom_rpc_method, SPDK_RPC_RUNTIME)
```

## State Mask Selection

### Available States

```c
#define SPDK_RPC_STARTUP  0x1  // During initialization
#define SPDK_RPC_RUNTIME  0x2  // After framework starts
```

### State Mask Guidelines

```c
// Startup-only methods (configuration, global settings)
SPDK_RPC_REGISTER("my_app_set_config", my_set_config, SPDK_RPC_STARTUP)

// Runtime-only methods (operational commands)
SPDK_RPC_REGISTER("my_app_get_stats", my_get_stats, SPDK_RPC_RUNTIME)

// Always available methods (status, introspection)
SPDK_RPC_REGISTER("my_app_get_version", my_get_version, SPDK_RPC_STARTUP | SPDK_RPC_RUNTIME)
```

## Parameter Handling Patterns

### No Parameters
```c
static void
simple_rpc_method(struct spdk_jsonrpc_request *request,
                  const struct spdk_json_val *params)
{
    // Reject any parameters
    if (params != NULL) {
        spdk_jsonrpc_send_error_response(request, SPDK_JSONRPC_ERROR_INVALID_PARAMS,
                                         "Method requires no parameters");
        return;
    }

    // Implementation...
    struct spdk_json_write_ctx *w = spdk_jsonrpc_begin_result(request);
    spdk_json_write_string(w, "success");
    spdk_jsonrpc_end_result(request, w);
}
```

### Optional Parameters  
```c
static const struct spdk_json_object_decoder optional_decoders[] = {
    {"required_param", offsetof(struct params, required), spdk_json_decode_string},
    {"optional_param", offsetof(struct params, optional), spdk_json_decode_uint32, true}, // true = optional
};

static void
optional_params_method(struct spdk_jsonrpc_request *request,
                       const struct spdk_json_val *params)
{
    struct params req = {.optional = 42}; // default value

    if (params && spdk_json_decode_object(params, optional_decoders,
                                          SPDK_COUNTOF(optional_decoders), &req)) {
        // Handle error...
    }
    // Use req.required (always present) and req.optional (default or user value)
}
```

### Array Parameters
```c
struct array_params {
    char **names;
    size_t names_count;
    uint32_t *values;
    size_t values_count;
};

static const struct spdk_json_object_decoder array_decoders[] = {
    {"names", offsetof(struct array_params, names), spdk_json_decode_array_of_strings},
    {"values", offsetof(struct array_params, values), spdk_json_decode_array_of_uint32},
};

static void
array_params_method(struct spdk_jsonrpc_request *request,
                    const struct spdk_json_val *params)
{
    struct array_params req = {};
    
    // After decoding, req.names is allocated array of strings
    // req.names_count contains the array size
    // Remember to free req.names and each req.names[i]
}
```

## Response Patterns

### Simple Success Response
```c
// Boolean response
spdk_jsonrpc_send_bool_response(request, true);

// String response  
w = spdk_jsonrpc_begin_result(request);
spdk_json_write_string(w, "Operation completed");
spdk_jsonrpc_end_result(request, w);
```

### Object Response
```c
w = spdk_jsonrpc_begin_result(request);
spdk_json_write_object_begin(w);
spdk_json_write_named_string(w, "status", "running");
spdk_json_write_named_uint32(w, "pid", getpid());
spdk_json_write_named_uint64(w, "uptime_ms", get_uptime_ms());
spdk_json_write_named_bool(w, "ready", is_ready());
spdk_json_write_object_end(w);
spdk_jsonrpc_end_result(request, w);
```

### Array Response
```c
w = spdk_jsonrpc_begin_result(request);
spdk_json_write_array_begin(w);

// Array of objects
for (int i = 0; i < count; i++) {
    spdk_json_write_object_begin(w);
    spdk_json_write_named_string(w, "name", items[i].name);
    spdk_json_write_named_uint32(w, "id", items[i].id);
    spdk_json_write_object_end(w);
}

spdk_json_write_array_end(w);
spdk_jsonrpc_end_result(request, w);
```

## Error Handling

### Standard Error Codes
```c
// JSON-RPC 2.0 standard errors
SPDK_JSONRPC_ERROR_PARSE_ERROR       // -32700
SPDK_JSONRPC_ERROR_INVALID_REQUEST   // -32600  
SPDK_JSONRPC_ERROR_METHOD_NOT_FOUND  // -32601
SPDK_JSONRPC_ERROR_INVALID_PARAMS    // -32602
SPDK_JSONRPC_ERROR_INTERNAL_ERROR    // -32603

// SPDK-specific errors
SPDK_JSONRPC_ERROR_INVALID_STATE     // -1
```

### Error Response Patterns
```c
// Simple error with message
spdk_jsonrpc_send_error_response(request, SPDK_JSONRPC_ERROR_INVALID_PARAMS,
                                 "Parameter 'name' is required");

// Error with formatted message
spdk_jsonrpc_send_error_response_fmt(request, SPDK_JSONRPC_ERROR_INTERNAL_ERROR,
                                   "Operation failed with code %d", error_code);

// System error (uses errno codes)
spdk_jsonrpc_send_error_response(request, -ENOMEM, "Out of memory");

// Custom error with context
w = spdk_jsonrpc_begin_error_response(request, SPDK_JSONRPC_ERROR_INVALID_PARAMS);
spdk_json_write_object_begin(w);
spdk_json_write_named_string(w, "message", "Validation failed");
spdk_json_write_named_array_begin(w, "errors");
spdk_json_write_string(w, "Field 'name' is required");
spdk_json_write_string(w, "Field 'value' must be positive");
spdk_json_write_array_end(w);
spdk_json_write_object_end(w);
spdk_jsonrpc_end_error_response(request, w);
```

## Asynchronous Operations

### Callback-Based Completion
```c
struct async_rpc_ctx {
    struct spdk_jsonrpc_request *request;
    char *operation_id;
};

static void
async_operation_complete(void *cb_arg, int status)
{
    struct async_rpc_ctx *ctx = cb_arg;
    struct spdk_json_write_ctx *w;

    if (status != 0) {
        spdk_jsonrpc_send_error_response(ctx->request, status, spdk_strerror(-status));
    } else {
        w = spdk_jsonrpc_begin_result(ctx->request);
        spdk_json_write_object_begin(w);
        spdk_json_write_named_string(w, "operation_id", ctx->operation_id);
        spdk_json_write_named_string(w, "status", "completed");
        spdk_json_write_object_end(w);
        spdk_jsonrpc_end_result(ctx->request, w);
    }

    free(ctx->operation_id);
    free(ctx);
}

static void
async_rpc_method(struct spdk_jsonrpc_request *request,
                 const struct spdk_json_val *params)
{
    struct async_rpc_ctx *ctx;
    
    ctx = calloc(1, sizeof(*ctx));
    ctx->request = request;
    ctx->operation_id = strdup("op123");
    
    // Start async operation
    int rc = start_async_operation(async_operation_complete, ctx);
    if (rc != 0) {
        spdk_jsonrpc_send_error_response(request, rc, spdk_strerror(-rc));
        free(ctx->operation_id);
        free(ctx);
    }
    // Request will be completed asynchronously via callback
}
```

## Integration with SPDK Applications

### Application Initialization
```c
int main(int argc, char **argv) {
    // 1. Initialize SPDK
    struct spdk_app_opts opts = {};
    spdk_app_opts_init(&opts, sizeof(opts));
    
    // 2. Custom RPC methods are registered via constructors before main()
    
    // 3. Start SPDK application (RPC server starts automatically)
    return spdk_app_start(&opts, my_app_start, NULL);
}

static void
my_app_start(void *arg)
{
    // Application-specific initialization
    // RPC methods are now available for external clients
}
```

### Build System Integration
```makefile
# Makefile for external application with custom RPC
SPDK_ROOT_DIR := /path/to/spdk
include $(SPDK_ROOT_DIR)/mk/spdk.common.mk

APP = my_spdk_app
SRCS = main.c my_rpc_methods.c

# Link against SPDK RPC libraries
SPDK_LIB_LIST = rpc jsonrpc log thread util

include $(SPDK_ROOT_DIR)/mk/spdk.app.mk
```

## Python Client Plugin Development

### Plugin Structure
```python
# my_plugin.py
from rpc.client import print_json

def my_custom_method(args):
    """Call custom RPC method"""
    params = {
        'name': args.name,
        'value': args.value,
        'enabled': args.enabled
    }
    return args.client.call('my_custom_method', params)

def spdk_rpc_plugin_initialize(subparsers):
    """Plugin initialization - called by rpc.py"""
    p = subparsers.add_parser('my_custom_method', 
                             help='Call my custom RPC method')
    p.add_argument('name', help='Name parameter')
    p.add_argument('value', type=int, help='Value parameter')  
    p.add_argument('--enabled', action='store_true', help='Enable flag')
    p.set_defaults(func=my_custom_method)
```

### Plugin Usage
```bash
# Use custom plugin
./scripts/rpc.py --plugin my_plugin my_custom_method "test" 42 --enabled

# Output
{
  "result": "success",
  "name": "test", 
  "processed_value": 42
}
```

## Best Practices

### Method Naming
- Use clear, descriptive names: `my_app_get_status` not `get_status`
- Follow SPDK conventions: `component_action_object`  
- Avoid conflicts with built-in methods
- Consider future method additions

### Parameter Design
- Use consistent parameter names across methods
- Provide sensible defaults for optional parameters
- Validate parameter ranges and formats
- Document parameter requirements clearly

### Error Handling
- Use appropriate error codes (standard JSON-RPC or errno)
- Provide descriptive error messages
- Clean up resources in error paths
- Log errors appropriately (SPDK_ERRLOG, SPDK_WARNLOG)

### State Management  
- Choose appropriate state masks
- Document state requirements
- Consider method interactions
- Handle state transitions gracefully

### Performance Considerations
- Minimize work in RPC handlers (use async operations)
- Avoid blocking operations
- Cache frequently accessed data
- Consider memory allocation patterns

### Testing
- Test parameter validation thoroughly
- Test error conditions
- Test state mask enforcement  
- Verify JSON response format
- Test with various clients

## Advanced Topics

### Custom JSON Decoders
```c
// Custom decoder for enum values
static int
decode_my_enum(const struct spdk_json_val *val, void *out)
{
    enum my_enum *result = out;
    
    if (spdk_json_strequal(val, "option1")) {
        *result = MY_ENUM_OPTION1;
    } else if (spdk_json_strequal(val, "option2")) {
        *result = MY_ENUM_OPTION2;  
    } else {
        return SPDK_JSON_PARSE_INVALID;
    }
    return 0;
}

static const struct spdk_json_object_decoder custom_decoders[] = {
    {"mode", offsetof(struct params, mode), decode_my_enum},
};
```

### Method Introspection
```c
// Register method that lists custom methods
static void
my_app_get_methods(struct spdk_jsonrpc_request *request,
                   const struct spdk_json_val *params)
{
    struct spdk_json_write_ctx *w = spdk_jsonrpc_begin_result(request);
    spdk_json_write_array_begin(w);
    spdk_json_write_string(w, "my_app_get_status");
    spdk_json_write_string(w, "my_app_set_config");
    spdk_json_write_string(w, "my_app_get_methods");
    spdk_json_write_array_end(w);
    spdk_jsonrpc_end_result(request, w);
}
SPDK_RPC_REGISTER("my_app_get_methods", my_app_get_methods, 
                  SPDK_RPC_STARTUP | SPDK_RPC_RUNTIME)
```

---

**Related Documentation:**
- **[[SPDK RPC Architecture]]** - Implementation details and data structures
- **[[SPDK RPC External Examples]]** - Working code examples  
- **[[SPDK RPC Method Registry]]** - Built-in methods for reference
- **[[SPDK RPC Client Usage]]** - Testing custom methods

**Key Source Files:**
- `include/spdk/rpc.h` - Registration API
- `test/external_code/passthru/vbdev_passthru_rpc.c` - Complete example
- `scripts/rpc/` - Python plugin examples