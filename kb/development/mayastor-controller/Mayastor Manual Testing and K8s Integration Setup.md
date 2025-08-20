---
title: Mayastor Manual Testing and K8s Integration Setup
type: note
permalink: development/mayastor-controller/mayastor-manual-testing-and-k8s-integration-setup
---

# Mayastor Manual Testing and K8s Integration Setup

## When You DON'T Need This

**Standard unit and integration tests work fine without this setup.** The Mayastor controller uses lightweight Docker containers managed by the `deployer` tool for:

- Daily development testing
- Automated CI/CD pipelines  
- Unit and integration tests
- BDD test suite execution

These tests automatically manage their own cluster lifecycle and require no manual setup.

## When You DO Need This

Use terraform K8s clusters for:

### Manual Testing Scenarios
- Interactive debugging of Kubernetes deployments
- Testing custom Docker images in realistic environments
- Validating Mayastor behavior in actual K8s clusters
- Exploring REST APIs and CSI driver functionality

### Storage-Specific Testing
- Testing with real block devices (not simulated)
- Verifying NVMe-oF target creation and connectivity
- Filesystem probe validation that requires actual mounting
- Storage hardware integration testing

### K8s-Specific Features
- Testing features that require full Kubernetes API behavior
- Validating CSI driver integration beyond unit tests
- Testing node cordoning, draining, and scheduling
- Multi-node storage scenarios

## Available Deployment Options

### 1. Local VM Clusters (KVM/libvirt)
**Best for**: Realistic testing with full isolation

**Requirements**:
- libvirtd installed and configured
- Ubuntu cloud image downloaded
- Sufficient system resources (VMs)

**Setup**:
```bash
# Download Ubuntu image
wget https://cloud-images.ubuntu.com/releases/focal/release/ubuntu-20.04-server-cloudimg-amd64.img

# Configure terraform
cd terraform/cluster
# Edit variables.tf with image path and SSH keys
terraform init
terraform plan
terraform apply
```

**Access**:
```bash
# Copy kubeconfig via ansible
ansible -i ansible-hosts -a 'sudo cat /etc/kubernetes/admin.conf' master > ~/.kube/config
```

### 2. Local Container Clusters (LXD)
**Best for**: Faster iteration, fewer resources

**Requirements**:
- LXD installed and configured (`lxd init`)
- **Important**: Don't use btrfs/ZFS storage pools
- Required kernel modules loaded

**Kernel modules**:
```bash
# Required for all LXD K8s clusters
ip_tables ip6_tables nf_nat overlay netlink_diag br_netfilter

# Additional for LVM storage backend  
dm-snapshot dm-mirror dm_thin_pool
```

**Setup**:
```bash
# Test LXD works first
lxc launch ubuntu:18.04 test
lxc exec test -- curl http://google.com

# Deploy cluster
cd terraform/cluster
# Edit main.tf to use LXD provider
terraform apply
```

**Access**:
```bash
# Copy kubeconfig directly
lxc exec ksnode-1 -- cat /etc/kubernetes/admin.conf > ~/.kube/config

# Add NBD devices for storage testing
lxc config device add ksnode-1 nbd0 unix-block path=/dev/nbd0
```

### 3. Cloud Deployment (AWS/GCE/Azure)
**Status**: Planned but not yet implemented
**Use case**: Testing in cloud environments

## Private Docker Registry (Optional)

For testing custom Mayastor builds without external dependencies:

### NixOS Setup
```nix
services.dockerRegistry = {
  enable = true;
  listenAddress = "0.0.0.0";
  enableDelete = true;
};
```

### Other Distributions
```bash
mkdir registry-data
cat > docker-compose.yml << EOF
version: '3'
services:
  registry:
    image: registry:2
    ports: ["5000:5000"]
    environment:
      REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY: /data
    volumes: ["./registry-data:/data"]
EOF

docker-compose up -d
```

### Usage Workflow
```bash
# Build and push custom images
docker build -t kvmhost:5000/mayastor:dev .
docker push kvmhost:5000/mayastor:dev

# The terraform cluster automatically configures containerd 
# to use kvmhost:5000 as an insecure registry
kubectl apply -f custom-mayastor-deployment.yaml
```

## Development Workflow

### Testing Custom Changes
1. **Build locally**: Compile Rust code and create Docker images
2. **Push to registry**: Upload images to local registry (`kvmhost:5000`)
3. **Deploy to cluster**: Apply Kubernetes manifests using custom images
4. **Test interactively**: Use kubectl, ssh access, and manual verification
5. **Iterate**: Rebuild and redeploy as needed

### Cluster Lifecycle
```bash
# Create cluster
terraform apply

# Work with cluster
kubectl get nodes
ssh into VMs for debugging
lxc exec containers for inspection

# Destroy when done  
terraform destroy
```

## Platform-Specific Notes

### NixOS
- Enable libvirtd in configuration.nix
- Add user to libvirtd group
- Configure kvm_intel nested virtualization
- Set conntrack hashsize for kube-proxy

### Other Linux Distributions  
- Install terraform with LXD provider manually
- Configure LXD storage backend (avoid btrfs/ZFS)
- Load required kernel modules permanently

## Related Documentation
- [[Mayastor Controller Test Architecture]] - Overview of all testing approaches
- [[OpenEBS Mayastor Local Development Testing]] - Custom Docker image workflows
- Official terraform cluster README: `terraform/cluster/README.adoc`