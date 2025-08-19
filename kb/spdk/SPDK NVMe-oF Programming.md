---
title: SPDK NVMe-oF Programming
type: note
permalink: spdk/spdk-nvme-o-f-programming
tags:
- '["spdk"'
- '"nvme-of"'
- '"programming"'
- '"api"'
- '"subsystem"'
- '"namespace"'
- '"state-management"]'
---

# SPDK NVMe-oF Programming API

This document covers the programmatic APIs for creating and managing NVMe-oF subsystems and namespaces in code, including state management and complete programming workflows.

## Creating a Subsystem

### API Reference

**API**: `spdk_nvmf_subsystem_create()` in `include/spdk/nvmf.h:446`

```c
struct spdk_nvmf_subsystem *spdk_nvmf_subsystem_create(
    struct spdk_nvmf_tgt *tgt,      // NVMe-oF target
    const char *nqn,                // NQN (e.g., "nqn.2016-06.io.spdk:storage1")
    enum spdk_nvmf_subtype type,    // SPDK_NVMF_SUBTYPE_NVME or SPDK_NVMF_SUBTYPE_DISCOVERY
    uint32_t num_ns                 // Max namespaces (0 = use default 32)
);
```

### Example Usage

```c
struct spdk_nvmf_subsystem *subsystem;
subsystem = spdk_nvmf_subsystem_create(tgt, 
                                      "nqn.2016-06.io.spdk:storage1",
                                      SPDK_NVMF_SUBTYPE_NVME,
                                      32);  // max 32 namespaces
if (!subsystem) {
    SPDK_ERRLOG("Failed to create subsystem\n");
    return -1;
}
```

## Adding Namespaces

### API Reference

**API**: `spdk_nvmf_subsystem_add_ns_ext()` in `include/spdk/nvmf.h:1096`

```c
uint32_t spdk_nvmf_subsystem_add_ns_ext(
    struct spdk_nvmf_subsystem *subsystem,
    const char *bdev_name,              // Block device name (e.g., "Malloc0")
    const struct spdk_nvmf_ns_opts *opts, // Namespace options (or NULL for defaults)
    size_t opts_size,                   // sizeof(*opts)
    const char *ptpl_file               // Persistence file (or NULL)
);
```

### Example Usage

```c
struct spdk_nvmf_ns_opts ns_opts;
uint32_t nsid;

// Get default namespace options
spdk_nvmf_ns_opts_get_defaults(&ns_opts, sizeof(ns_opts));

// Add namespace - returns NSID (1, 2, 3, etc.) or 0 on failure
nsid = spdk_nvmf_subsystem_add_ns_ext(subsystem, 
                                     "Malloc0",   // bdev name
                                     &ns_opts,    // or NULL for defaults
                                     sizeof(ns_opts),
                                     NULL);       // no persistence file
if (nsid == 0) {
    SPDK_ERRLOG("Failed to add namespace\n");
    return -1;
}
```

## Subsystem State Management

### State Overview

**Important**: Subsystems must be in **PAUSED** or **INACTIVE** state to add or remove namespaces.

Available states:
- **INACTIVE**: Newly created, not yet started
- **ACTIVE**: Running and accepting I/O
- **PAUSED**: Admin frozen, can modify namespaces

### State Management APIs

```c
// Callback function prototype
typedef void (*spdk_nvmf_subsystem_state_change_done)(struct spdk_nvmf_subsystem *subsystem,
                                                      void *cb_arg, int status);

// Start subsystem (INACTIVE -> ACTIVE)
int spdk_nvmf_subsystem_start(struct spdk_nvmf_subsystem *subsystem,
                             spdk_nvmf_subsystem_state_change_done cb_fn,
                             void *cb_arg);

// Pause subsystem (ACTIVE -> PAUSED) to modify namespaces
int spdk_nvmf_subsystem_pause(struct spdk_nvmf_subsystem *subsystem,
                             uint32_t nsid,  // namespace to pause, or 0 for none
                             spdk_nvmf_subsystem_state_change_done cb_fn,
                             void *cb_arg);

// Resume subsystem (PAUSED -> ACTIVE)
int spdk_nvmf_subsystem_resume(struct spdk_nvmf_subsystem *subsystem,
                              spdk_nvmf_subsystem_state_change_done cb_fn,
                              void *cb_arg);
```

### State Transition Example

