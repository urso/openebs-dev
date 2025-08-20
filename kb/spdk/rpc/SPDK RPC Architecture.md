---
title: SPDK RPC Architecture
type: note
permalink: spdk/rpc/spdk-rpc-architecture
---

# SPDK RPC Architecture

## Core Implementation Files

### Primary Server Components

**Core RPC Server** - `lib/rpc/rpc.c`
- **Line 54**: `struct spdk_rpc_method` definition
- **Line 67**: State management functions
- **Line 105**: Main request handler (`jsonrpc_handler`)
- **Line 149**: Socket listener setup (`spdk_rpc_listen`)
- **Line 221**: Method registration (`spdk_rpc_register_method`)

**JSON-RPC Transport** - `lib/jsonrpc/`
- **`jsonrpc_server.c:38`**: Core server implementation
- **`jsonrpc_server_tcp.c:38`**: TCP transport layer
- **`jsonrpc_client.c:37`**: Native C client library
- **`jsonrpc_internal.h:43`**: Internal data structures and constants

**Public API** - `include/spdk/rpc.h`
- **Line 82**: Handler function signature
- **Line 93**: Method registration API
- **Line 124**: `SPDK_RPC_REGISTER` convenience macro

## Key Data Structures

### RPC Method Registry

```c
// lib/rpc/rpc.c:54
struct spdk_rpc_method {
    const char *name;                    // RPC method name
    spdk_rpc_method_handler func;        // Handler function pointer
    SLIST_ENTRY(spdk_rpc_method) slist; // Linked list entry
    uint32_t state_mask;                 // When method can be called
    bool is_deprecated;                  // Deprecation flag
    struct spdk_rpc_method *is_alias_of; // Alias resolution pointer
    bool deprecation_warning_printed;    // One-time warning flag
};

// Global registry - lib/rpc/rpc.c:64
static SLIST_HEAD(, spdk_rpc_method) g_rpc_methods = SLIST_HEAD_INITIALIZER(g_rpc_methods);
```

### Transport Layer Configuration

```c
// lib/jsonrpc/jsonrpc_internal.h:43
#define SPDK_JSONRPC_RECV_BUF_SIZE      (32 * 1024)      // 32KB receive buffer
#define SPDK_JSONRPC_SEND_BUF_SIZE_INIT (32 * 1024)      // 32KB initial send
#define SPDK_JSONRPC_SEND_BUF_SIZE_MAX  (32 * 1024 * 1024) // 32MB max send
#define SPDK_JSONRPC_MAX_CONNS          64               // Connection limit
#define SPDK_JSONRPC_MAX_VALUES         1024             // JSON value limit
#define SPDK_JSONRPC_CLIENT_MAX_VALUES  8192             // Client value limit
```

### Server Connection Management

```c
// lib/jsonrpc/jsonrpc_internal.h
struct spdk_jsonrpc_server {
    int listen_fd;                                    // Listening socket
    spdk_jsonrpc_handle_request_fn handle_request;   // Request handler callback
    TAILQ_HEAD(, spdk_jsonrpc_server_conn) free_conns; // Connection pool
    TAILQ_HEAD(, spdk_jsonrpc_server_conn) conns;      // Active connections
    struct spdk_jsonrpc_server_conn conns_array[SPDK_JSONRPC_MAX_CONNS];
};
```

## Request Processing Flow

### 1. Connection Establishment
```c
// lib/rpc/rpc.c:149 - spdk_rpc_listen()
int spdk_rpc_listen(const char *listen_addr) {
    // 1. Setup Unix domain socket address
    // 2. Create lock file to prevent multiple instances  
    // 3. Acquire exclusive lock with flock()
    // 4. Remove stale socket file
    // 5. Create JSON-RPC server with jsonrpc_handler
    g_jsonrpc_server = spdk_jsonrpc_server_listen(AF_UNIX, 0,
                       (struct sockaddr *)&g_rpc_listen_addr_unix,
                       sizeof(g_rpc_listen_addr_unix), jsonrpc_handler);
}
```

### 2. Request Handling Pipeline
```c
// lib/rpc/rpc.c:105 - jsonrpc_handler()
static void jsonrpc_handler(struct spdk_jsonrpc_request *request,
                           const struct spdk_json_val *method,
                           const struct spdk_json_val *params) {
    // 1. Method lookup in global registry
    struct spdk_rpc_method *m = _get_rpc_method(method);
    
    // 2. Handle method not found
    if (m == NULL) {
        spdk_jsonrpc_send_error_response(request, 
                                       SPDK_JSONRPC_ERROR_METHOD_NOT_FOUND,
                                       "Method not found");
        return;
    }
    
    // 3. Resolve aliases and handle deprecation warnings
    if (m->is_alias_of != NULL) {
        if (m->is_deprecated && !m->deprecation_warning_printed) {
            SPDK_WARNLOG("RPC method %s is deprecated. Use %s instead.\n",
                        m->name, m->is_alias_of->name);
            m->deprecation_warning_printed = true;
        }
        m = m->is_alias_of;
    }
    
    // 4. State validation
    if ((m->state_mask & g_rpc_state) == g_rpc_state) {
        m->func(request, params);  // Execute handler
    } else {
        // Send state-specific error message
        spdk_jsonrpc_send_error_response_fmt(request, 
                                           SPDK_JSONRPC_ERROR_INVALID_STATE,
                                           "Method not allowed in current state");
    }
}
```

## Method Registration System

