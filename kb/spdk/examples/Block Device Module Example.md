---
title: Block Device Module Example
type: note
permalink: spdk/examples/block-device-module-example
---

# Block Device Module Example

Complete implementation of a simple RAM-based block device module.

## Pattern
Block device modules implement the `spdk_bdev_module` interface and provide `spdk_bdev_fn_table` operations.

## Code Example

```c
struct my_bdev {
    struct spdk_bdev bdev;
    char *name;
    uint64_t size;
    void *data;
};

static int my_bdev_destruct(void *ctx)
{
    struct my_bdev *my_bdev = ctx;
    
    free(my_bdev->data);
    free(my_bdev->name);
    free(my_bdev);
    return 0;
}

static void my_bdev_submit_request(struct spdk_io_channel *ch, struct spdk_bdev_io *bdev_io)
{
    struct my_bdev *my_bdev = (struct my_bdev *)bdev_io->bdev->ctxt;
    
    switch (bdev_io->type) {
    case SPDK_BDEV_IO_TYPE_READ:
        memcpy(bdev_io->u.bv.iovs[0].iov_base, 
               my_bdev->data + bdev_io->u.bv.offset_blocks * 512,
               bdev_io->u.bv.num_blocks * 512);
        spdk_bdev_io_complete(bdev_io, SPDK_BDEV_IO_STATUS_SUCCESS);
        break;
        
    case SPDK_BDEV_IO_TYPE_WRITE:
        memcpy(my_bdev->data + bdev_io->u.bv.offset_blocks * 512,
               bdev_io->u.bv.iovs[0].iov_base,
               bdev_io->u.bv.num_blocks * 512);
        spdk_bdev_io_complete(bdev_io, SPDK_BDEV_IO_STATUS_SUCCESS);
        break;
        
    default:
        spdk_bdev_io_complete(bdev_io, SPDK_BDEV_IO_STATUS_FAILED);
        break;
    }
}

static struct spdk_bdev_fn_table my_bdev_fn_table = {
    .destruct = my_bdev_destruct,
    .submit_request = my_bdev_submit_request,
};

static int create_my_bdev(const char *name, uint64_t size_mb)
{
    struct my_bdev *my_bdev = calloc(1, sizeof(*my_bdev));
    if (!my_bdev) {
        return -ENOMEM;
    }
    
    my_bdev->name = strdup(name);
    my_bdev->size = size_mb * 1024 * 1024;
    my_bdev->data = malloc(my_bdev->size);
    
    // Initialize bdev structure
    my_bdev->bdev.name = my_bdev->name;
    my_bdev->bdev.product_name = "My Device";
    my_bdev->bdev.blocklen = 512;
    my_bdev->bdev.blockcnt = my_bdev->size / 512;
    my_bdev->bdev.fn_table = &my_bdev_fn_table;
    my_bdev->bdev.module = &my_bdev_module;
    my_bdev->bdev.ctxt = my_bdev;
    
    // Register with SPDK
    int rc = spdk_bdev_register(&my_bdev->bdev);
    if (rc != 0) {
        free(my_bdev->data);
        free(my_bdev->name);
        free(my_bdev);
        return rc;
    }
    
    return 0;
}

static int my_bdev_init(void) { return 0; }
static void my_bdev_fini(void) { }

static struct spdk_bdev_module my_bdev_module = {
    .name = "my_bdev",
    .module_init = my_bdev_init,
    .module_fini = my_bdev_fini,
};

SPDK_BDEV_MODULE_REGISTER(my_bdev, &my_bdev_module)
```

## Key Points
- Implement required operations in `spdk_bdev_fn_table`
- Always call `spdk_bdev_io_complete()` for every I/O request
- Set proper block size (`blocklen`) and block count (`blockcnt`)
- Handle cleanup in the `destruct` callback