```c
static void start_complete(struct spdk_nvmf_subsystem *subsystem, void *cb_arg, int status)
{
    if (status != 0) {
        SPDK_ERRLOG("Failed to start subsystem: %d\n", status);
        return;
    }
    SPDK_NOTICELOG("Subsystem started successfully\n");
}

// Start subsystem (INACTIVE -> ACTIVE)
spdk_nvmf_subsystem_start(subsystem, start_complete, NULL);
```

## Complete Programming Workflow

### Basic Setup Example

```c
static void setup_nvmf_subsystem(struct spdk_nvmf_tgt *tgt)
{
    struct spdk_nvmf_subsystem *subsystem;
    uint32_t nsid;
    
    // 1. Create subsystem
    subsystem = spdk_nvmf_subsystem_create(tgt,
                                          "nqn.2016-06.io.spdk:storage1",
                                          SPDK_NVMF_SUBTYPE_NVME,
                                          0);  // use default max namespaces
    if (!subsystem) {
        SPDK_ERRLOG("Failed to create subsystem\n");
        return;
    }
    
    // 2. Add namespaces (subsystem starts in INACTIVE state)
    nsid = spdk_nvmf_subsystem_add_ns_ext(subsystem, "Malloc0", NULL, 0, NULL);
    if (nsid == 0) {
        SPDK_ERRLOG("Failed to add namespace\n");
        return;
    }
    
    // 3. Add listeners for network access (covered in [[SPDK NVMe-oF Network]])
    // spdk_nvmf_subsystem_add_listener(...)
    
    // 4. Start subsystem (INACTIVE -> ACTIVE)
    spdk_nvmf_subsystem_start(subsystem, start_complete, NULL);
}
```

### Advanced Multi-Namespace Example

```c
struct setup_context {
    struct spdk_nvmf_tgt *tgt;
    struct spdk_nvmf_subsystem *subsystem;
    const char **bdev_names;
    int bdev_count;
    int current_bdev;
};

static void add_next_namespace(void *ctx);

static void namespace_added_cb(void *cb_arg, uint32_t nsid, int status)
{
    struct setup_context *ctx = cb_arg;
    
    if (status != 0) {
        SPDK_ERRLOG("Failed to add namespace %s: %d\n", 
                   ctx->bdev_names[ctx->current_bdev], status);
        return;
    }
    
    SPDK_NOTICELOG("Added namespace %d for bdev %s\n", 
                   nsid, ctx->bdev_names[ctx->current_bdev]);
    
    ctx->current_bdev++;
    if (ctx->current_bdev < ctx->bdev_count) {
        // Add next namespace
        add_next_namespace(ctx);
    } else {
        // All namespaces added, start subsystem
        spdk_nvmf_subsystem_start(ctx->subsystem, start_complete, ctx);
    }
}

static void add_next_namespace(void *cb_arg)
{
    struct setup_context *ctx = cb_arg;
    uint32_t nsid;
    
    nsid = spdk_nvmf_subsystem_add_ns_ext(ctx->subsystem,
                                         ctx->bdev_names[ctx->current_bdev],
                                         NULL, 0, NULL);
    if (nsid == 0) {
        SPDK_ERRLOG("Failed to add namespace for %s\n", 
                   ctx->bdev_names[ctx->current_bdev]);
        return;
    }
    
    // Namespace added synchronously, call callback
    namespace_added_cb(ctx, nsid, 0);
}

static void setup_multi_namespace_subsystem(struct spdk_nvmf_tgt *tgt)
{
    struct setup_context *ctx;
    const char *bdev_names[] = {"Malloc0", "Malloc1", "Nvme0n1", "AIO0"};
    
    ctx = calloc(1, sizeof(*ctx));
    ctx->tgt = tgt;
    ctx->bdev_names = bdev_names;
    ctx->bdev_count = SPDK_COUNTOF(bdev_names);
    ctx->current_bdev = 0;
    
    // Create subsystem
    ctx->subsystem = spdk_nvmf_subsystem_create(tgt,
                                               "nqn.2016-06.io.spdk:multi-storage",
                                               SPDK_NVMF_SUBTYPE_NVME,
                                               0);
    if (!ctx->subsystem) {
        SPDK_ERRLOG("Failed to create subsystem\n");
        free(ctx);
        return;
    }
    
    // Start adding namespaces
    add_next_namespace(ctx);
}
```

## Dynamic Namespace Management

### Adding Namespaces to Active Subsystem