### Automatic Registration Macro
```c
// include/spdk/rpc.h:124
#define SPDK_RPC_REGISTER(method, func, state_mask) \
static void __attribute__((constructor(1000))) rpc_register_##func(void) \
{ \
    spdk_rpc_register_method(method, func, state_mask); \
}
```

**Constructor Priority**: `1000` ensures RPC methods register before aliases (`1001`)

### Registration Implementation
```c
// lib/rpc/rpc.c:221
void spdk_rpc_register_method(const char *method, spdk_rpc_method_handler func, 
                             uint32_t state_mask) {
    // 1. Check for duplicate method names
    struct spdk_rpc_method *m = _get_rpc_method_raw(method);
    if (m != NULL) {
        SPDK_ERRLOG("duplicate RPC %s registered...\n", method);
        g_rpcs_correct = false;
        return;
    }
    
    // 2. Allocate and initialize method structure
    m = calloc(1, sizeof(struct spdk_rpc_method));
    m->name = strdup(method);
    m->func = func;
    m->state_mask = state_mask;
    
    // 3. Add to global registry (TODO: optimize with hash table)
    SLIST_INSERT_HEAD(&g_rpc_methods, m, slist);
}
```

## State Management System

### State Definitions
```c
// include/spdk/rpc.h:115
#define SPDK_RPC_STARTUP  0x1  // Methods callable during initialization
#define SPDK_RPC_RUNTIME  0x2  // Methods callable after framework starts

// Global state tracking - lib/rpc/rpc.c:51
static uint32_t g_rpc_state;
```

### State Transition Control
```c
// State management functions - lib/rpc/rpc.c:67
void spdk_rpc_set_state(uint32_t state) {
    g_rpc_state = state;
}

uint32_t spdk_rpc_get_state(void) {
    return g_rpc_state;
}
```

### State Validation Logic
```c
// Method validation - lib/rpc/rpc.c:127
if ((m->state_mask & g_rpc_state) == g_rpc_state) {
    // Method allowed in current state
    m->func(request, params);
} else {
    // Generate appropriate error message based on current state
    if (g_rpc_state == SPDK_RPC_STARTUP) {
        // "Method may only be called after framework is initialized"
    } else {
        // "Method may only be called before framework is initialized"
    }
}
```

## Transport Layer Architecture

### Unix Domain Socket Transport
```c
// lib/rpc/rpc.c:46-48
static struct sockaddr_un g_rpc_listen_addr_unix = {};
static char g_rpc_lock_path[sizeof(g_rpc_listen_addr_unix.sun_path) + sizeof(".lock")];
static int g_rpc_lock_fd = -1;
```

**File Locking Mechanism**:
1. Create `.lock` file alongside socket
2. Acquire exclusive lock with `flock(LOCK_EX | LOCK_NB)`
3. Prevents multiple SPDK instances on same socket
4. Clean up stale socket files safely

### TCP Transport Support
- **File**: `lib/jsonrpc/jsonrpc_server_tcp.c:38`
- **Features**: IPv4, IPv6, configurable ports
- **Connection**: Managed through same connection pool
- **Security**: No built-in authentication (relies on network security)

## Memory Management

### Connection Pooling
- **Pre-allocated**: 64 connection structures
- **Reuse Strategy**: Free connections moved to pool for reuse
- **Buffer Management**: Dynamic send buffer growth up to 32MB

### JSON Parsing Limits
- **Values per Request**: 1024 (server), 8192 (client)
- **Memory Strategy**: Stack-based JSON value arrays
- **Overflow Handling**: Graceful error responses

## Performance Considerations

### Method Lookup
- **Current**: Linear search through linked list
- **TODO Note** at `lib/rpc/rpc.c:241`: "use a hash table or sorted list"
- **Impact**: O(n) lookup time affects high-frequency RPC usage

### Buffer Management
- **Receive**: Fixed 32KB per connection
- **Send**: Dynamic growth from 32KB to 32MB
- **Strategy**: Optimized for typical JSON-RPC message sizes

## Error Handling

### JSON-RPC 2.0 Error Codes
```c
// Standard error codes used throughout SPDK
SPDK_JSONRPC_ERROR_METHOD_NOT_FOUND  // -32601
SPDK_JSONRPC_ERROR_INVALID_PARAMS    // -32602  
SPDK_JSONRPC_ERROR_INTERNAL_ERROR    // -32603
SPDK_JSONRPC_ERROR_INVALID_STATE     // -1 (SPDK-specific)
```

### Validation and Safety
- **Method Registration**: Duplicate detection
- **Parameter Parsing**: JSON schema validation
- **State Enforcement**: Automatic state mask checking
- **Resource Cleanup**: Proper memory management in error paths

## Integration Points

### Framework Integration
- **Initialization**: RPC server started during SPDK app initialization
- **Event Loop**: Integrated with SPDK's reactor-based event system
- **Thread Safety**: RPC handlers execute in main reactor thread

### Module Integration
- **Automatic Discovery**: Constructor-based registration
- **Load Order**: Priority-based constructor execution
- **Plugin Support**: Dynamic method registration for external modules

---

**Related Documentation:**
- **[[SPDK RPC Method Registry]]** - Complete catalog of available methods
- **[[Custom RPC Development Guide]]** - Using these APIs for custom methods

**Key Source Files:**
- `lib/rpc/rpc.c` - Core server implementation
- `lib/jsonrpc/jsonrpc_server.c` - Transport layer  
- `include/spdk/rpc.h` - Public API definitions