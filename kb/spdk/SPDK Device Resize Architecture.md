---
title: SPDK Device Resize Architecture
type: note
permalink: spdk/spdk-device-resize-architecture
---

# SPDK Device Resize Architecture

SPDK's device resize system enables dynamic storage capacity changes through an event-driven architecture. While the core resize infrastructure is robust, **most virtual bdev implementations ignore resize events**, breaking the resize propagation chain and preventing applications from detecting capacity changes.

## Architecture Overview

Device resize in SPDK follows a **bottom-up event propagation model** built on the bdev event system documented in [[SPDK Event System Architecture]]. The resize flow traverses the layered bdev architecture described in [[SPDK Bdev Overview]], requiring each layer to properly handle and propagate resize events.

### Resize Event Flow

```
┌─────────────────────────────────────────────────┐
│                Application                       │ ← Receives SPDK_BDEV_EVENT_RESIZE
│  (NVMf, SCSI, vhost, etc.)                     │
└─────────────────────────────────────────────────┘
                     ↑ 
┌─────────────────────────────────────────────────┐
│            Virtual Bdev Layers                  │ ← Should propagate (most don't!)
│  (crypto, passthru, delay, compress...)        │   
└─────────────────────────────────────────────────┘
                     ↑ 
┌─────────────────────────────────────────────────┐
│              Base Bdev                          │ ← Calls spdk_bdev_notify_blockcnt_change()
│  (nvme, rbd, lvol, null, aio...)              │
└─────────────────────────────────────────────────┘
                     ↑ 
┌─────────────────────────────────────────────────┐
│         Resize Sources                          │
│  RPC commands, hardware detection, backend     │  
└─────────────────────────────────────────────────┘
```

### Core Resize Notification API

The resize system centers on `spdk_bdev_notify_blockcnt_change()` in `lib/bdev/bdev.c:3710`:

```c
int spdk_bdev_notify_blockcnt_change(struct spdk_bdev *bdev, uint64_t size)
{
    if (size == bdev->blockcnt) {
        return 0;  // No change
    }
    
    bdev->blockcnt = size;  // Update size first
    
    // Send SPDK_BDEV_EVENT_RESIZE to all open descriptors
    TAILQ_FOREACH(desc, &bdev->internal.open_descs, link) {
        spdk_thread_send_msg(desc->thread, _resize_notify, desc);
    }
}
```

## Resize Sources

### 1. RPC Commands (Admin-initiated)
```bash
# Examples of working resize RPCs
./scripts/rpc.py bdev_rbd_resize Rbd0 4096      # Resize RBD to 4GB
./scripts/rpc.py bdev_null_resize Null0 1024    # Resize null bdev to 1GB
./scripts/rpc.py bdev_lvol_resize lvol0 2048    # Resize logical volume to 2GB
```

### 2. Hardware Detection (Auto-discovery)
```c
// NVMe namespace change detection: module/bdev/nvme/bdev_nvme.c:1832-1838
if (bdev->disk.blockcnt != num_sectors) {
    SPDK_NOTICELOG("NSID %u is resized: bdev name %s, old size %" PRIu64 ", new size %" PRIu64 "\n",
                   nsid, bdev->disk.name, bdev->disk.blockcnt, num_sectors);
    rc = spdk_bdev_notify_blockcnt_change(&bdev->disk, num_sectors);
}
```

## Virtual Bdev Implementation Gap

### Current Problem: Resize Events Ignored

**All major virtual bdevs ignore resize events**, following this broken pattern:

```c
// Common pattern across virtual bdevs
static void vbdev_*_base_bdev_event_cb(enum spdk_bdev_event_type type, ...)
{
    switch (type) {
    case SPDK_BDEV_EVENT_REMOVE:
        // Handle removal
        break;
    default:
        SPDK_NOTICELOG("Unsupported bdev event: type %d\n", type);
        break;  // ❌ RESIZE events ignored here - BREAKS RESIZE CHAIN
    }
}
```

### Virtual Bdev Resize Support Status

| Virtual Bdev | Resize Support | Implementation Location | Status |
|--------------|----------------|------------------------|--------|
| **Crypto** ❌ | No | `module/bdev/crypto/vbdev_crypto.c:1648-1658` | Ignores resize events |
| **Passthru** ❌ | No | `module/bdev/passthru/vbdev_passthru.c:587-599` | Ignores resize events |
| **Delay** ❌ | No | `module/bdev/delay/vbdev_delay.c:709-719` | Ignores resize events |
| **Zone Block** ❌ | No | `module/bdev/zone_block/vbdev_zone_block.c:615-625` | Ignores resize events |
| **OCF** ❌ | No | `module/bdev/ocf/vbdev_ocf.c:1361-1373` | Ignores resize events |
| **Compress** ❌ | No | N/A | No event handler found |

