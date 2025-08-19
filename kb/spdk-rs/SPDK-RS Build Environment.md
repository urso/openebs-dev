---
title: SPDK-RS Build Environment
type: note
permalink: spdk-rs/spdk-rs-build-environment
---

# SPDK-RS Build Environment

SPDK-RS uses Nix package manager to provide a reproducible, isolated build environment with all necessary tools and libraries for cross-platform SPDK development.

## Nix-Based Development

### Why Nix?
- **Reproducible Builds** - Exact same environment across machines
- **Dependency Isolation** - No conflicts with system packages  
- **Version Pinning** - Precise control over tool and library versions
- **Cross-Compilation** - Seamless support for multiple architectures

### Requirements
- **Platform**: Linux only (SPDK requirement)
- **Architectures**: x86_64 (Nehalem+), aarch64 (with crypto)
- **Nix**: Package manager or NixOS distribution

## Environment Setup

### Installing Nix
```bash
# Install Nix package manager on existing Linux
curl -L https://nixos.org/nix/install | sh

# Or use NixOS distribution
# Download from: https://nixos.org/download/#nixos-iso
```

### Starting SPDK-RS Shell
```bash
# Enter reproducible development environment
cd spdk-rs/
nix-shell

# With specific configurations
nix-shell --argstr spdk release --argstr rust nightly
```

**First Run**: Downloads and builds all dependencies (can take significant time)  
**Subsequent Runs**: Uses cached dependencies for fast startup

### Shell Configuration Options

**SPDK Configuration**:
```bash
nix-shell --argstr spdk develop  # Debug SPDK (default)
nix-shell --argstr spdk release  # Optimized SPDK  
nix-shell --argstr spdk none     # No SPDK package (custom build)
```

**Rust Configuration**:
```bash
nix-shell --argstr rust stable   # Stable Rust (default)
nix-shell --argstr rust nightly  # Nightly Rust
nix-shell --argstr rust asan     # Address Sanitizer enabled
nix-shell --argstr rust none     # System Rust (rustup)
```

## SPDK Version Management

### OpenEBS SPDK Integration
SPDK-RS uses OpenEBS-patched SPDK versions specifically configured for Mayastor:

```nix
# nix/pkgs/libspdk/default.nix
src = fetchFromGitHub {
  owner = "openebs";
  repo = "spdk";
  rev = "commit_hash_here";  # Pinned OpenEBS SPDK version
  sha256 = "hash_here";
};
```

**Branch Naming**: `v24.05.x-mayastor` (SPDK version + OpenEBS suffix)

### Version Compatibility
- **spdk-rs 0.2.x** → SPDK v24.01+ with OpenEBS patches
- **Precise Pinning** - Each spdk-rs version targets specific SPDK commit
- **Automatic Updates** - OpenEBS maintains compatibility across releases

### Custom SPDK Development
For SPDK modifications or newer versions:

```bash
# Clone OpenEBS SPDK
git clone git@github.com:openebs/spdk.git
cd spdk
git checkout -t origin/v24.01.x-mayastor
git submodule update --recursive --init

# Start spdk-rs without SPDK package
cd ../spdk-rs
nix-shell --argstr spdk-path ~/myspdk
```

## Cross-Compilation Support

### Architecture Support
```bash
# x86_64 (default)
nix-shell

# aarch64 (ARM64) 
nix-shell --argstr target aarch64-unknown-linux-gnu
```

### Build Configuration
SPDK-RS includes cross-compilation helpers:

```nix
# Configure for target architecture
AS = if targetPlatform.isAarch64 then "nasm" else "yasm";
configureFlags = [
  "--target-arch=${if targetPlatform.isAarch64 then "native" else "nehalem"}"
] ++ lib.optionals targetPlatform.isAarch64 [
  "--with-crypto"  # Required for aarch64
];
```

### Known Cross-Compilation Issues
- **Archive Indexing** - Resolved with proper cross-compilation tools
- **vhost Logic** - Requires patches for non-x86_64 (included in OpenEBS SPDK)

## Build Process

