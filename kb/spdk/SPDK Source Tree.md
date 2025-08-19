---
title: SPDK Source Tree
type: note
permalink: spdk/spdk-source-tree
---

# SPDK Source Tree

```
spdk/
├── include/spdk/          # Public APIs
├── lib/                   # Core implementations
│   ├── bdev/             # Block device abstraction
│   ├── nvme/             # NVMe driver
│   ├── nvmf/             # NVMe-oF target
│   ├── thread/           # Threading framework
│   ├── event/            # Event/reactor framework
│   ├── env_dpdk/         # DPDK environment wrapper
│   ├── rpc/              # JSON-RPC framework
│   ├── json/             # JSON parsing
│   ├── util/             # Utilities (CRC, base64, etc.)
│   └── */                # Other core libraries
├── module/               # Pluggable implementations
│   ├── bdev/             # Block device types (nvme, malloc, null, raid, etc.)
│   ├── accel/            # Acceleration engines (ioat, dsa, etc.)
│   ├── sock/             # Socket implementations
│   └── */                # Other module types
├── app/                  # Complete applications (spdk_tgt, nvmf_tgt, etc.)
├── examples/             # Reference code and utilities
├── test/                 # Unit and functional tests
├── scripts/              # Setup and utility scripts (setup.sh, rpc.py)
└── doc/                  # Official documentation
```