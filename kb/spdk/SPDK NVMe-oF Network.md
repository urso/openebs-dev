---
title: SPDK NVMe-oF Network
type: note
permalink: spdk/spdk-nvme-o-f-network
tags:
- '["spdk"'
- '"nvme-of"'
- '"network"'
- '"transport"'
- '"listener"'
- '"tcp"'
- '"rdma"]'
---

# SPDK NVMe-oF Network Integration

This document covers NVMe-oF network architecture, including transport configuration, listener setup, and network connectivity patterns.

## Network Architecture Overview

NVMe-oF uses a **two-layer network architecture** to provide flexible network connectivity:

1. **Transport Layer** - Protocol handling (TCP, RDMA, FC) - global resources
2. **Listener Layer** - Network endpoints - per-subsystem resources

This design enables a single NVMe-oF target to serve multiple storage subsystems over various network interfaces and protocols simultaneously.

## Transport Layer - Protocol Handling

**Transports** handle the actual network protocols (TCP, RDMA, FC) and are **global** resources shared across all subsystems.

### Creating Transports

**API**: `spdk_nvmf_transport_create_async()` in `include/spdk/nvmf.h:1323`

```c
typedef void (*spdk_nvmf_transport_create_done_cb)(void *cb_arg,
                                                  struct spdk_nvmf_transport *transport);

int spdk_nvmf_transport_create_async(const char *transport_name,
                                    struct spdk_nvmf_transport_opts *opts,
                                    spdk_nvmf_transport_create_done_cb cb_fn, 
                                    void *cb_arg);
```

### Transport Creation Example

```c
static void transport_created(void *cb_arg, struct spdk_nvmf_transport *transport)
{
    if (!transport) {
        SPDK_ERRLOG("Failed to create transport\n");
        return;
    }
    // Add transport to target
    spdk_nvmf_tgt_add_transport(tgt, transport, transport_added_cb, cb_arg);
}

static void create_tcp_transport(struct spdk_nvmf_tgt *tgt)
{
    struct spdk_nvmf_transport_opts tcp_opts;
    
    // Initialize with defaults
    spdk_nvmf_transport_opts_init(&tcp_opts, sizeof(tcp_opts));
    
    // Customize options
    tcp_opts.max_queue_depth = 128;
    tcp_opts.max_io_size = 131072;
    tcp_opts.in_capsule_data_size = 8192;
    
    // Create transport asynchronously
    spdk_nvmf_transport_create_async("TCP", &tcp_opts, transport_created, tgt);
}
```

### Adding Transports to Target

**API**: `spdk_nvmf_tgt_add_transport()` in `include/spdk/nvmf.h:1414`

```c
void spdk_nvmf_tgt_add_transport(struct spdk_nvmf_tgt *tgt,
                                struct spdk_nvmf_transport *transport,
                                spdk_nvmf_tgt_add_transport_done_fn cb_fn,
                                void *cb_arg);
```

## Listener Layer - Network Endpoints

**Listeners** bind subsystems to specific network addresses and are **per-subsystem** resources.

### Adding Listeners to Subsystems

**API**: `spdk_nvmf_subsystem_add_listener()` in `include/spdk/nvmf.h:771`

```c
void spdk_nvmf_subsystem_add_listener(struct spdk_nvmf_subsystem *subsystem,
                                     const struct spdk_nvme_transport_id *trid,
                                     spdk_nvmf_tgt_subsystem_listen_done_fn cb_fn,
                                     void *cb_arg);
```

### Listener Configuration Example

```c
static void add_tcp_listener(struct spdk_nvmf_subsystem *subsystem)
{
    struct spdk_nvme_transport_id trid = {};
    
    // Configure TCP listener
    trid.adrfam = SPDK_NVMF_ADRFAM_IPV4;
    trid.trtype = SPDK_NVMF_TRTYPE_TCP;
    snprintf(trid.traddr, sizeof(trid.traddr), "192.168.1.100");
    snprintf(trid.trsvcid, sizeof(trid.trsvcid), "4420");
    
    // Add listener to subsystem
    spdk_nvmf_subsystem_add_listener(subsystem, &trid, listener_added_cb, NULL);
}
```

### Starting Global Listening

**API**: `spdk_nvmf_tgt_listen_ext()` in `include/spdk/nvmf.h:308`

```c
int spdk_nvmf_tgt_listen_ext(struct spdk_nvmf_tgt *tgt, 
                            const struct spdk_nvme_transport_id *trid,
                            struct spdk_nvmf_listen_opts *opts);
```

## Complete Network Setup Workflow

### Comprehensive Setup Example