## Working Protocol Layer Examples

### NVMf (NVMe-over-Fabrics) - Full Implementation
**Location**: `lib/nvmf/subsystem.c:1353-1354`, `1304-1336`

```c
// Event handler
static void nvmf_ns_event(enum spdk_bdev_event_type type, struct spdk_bdev *bdev, void *event_ctx)
{
    switch (type) {
    case SPDK_BDEV_EVENT_RESIZE:  // ✅ Handles resize
        nvmf_ns_resize(event_ctx);
        break;
    // ...
    }
}

// Resize implementation
static void nvmf_ns_resize(void *event_ctx)
{
    struct spdk_nvmf_ns *ns = event_ctx;
    
    // Allocate async context
    ns_ctx = calloc(1, sizeof(struct subsystem_ns_change_ctx));
    ns_ctx->subsystem = ns->subsystem;
    ns_ctx->nsid = ns->opts.nsid;
    
    // Pause subsystem to handle resize safely
    rc = spdk_nvmf_subsystem_pause(ns->subsystem, 0, _nvmf_ns_resize, ns_ctx);
}
```

### vhost - Guest VM Notification  
**Location**: `lib/vhost/vhost_blk.c:1185-1187`, `1106-1114`

```c
static void blk_resize_cb(void *resize_ctx)
{
    struct spdk_vhost_blk_dev *bvdev = resize_ctx;
    
    spdk_vhost_lock();
    // Notify all active vhost sessions about the resize
    vhost_dev_foreach_session(&bvdev->vdev, vhost_session_bdev_resize_cb, NULL, NULL);
    spdk_vhost_unlock();
}

static int vhost_session_bdev_resize_cb(...)
{
    // Send config change to VM/guest
    rte_vhost_slave_config_change(vsession->vid, false);
    return 0;
}
```

## Implementation Solution

### Generic Virtual Bdev Resize Pattern

The fix for any virtual bdev follows this pattern:

```c
static void
vbdev_*_base_bdev_event_cb(enum spdk_bdev_event_type type, struct spdk_bdev *bdev,
                          void *event_ctx)
{
    switch (type) {
    case SPDK_BDEV_EVENT_REMOVE:
        vbdev_*_base_bdev_hotremove_cb(bdev);
        break;
    case SPDK_BDEV_EVENT_RESIZE:  // ✅ Add resize support
        vbdev_*_base_bdev_resize_cb(bdev);
        break;
    default:
        SPDK_NOTICELOG("Unsupported bdev event: type %d\n", type);
        break;
    }
}

static void
vbdev_*_base_bdev_resize_cb(struct spdk_bdev *base_bdev)
{
    struct vbdev_* *virtual_bdev;
    
    // Find virtual bdev that uses this base bdev
    TAILQ_FOREACH(virtual_bdev, &g_vbdev_*_list, link) {
        if (virtual_bdev->base_bdev == base_bdev) {
            // Update virtual bdev size to match base bdev
            virtual_bdev->vbdev.blockcnt = base_bdev->blockcnt;
            
            // Propagate resize event to layers above virtual bdev
            spdk_bdev_notify_blockcnt_change(&virtual_bdev->vbdev, base_bdev->blockcnt);
            break;
        }
    }
}
```

### Crypto Bdev Specific Example

For crypto bdev (`module/bdev/crypto/vbdev_crypto.c:1648-1658`):

```c
static void
vbdev_crypto_base_bdev_event_cb(enum spdk_bdev_event_type type, struct spdk_bdev *bdev,
                                void *event_ctx)
{
    switch (type) {
    case SPDK_BDEV_EVENT_REMOVE:
        vbdev_crypto_base_bdev_hotremove_cb(bdev);
        break;
    case SPDK_BDEV_EVENT_RESIZE:  // ✅ Add resize support
        vbdev_crypto_base_bdev_resize_cb(bdev);
        break;
    default:
        SPDK_NOTICELOG("Unsupported bdev event: type %d\n", type);
        break;
    }
}

static void
vbdev_crypto_base_bdev_resize_cb(struct spdk_bdev *base_bdev)
{
    struct vbdev_crypto *crypto_bdev;
    
    // Find crypto bdev that uses this base bdev
    TAILQ_FOREACH(crypto_bdev, &g_vbdev_crypto, link) {
        if (crypto_bdev->base_bdev == base_bdev) {
            // Update crypto bdev size to match base bdev
            crypto_bdev->crypto_bdev.blockcnt = base_bdev->blockcnt;
            
            // Propagate resize event to layers above crypto bdev
            spdk_bdev_notify_blockcnt_change(&crypto_bdev->crypto_bdev, base_bdev->blockcnt);
            break;
        }
    }
}
```

