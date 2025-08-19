---
title: OpenEBS Mayastor Local Development Testing
type: note
permalink: development/openebs/open-ebs-mayastor-local-development-testing
---

# OpenEBS Mayastor Local Development Testing

## Overview

This guide covers the complete workflow for testing Mayastor code changes locally using custom Docker images and Helm charts. This process is **not directly documented** in the official repositories but combines standard Kubernetes development practices with Mayastor-specific tooling.

## Architecture Components

Mayastor consists of three separate repositories with independent build systems:

1. **io-engine** (`mayastor/io-engine/`) - Core storage engine
2. **controller** (`mayastor/controller/`) - Control plane components  
3. **extensions** (`mayastor/extensions/`) - Metrics, observability, kubectl plugin

## Build System Documentation

- **Build system**: Documented in `mayastor/io-engine/CLAUDE.md`
- **Nix environment**: Each repo has `shell.nix` for development dependencies
- **Release scripts**: Each repo has `scripts/release.sh` for building Docker images

## Development Testing Workflow

### Step 1: Build Custom Images

Each component must be built separately using their release scripts:

```bash
# In development container
cd /workspace/mayastor/io-engine
./scripts/release.sh --skip-publish --alias-tag dev-$(date +%Y%m%d)

cd /workspace/mayastor/controller  
./scripts/release.sh --skip-publish --alias-tag dev-$(date +%Y%m%d)

cd /workspace/mayastor/extensions
./scripts/release.sh --skip-publish --alias-tag dev-$(date +%Y%m%d)
```

**Images produced:**
- `openebs/mayastor-io-engine:dev-YYYYMMDD`
- `openebs/mayastor-agent-core:dev-YYYYMMDD`
- `openebs/mayastor-csi-controller:dev-YYYYMMDD`
- `openebs/mayastor-metrics-exporter-io-engine:dev-YYYYMMDD`
- And more...

### Step 2: Create Custom Values File

The main OpenEBS helm chart is located at `openebs/charts/Chart.yaml` with values at `openebs/charts/values.yaml`. Image configuration is handled by the mayastor sub-chart from `mayastor/extensions/chart/values.yaml`.

**Sample values file** (`test-values.yaml`):

```yaml
# Enable only Mayastor for focused testing
engines:
  local:
    lvm:
      enabled: false
    zfs:
      enabled: false
    rawfile:
      enabled: false
  replicated:
    mayastor:
      enabled: true

# Override Mayastor image tags with your custom builds
mayastor:
  image:
    registry: docker.io
    repo: openebs
    tag: dev-20250107  # Your custom build tag
    pullPolicy: IfNotPresent
  
  # Optional: Disable components you don't need for testing
  loki:
    enabled: false
  alloy:
    enabled: false
  
  # Enable specific features for testing
  etcd:
    clusterDomain: cluster.local
  
  csi:
    node:
      initContainers:
        enabled: true

# Disable other storage engines for focused testing
loki:
  enabled: false
```

### Step 3: Deploy with Helm

```bash
# Add OpenEBS helm repository
helm repo add openebs https://openebs.github.io/openebs
helm repo update

# Install with custom values
helm install openebs-dev openebs/openebs \
  --namespace openebs \
  --create-namespace \
  --values test-values.yaml

# Or upgrade existing installation
helm upgrade openebs-dev openebs/openebs \
  --namespace openebs \
  --values test-values.yaml
```

### Step 4: Verify Deployment

```bash
# Check pod status
kubectl get pods -n openebs

# Check if your custom images are being used
kubectl get pods -n openebs -o jsonpath='{.items[*].spec.containers[*].image}' | tr ' ' '\n' | grep dev-

# Monitor logs
kubectl logs -n openebs -l app=mayastor-io-engine -f
```

## Sample Testing Scenarios

### Minimal Mayastor Test

```yaml
# minimal-test-values.yaml
engines:
  replicated:
    mayastor:
      enabled: true
  local:
    lvm:
      enabled: false
    zfs: 
      enabled: false

mayastor:
  image:
    tag: dev-latest
    pullPolicy: IfNotPresent
  loki:
    enabled: false
  alloy:
    enabled: false
```

### Development with Observability

```yaml
# dev-with-monitoring-values.yaml
engines:
  replicated:
    mayastor:
      enabled: true

mayastor:
  image:
    tag: dev-20250107
    pullPolicy: IfNotPresent
  
  # Enable monitoring stack
  loki:
    enabled: true
  alloy:
    enabled: true
    
  base:
    logging:
      format: json
      color: false
    metrics:
      enabled: true
```

## Image Tag Configuration

Image tags are configured in `mayastor/extensions/chart/values.yaml`:

```yaml
image:
  registry: docker.io
  repo: openebs
  tag: develop  # Default tag
  repoTags:
    controlPlane: ""  # Override for control plane images
    dataPlane: ""     # Override for data plane images  
    extensions: ""    # Override for extensions images
```

## Container Environment Setup

The development container already has:
- ✅ `kubectl` - Available via Nix packages
- ✅ `docker` - Available for building images
- ✅ `rustup` - Added for Rust development
- ✅ `cargo` cache - Persistent volume mounted

## Suggested Devcontainer Enhancements

### Add Helm Support

Add to `devcontainer/Dockerfile`:
```dockerfile
# Install helm via Nix
RUN nix-env -iA nixpkgs.helm
```

### Add Development Helper Scripts

Create `devcontainer/scripts/build-and-test.sh`:
```bash
#!/bin/bash
set -e

TAG="dev-$(date +%Y%m%d-%H%M)"
echo "Building with tag: $TAG"

# Build all components
cd /workspace/mayastor/io-engine && ./scripts/release.sh --skip-publish --alias-tag $TAG
cd /workspace/mayastor/controller && ./scripts/release.sh --skip-publish --alias-tag $TAG  
cd /workspace/mayastor/extensions && ./scripts/release.sh --skip-publish --alias-tag $TAG

# Update test values
sed -i "s/tag: .*/tag: $TAG/" /workspace/devcontainer/test-values.yaml

echo "✅ Build complete. Install with:"
echo "helm upgrade openebs-dev openebs/openebs -n openebs --values /workspace/devcontainer/test-values.yaml"
```

### Add Sample Values Files

Create `devcontainer/values/` directory with:
- `minimal-test.yaml`
- `dev-with-monitoring.yaml`
- `production-like.yaml`

## Troubleshooting

### Image Pull Issues
If images aren't found:
```bash
# Check if images were built locally
docker images | grep openebs

# Verify image tags in pods
kubectl describe pod -n openebs <pod-name> | grep Image
```

### Build Cache Issues
With persistent cargo cache volume, subsequent builds should be faster:
```bash
# Check cache usage
du -sh ~/.cargo
```

## Integration with k3d/kind

For complete local testing:
```bash
# Create local k3d cluster
k3d cluster create openebs-dev --agents 2

# Deploy with local images
helm install openebs-dev openebs/openebs \
  --namespace openebs \
  --create-namespace \
  --values test-values.yaml
```

## Related Files

- **Main chart**: `openebs/charts/Chart.yaml`, `openebs/charts/values.yaml`
- **Mayastor chart**: `mayastor/extensions/chart/values.yaml`
- **Build system**: `mayastor/io-engine/CLAUDE.md`
- **Release scripts**: `*/scripts/release.sh` in each repo
- **Container setup**: `devcontainer/Dockerfile`, `devcontainer/docker-compose.yml`