```c
struct setup_ctx {
    struct spdk_nvmf_tgt *tgt;
    struct spdk_nvmf_subsystem *subsystem;
    struct spdk_nvme_transport_id trid;
};

static void subsystem_started(struct spdk_nvmf_subsystem *subsystem, void *cb_arg, int status)
{
    if (status == 0) {
        SPDK_NOTICELOG("NVMe-oF subsystem ready for connections\n");
    }
}

static void listener_added(void *cb_arg, int status) 
{
    struct setup_ctx *ctx = cb_arg;
    
    if (status != 0) {
        SPDK_ERRLOG("Failed to add listener: %d\n", status);
        return;
    }
    
    // Start global listening on the address
    int rc = spdk_nvmf_tgt_listen_ext(ctx->tgt, &ctx->trid, NULL);
    if (rc != 0) {
        SPDK_ERRLOG("Failed to start listening: %d\n", rc);
        return;
    }
    
    // Start the subsystem (INACTIVE -> ACTIVE)
    spdk_nvmf_subsystem_start(ctx->subsystem, subsystem_started, ctx);
}

static void transport_added(void *cb_arg, int status)
{
    struct setup_ctx *ctx = cb_arg;
    uint32_t nsid;
    
    if (status != 0) {
        SPDK_ERRLOG("Failed to add transport: %d\n", status);
        return;
    }
    
    // Create subsystem (details covered in [[SPDK NVMe-oF Programming]])
    ctx->subsystem = spdk_nvmf_subsystem_create(ctx->tgt,
                                               "nqn.2016-06.io.spdk:storage1",
                                               SPDK_NVMF_SUBTYPE_NVME,
                                               0);
    if (!ctx->subsystem) {
        SPDK_ERRLOG("Failed to create subsystem\n");
        return;
    }
    
    // Add namespace (subsystem starts in INACTIVE state)
    nsid = spdk_nvmf_subsystem_add_ns_ext(ctx->subsystem, "Malloc0", NULL, 0, NULL);
    if (nsid == 0) {
        SPDK_ERRLOG("Failed to add namespace\n");
        return;
    }
    
    // Configure listener address
    ctx->trid.adrfam = SPDK_NVMF_ADRFAM_IPV4;
    ctx->trid.trtype = SPDK_NVMF_TRTYPE_TCP;
    snprintf(ctx->trid.traddr, sizeof(ctx->trid.traddr), "192.168.1.100");
    snprintf(ctx->trid.trsvcid, sizeof(ctx->trid.trsvcid), "4420");
    
    // Add listener to subsystem
    spdk_nvmf_subsystem_add_listener(ctx->subsystem, &ctx->trid, listener_added, ctx);
}

static void transport_created(void *cb_arg, struct spdk_nvmf_transport *transport)
{
    struct setup_ctx *ctx = cb_arg;
    
    if (!transport) {
        SPDK_ERRLOG("Failed to create transport\n");
        return;
    }
    
    // Add transport to target
    spdk_nvmf_tgt_add_transport(ctx->tgt, transport, transport_added, ctx);
}

static void setup_nvmf_target_with_network(struct spdk_nvmf_tgt *tgt)
{
    struct spdk_nvmf_transport_opts tcp_opts;
    struct setup_ctx *ctx;
    
    ctx = calloc(1, sizeof(*ctx));
    ctx->tgt = tgt;
    
    // 1. Initialize transport options
    spdk_nvmf_transport_opts_init(&tcp_opts, sizeof(tcp_opts));
    tcp_opts.max_queue_depth = 128;
    tcp_opts.max_io_size = 131072;
    tcp_opts.in_capsule_data_size = 8192;
    
    // 2. Create transport (async)
    spdk_nvmf_transport_create_async("TCP", &tcp_opts, transport_created, ctx);
    
    // Flow continues through callbacks:
    // transport_created -> transport_added -> listener_added -> subsystem_started
}
```

## Advanced Network Configurations

### Multi-Protocol Setup

```c
static void setup_multi_protocol_target(struct spdk_nvmf_tgt *tgt)
{
    // TCP Transport
    struct spdk_nvmf_transport_opts tcp_opts;
    spdk_nvmf_transport_opts_init(&tcp_opts, sizeof(tcp_opts));
    tcp_opts.max_queue_depth = 128;
    spdk_nvmf_transport_create_async("TCP", &tcp_opts, tcp_transport_created, ctx);
    
    // RDMA Transport  
    struct spdk_nvmf_transport_opts rdma_opts;
    spdk_nvmf_transport_opts_init(&rdma_opts, sizeof(rdma_opts));
    rdma_opts.max_queue_depth = 256;
    rdma_opts.max_io_size = 262144;
    spdk_nvmf_transport_create_async("RDMA", &rdma_opts, rdma_transport_created, ctx);
}
```

### Multi-Address Listeners

