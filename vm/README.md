# VM Development Environment

## What's Included

Ubuntu 24.04 VM pre-configured for OpenEBS/Mayastor development and testing. Includes Docker, Nix package manager, storage disks for testing, and Mayastor-specific kernel modules and configuration (hugepages, IOMMU, NVMe fabrics).

## Getting Started

### Prerequisites

- libvirt with KVM support
- If your host doesn't have a default libvirt network, configure it:
  ```bash
  virsh net-define default-network.xml
  virsh net-start default
  virsh net-autostart default
  ```

### First Run

```bash
# Create and start VM
./vm.sh start

# SSH into VM (wait a moment for cloud-init to complete)
./vm.sh ssh
```

The VM will automatically mount your workspace at `/mnt/workspace` for development.

## VM Management

### Basic Operations

| Command | Description |
|---------|-------------|
| `./vm.sh start` | Create new VM or start existing one |
| `./vm.sh stop` | Shutdown VM gracefully |
| `./vm.sh destroy` | Destroy VM and remove all disks |
| `./vm.sh status` | Show VM status and network info |

### Accessing Your VM

| Command | Description |
|---------|-------------|
| `./vm.sh ssh` | SSH into VM as ubuntu user |
| `./vm.sh console` | Connect to VM console (Ctrl+] to exit) |

### State Management

| Command | Description |
|---------|-------------|
| `./vm.sh snapshot` | Save current VM state |
| `./vm.sh restore` | Restore VM from saved snapshot |

### Configuration Options

Customize VM resources and behavior:

| Flag | Environment Variable | Default | Description |
|------|---------------------|---------|-------------|
| `--memory SIZE` | `VM_MEMORY` | 16384 | RAM in MB |
| `--cpus COUNT` | `VM_CPUS` | 16 | Number of vCPUs |
| `--disk-size SIZE` | `VM_DISK_SIZE` | 100G | Main disk size |
| `--additional-disks COUNT` | `ADDITIONAL_DISK_COUNT` | 3 | Storage disks for testing |
| `--additional-disk-size SIZE` | `ADDITIONAL_DISK_SIZE` | 1G | Size of each storage disk |
| `--no-workspace` | `WORKSPACE_MOUNT_ENABLED=false` | - | Disable workspace mounting |
| `--workspace-path PATH` | `WORKSPACE_SOURCE_PATH` | .. | Custom workspace path |
| `--network CONFIG` | `VM_NETWORK` | bridge=virbr0 | Network configuration |
| `--config FILE` | - | - | Load settings from file |

**Examples:**
```bash
# Smaller VM for limited resources
./vm.sh start --memory 8192 --cpus 8

# More storage disks for testing
./vm.sh start --additional-disks 5 --additional-disk-size 2G

# Use config file
./vm.sh start --config my-vm-config.env
```