## Why Crypto Bdev Resize Is Safe

### Technical Requirements Analysis

**Requirement 1: Key Independence ✅ VERIFIED**
- Keys are completely static and configuration-driven
- No dependency on bdev metadata anywhere in key lifecycle

```c
// Key handling: module/bdev/crypto/vbdev_crypto.c:1856-1863
vbdev->cipher_xform.cipher.key.data = vbdev->key;        // Static key from config
vbdev->cipher_xform.cipher.key.length = AES_CBC_KEY_LENGTH; // Fixed length
```

**Requirement 2: Block Size Transparency ✅ VERIFIED**
- Perfect 1:1 block size mapping with no overhead

```c
// Size inheritance: module/bdev/crypto/vbdev_crypto.c:1801-1802
vbdev->crypto_bdev.blocklen = bdev->blocklen;   // ← Identical block size
vbdev->crypto_bdev.blockcnt = bdev->blockcnt;   // ← Identical block count
```

**Requirement 3: No Block Interdependency ✅ VERIFIED**
- Each block encrypted independently using LBA-based IV

```c
// Independent block encryption: module/bdev/crypto/vbdev_crypto.c:783-788
/* Set the IV - we use the LBA of the crypto_op */
op_block_offset = bdev_io->u.bdev.offset_blocks + crypto_index;
rte_memcpy(iv_ptr, &op_block_offset, sizeof(uint64_t));
```

### Implementation Safety

**Why This Implementation Is Safe:**
1. **No crypto state changes needed**: Crypto sessions, keys, and IVs remain unchanged
2. **No metadata updates**: No persistent state to update
3. **Automatic IV scaling**: LBA-based IVs work for any block count  
4. **No block dependencies**: Each block remains independently encrypted
5. **Size transparency**: Crypto bdev maintains 1:1 mapping with base bdev

## Testing Strategy

### Unit Tests
1. **Resize propagation**: Verify events propagate through virtual bdev layers
2. **Size consistency**: Confirm virtual bdev size matches base bdev after resize
3. **Operations continuity**: Verify I/O operations work on resized device
4. **Error conditions**: Test invalid resize scenarios

### Integration Tests  
1. **End-to-end**: RBD → Crypto → NVMf resize through full stack
2. **Multiple layers**: Test resize through multiple virtual bdev layers
3. **Live I/O**: Resize during active I/O operations
4. **Shrink protection**: Verify shrinking blocked with open descriptors

### Specific Test Cases
```bash
# Test resize propagation
rpc.py bdev_rbd_create rbd_pool test_image 1024  # Create 1GB RBD
rpc.py bdev_crypto_create test_image crypto_test crypto_aesni_mb AES_CBC
rpc.py nvmf_subsystem_add_ns nqn.test crypto_test

# Resize base and verify propagation  
rpc.py bdev_rbd_resize test_image 2048  # Resize to 2GB
# Verify: crypto_test and NVMf namespace both show 2GB
```

## Impact and Benefits

### **Current State Problems**
- Applications cannot detect storage capacity changes
- Manual intervention required for capacity updates
- Inconsistent behavior across different storage stacks
- Broken storage orchestration in dynamic environments

### **After Implementation**
- **5-10 lines of code** to handle resize events per virtual bdev
- **Zero crypto-related changes** (keys, sessions, algorithms unchanged)
- **No on-disk format changes** (no persistent metadata)
- **Backward compatibility** (existing virtual bdevs unaffected)
- **Complete resize chain**: Events propagate from storage to applications

## Conclusion

**All technical requirements for virtual bdev resize support are satisfied.** The absence of resize support is purely an implementation gap, not a technical limitation. Adding resize event handling to virtual bdevs would:

- Enable dynamic storage management in SPDK applications
- Complete the resize event propagation chain
- Require minimal code changes with zero risk
- Provide immediate benefits for storage orchestration systems

This represents an excellent, low-risk contribution opportunity for the SPDK project.

## References

- **[[SPDK Event System Architecture]]**: Foundation for bdev events and resize notification system
- **[[SPDK Bdev Overview]]**: Virtual bdev layering architecture and stacking concepts
- **SPDK Bdev Module Interface**: `include/spdk/bdev_module.h:1019`
- **Resize Notification Implementation**: `lib/bdev/bdev.c:3710-3739`
- **Working Protocol Examples**: `lib/nvmf/subsystem.c`, `lib/vhost/vhost_blk.c`