### Standard Build
```bash
# Inside nix-shell
cargo build                    # Debug build
cargo build --release         # Release build
cargo build --example hello_world
```

### Custom SPDK Build
```bash
# Configure and build SPDK
./build_scripts/build_spdk.sh configure
./build_scripts/build_spdk.sh make

# Build spdk-rs (automatically detects SPDK changes)
cargo build
```

### Build Script Integration
SPDK-RS build.rs automatically:
- Generates FFI bindings with bindgen
- Compiles C helper functions
- Links against SPDK libraries
- Configures library search paths

```rust
// build.rs key operations
configure_spdk()?;           // Find and configure SPDK
compile_spdk_helpers()?;     // Build C helpers
generate_bindings()?;        // Create Rust FFI bindings
```

## Development Tools

### Included in Nix Shell
- **Rust Toolchain** - Compiler, cargo, rustfmt
- **SPDK Library** - Pre-built with correct configuration
- **Build Tools** - bindgen, cc, pkg-config
- **System Libraries** - DPDK, uring, crypto, numa
- **Development Utilities** - gdb, valgrind, perf

### Code Formatting
```bash
# Rust formatting (automatic with nightly rustfmt)
cargo fmt

# SPDK code formatting
./build_scripts/build_spdk.sh fmt
```

### Testing
```bash
# Run Rust tests
cargo test

# Run examples (requires root for SPDK)
sudo ./target/debug/examples/hello_world
```

## Environment Variables

### Key Variables Set by Nix
```bash
SPDK_ROOT_DIR=/nix/store/.../spdk    # SPDK installation path
RUST_NIGHTLY_PATH=/nix/store/.../    # Nightly rust path
PKG_CONFIG_PATH=...                  # Library discovery
LD_LIBRARY_PATH=...                  # Runtime linking
```

### Build Customization
```bash
# Force rebuild on SPDK changes
export SPDK_RS_BUILD_USE_LOGS=yes

# Custom SPDK path
export SPDK_ROOT_DIR=/path/to/custom/spdk
```

## Reproducible Builds

### Version Pinning
All dependencies pinned in `nix/sources.json`:
```json
{
  "nixpkgs": {
    "branch": "nixos-unstable",
    "revision": "abc123...",
    "sha256": "hash..."
  }
}
```

### Build Caching
- **Binary Caches** - Nix downloads pre-built packages when possible
- **Local Cache** - Built dependencies cached between sessions
- **Shared Cache** - Team can share build artifacts

### CI/CD Integration
```yaml
# GitHub Actions example
- uses: cachix/install-nix-action@v18
- name: Build spdk-rs
  run: |
    nix-shell --run "cargo build --release"
```

## Troubleshooting

### Common Issues

**Missing SPDK Headers**:
```bash
# Verify SPDK_ROOT_DIR is set correctly
echo $SPDK_ROOT_DIR
ls $SPDK_ROOT_DIR/include/spdk/
```

**Library Linking Errors**:
```bash
# Check PKG_CONFIG_PATH
pkg-config --list-all | grep spdk
```

**Permission Errors with Examples**:
```bash
# SPDK requires root for hardware access
sudo -E ./target/debug/examples/hello_world
#      ^ Preserve environment variables
```

### Build Script Debugging
```bash
# Verbose build output
RUST_LOG=debug cargo build -v

# Inspect generated bindings
cat target/debug/build/spdk-rs-*/out/libspdk.rs
```

## Integration with Existing Projects

### Adding to Cargo.toml
```toml
[dependencies]
spdk-rs = { git = "https://github.com/openebs/spdk-rs", branch = "develop" }

[build-dependencies]
bindgen = "0.70.1"
cc = "1.1.31"
pkg-config = "0.3.31"
```

### Custom Build Scripts
```rust
// build.rs for projects using spdk-rs
fn main() {
    println!("cargo:rustc-link-lib=static=spdk_bdev");
    println!("cargo:rustc-link-lib=static=spdk_util");
    // ... other SPDK libraries
}
```

For understanding SPDK source organization, see [[SPDK Source Tree]].

For practical build examples, see [[SPDK-RS Integration Patterns]].