```c 
static void add_multiple_listeners(struct spdk_nvmf_subsystem *subsystem)
{
    struct spdk_nvme_transport_id trid1 = {}, trid2 = {};
    
    // Primary interface
    trid1.adrfam = SPDK_NVMF_ADRFAM_IPV4;
    trid1.trtype = SPDK_NVMF_TRTYPE_TCP;
    snprintf(trid1.traddr, sizeof(trid1.traddr), "192.168.1.100");
    snprintf(trid1.trsvcid, sizeof(trid1.trsvcid), "4420");
    
    // Secondary interface
    trid2.adrfam = SPDK_NVMF_ADRFAM_IPV4;
    trid2.trtype = SPDK_NVMF_TRTYPE_TCP;
    snprintf(trid2.traddr, sizeof(trid2.traddr), "10.0.0.100");
    snprintf(trid2.trsvcid, sizeof(trid2.trsvcid), "4420");
    
    spdk_nvmf_subsystem_add_listener(subsystem, &trid1, listener1_added_cb, NULL);
    spdk_nvmf_subsystem_add_listener(subsystem, &trid2, listener2_added_cb, NULL);
}
```

## Network Topology Patterns

### Single Subsystem, Multiple Interfaces

```
Host Connections:
├── 192.168.1.100:4420 → nqn.2016-06.io.spdk:storage1
└── 10.0.0.100:4420    → nqn.2016-06.io.spdk:storage1

Result: Same subsystem accessible via multiple network paths
```

### Multiple Subsystems, Shared Transport

```
TCP Transport (Global)
├── Listener 192.168.1.100:4420 → nqn.2016-06.io.spdk:storage1
├── Listener 192.168.1.100:4421 → nqn.2016-06.io.spdk:storage2
└── Listener 192.168.1.100:4422 → nqn.2016-06.io.spdk:storage3

Result: Multiple subsystems on same IP, different ports
```

### Multi-Protocol Access

```
Host Connection Options:
├── TCP: 192.168.1.100:4420  → nqn.2016-06.io.spdk:storage1
└── RDMA: 192.168.1.100:4420 → nqn.2016-06.io.spdk:storage1

Result: Same subsystem accessible via TCP or RDMA
```

## Transport Configuration Options

### TCP Transport Options

```c
struct spdk_nvmf_transport_opts tcp_opts = {
    .max_queue_depth = 128,           // Max outstanding commands per queue
    .max_io_size = 131072,           // Max I/O size (128KB)
    .in_capsule_data_size = 8192,    // Data in command capsule (8KB)
    .max_aq_depth = 32,              // Admin queue depth
    .num_shared_buffers = 8192,      // Shared buffer pool size
    .c2h_success = true,             // Send success responses
    .dif_insert_or_strip = false,    // DIF handling
    .sock_priority = 0,              // Socket priority
    .abort_timeout_sec = 1,          // Command abort timeout
};
```

### RDMA Transport Options

```c
struct spdk_nvmf_transport_opts rdma_opts = {
    .max_queue_depth = 256,          // Higher for RDMA performance
    .max_io_size = 262144,           // Larger I/O sizes (256KB)
    .in_capsule_data_size = 16384,   // Larger in-capsule data (16KB)
    .max_srq_depth = 4096,           // Shared receive queue depth
    .no_srq = false,                 // Use shared receive queues
    .acceptor_backlog = 100,         // Connection backlog
    .max_aq_depth = 32,              // Admin queue depth
};
```

## Connection Flow

### Host Connection Process

1. **Host discovers target** using Discovery Service or static configuration
2. **Host connects to specific (IP:port, NQN)** tuple
3. **Transport handles protocol negotiation** (TCP, RDMA, etc.)
4. **Subsystem presents namespaces** as NVMe controller to host
5. **Host sees NVMe controller** with accessible namespaces

### Connection Example

```bash
# Host connects to:
# IP: 192.168.1.100, Port: 4420, NQN: nqn.2016-06.io.spdk:storage1

# Host discovers:
nvme discover -t tcp -a 192.168.1.100 -s 4420

# Host connects:
nvme connect -t tcp -a 192.168.1.100 -s 4420 -n nqn.2016-06.io.spdk:storage1

# Host sees: /dev/nvme0 (controller) with /dev/nvme0n1, /dev/nvme0n2... (namespaces)
```

## Network Architecture Key Points

- **Transports are global**: One TCP transport can serve multiple subsystems and addresses
- **Listeners are per-subsystem**: Each subsystem can have multiple network endpoints
- **Flexible topology**: 
  - Multiple subsystems can share the same transport
  - Same address can serve multiple subsystems (different NQNs)
  - One subsystem can listen on multiple addresses/ports
- **Host connection**: Hosts connect to `(IP:port, NQN)` tuple to access specific subsystem
- **Two-step process**: 
  1. `spdk_nvmf_subsystem_add_listener()` - associates address with subsystem
  2. `spdk_nvmf_tgt_listen_ext()` - starts actual network listening

For the foundational concepts and bdev integration that enable this network functionality, see [[SPDK NVMe-oF Overview]].

## Implementation References

### Network APIs
- **Transport Creation**: include/spdk/nvmf.h:1323 (`spdk_nvmf_transport_create_async()`)
- **Listener Management**: include/spdk/nvmf.h:771 (`spdk_nvmf_subsystem_add_listener()`)
- **Global Listening**: include/spdk/nvmf.h:308 (`spdk_nvmf_tgt_listen_ext()`)
- **Transport Integration**: lib/nvmf/transport.c (transport implementation)