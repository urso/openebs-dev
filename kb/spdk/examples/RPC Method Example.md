---
title: RPC Method Example
type: note
permalink: spdk/examples/rpc-method-example
---

# RPC Method Example

Complete RPC method implementation with JSON parameter parsing and validation.

## Pattern
RPC methods provide management interfaces for SPDK components. They parse JSON parameters and perform configuration operations.

## Code Example

```c
struct rpc_create_device_params {
    char *name;
    uint64_t size_mb;
    bool enable_feature;
};

static const struct spdk_json_object_decoder rpc_create_device_decoders[] = {
    {"name", offsetof(struct rpc_create_device_params, name), spdk_json_decode_string},
    {"size_mb", offsetof(struct rpc_create_device_params, size_mb), spdk_json_decode_uint64},
    {"enable_feature", offsetof(struct rpc_create_device_params, enable_feature), spdk_json_decode_bool, true},
};

static void rpc_create_my_device(struct spdk_jsonrpc_request *request,
                                const struct spdk_json_val *params)
{
    struct rpc_create_device_params req = {};
    
    // Parse JSON parameters
    if (spdk_json_decode_object(params, rpc_create_device_decoders,
                               SPDK_COUNTOF(rpc_create_device_decoders), &req)) {
        spdk_jsonrpc_send_error_response(request, SPDK_JSONRPC_ERROR_INVALID_PARAMS,
                                        "Invalid parameters");
        return;
    }
    
    // Validate parameters
    if (!req.name || req.size_mb == 0) {
        spdk_jsonrpc_send_error_response(request, SPDK_JSONRPC_ERROR_INVALID_PARAMS,
                                        "Name and size are required");
        free(req.name);
        return;
    }
    
    // Perform the operation
    int rc = create_my_device(req.name, req.size_mb, req.enable_feature);
    if (rc != 0) {
        spdk_jsonrpc_send_error_response(request, SPDK_JSONRPC_ERROR_INTERNAL_ERROR,
                                        spdk_strerror(-rc));
    } else {
        spdk_jsonrpc_send_bool_response(request, true);
    }
    
    free(req.name);
}

SPDK_RPC_REGISTER("create_my_device", rpc_create_my_device, SPDK_RPC_RUNTIME)
```

## Key Points
- Always validate input parameters thoroughly
- Free allocated strings and resources before returning
- Use appropriate error codes (`INVALID_PARAMS`, `INTERNAL_ERROR`)
- Register with the correct state mask (`STARTUP`, `RUNTIME`, `SHUTDOWN`)