```c
static void namespace_added_to_active(void *cb_arg, uint32_t nsid, int status)
{
    struct management_ctx *ctx = cb_arg;
    
    if (status == 0) {
        SPDK_NOTICELOG("Successfully added namespace %d\n", nsid);
    }
    
    // Resume subsystem (PAUSED -> ACTIVE)
    spdk_nvmf_subsystem_resume(ctx->subsystem, resume_complete, ctx);
}

static void pause_complete_for_add(struct spdk_nvmf_subsystem *subsystem, 
                                  void *cb_arg, int status)
{
    struct management_ctx *ctx = cb_arg;
    uint32_t nsid;
    
    if (status != 0) {
        SPDK_ERRLOG("Failed to pause subsystem: %d\n", status);
        return;
    }
    
    // Now we can add namespace (subsystem is PAUSED)
    nsid = spdk_nvmf_subsystem_add_ns_ext(subsystem, ctx->new_bdev_name, 
                                         NULL, 0, NULL);
    if (nsid == 0) {
        SPDK_ERRLOG("Failed to add namespace\n");
        spdk_nvmf_subsystem_resume(subsystem, resume_complete, ctx);
        return;
    }
    
    namespace_added_to_active(ctx, nsid, 0);
}

static void add_namespace_to_active_subsystem(struct spdk_nvmf_subsystem *subsystem,
                                             const char *bdev_name)
{
    struct management_ctx *ctx;
    
    ctx = calloc(1, sizeof(*ctx));
    ctx->subsystem = subsystem;
    ctx->new_bdev_name = bdev_name;
    
    // Pause subsystem to allow namespace modification (ACTIVE -> PAUSED)
    spdk_nvmf_subsystem_pause(subsystem, 0, pause_complete_for_add, ctx);
}
```

## Error Handling Best Practices

### Comprehensive Error Checking

```c
static int create_subsystem_with_validation(struct spdk_nvmf_tgt *tgt,
                                           const char *nqn,
                                           const char **bdev_names,
                                           int bdev_count)
{
    struct spdk_nvmf_subsystem *subsystem;
    uint32_t nsid;
    int i;
    
    // Validate inputs
    if (!tgt || !nqn || !bdev_names || bdev_count <= 0) {
        SPDK_ERRLOG("Invalid parameters\n");
        return -EINVAL;
    }
    
    // Check if bdevs exist before creating subsystem
    for (i = 0; i < bdev_count; i++) {
        struct spdk_bdev *bdev = spdk_bdev_get_by_name(bdev_names[i]);
        if (!bdev) {
            SPDK_ERRLOG("Bdev %s not found\n", bdev_names[i]);
            return -ENODEV;
        }
    }
    
    // Create subsystem
    subsystem = spdk_nvmf_subsystem_create(tgt, nqn, SPDK_NVMF_SUBTYPE_NVME, bdev_count);
    if (!subsystem) {
        SPDK_ERRLOG("Failed to create subsystem %s\n", nqn);
        return -ENOMEM;
    }
    
    // Add namespaces with error handling
    for (i = 0; i < bdev_count; i++) {
        nsid = spdk_nvmf_subsystem_add_ns_ext(subsystem, bdev_names[i], NULL, 0, NULL);
        if (nsid == 0) {
            SPDK_ERRLOG("Failed to add namespace for bdev %s\n", bdev_names[i]);
            // Could implement cleanup here
            return -EIO;
        }
        SPDK_NOTICELOG("Added namespace %d for bdev %s\n", nsid, bdev_names[i]);
    }
    
    return 0;
}
```

## Key Programming Points

- **Subsystems are created in INACTIVE state** - safe for namespace modification
- **Namespaces can only be added/removed when subsystem is PAUSED or INACTIVE**
- **Each namespace maps to an existing SPDK block device** (bdev) by name
- **The API returns the assigned namespace ID** (NSID) starting from 1
- **State transitions are asynchronous** and require completion callbacks
- **Multiple namespaces in one subsystem** appear as `/dev/nvme0n1`, `/dev/nvme0n2`, etc. to hosts
- **Error handling is critical** - always check return values and handle failures gracefully

For network connectivity and transport configuration, see [[SPDK NVMe-oF Network]] which covers the listener and transport setup required to make subsystems accessible over the network.

## Implementation References

### Programming APIs
- **Subsystem Creation**: include/spdk/nvmf.h:446 (`spdk_nvmf_subsystem_create()`)
- **Namespace Addition**: include/spdk/nvmf.h:1096 (`spdk_nvmf_subsystem_add_ns_ext()`)
- **State Management**: include/spdk/nvmf.h (start/pause/resume functions)
- **Internal Implementation**: lib/nvmf/subsystem.c (subsystem and namespace management)