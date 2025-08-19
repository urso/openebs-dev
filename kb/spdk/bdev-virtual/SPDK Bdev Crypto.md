---
title: SPDK Bdev Crypto
type: note
permalink: spdk/bdev-virtual/spdk-bdev-crypto
---

# SPDK Bdev Crypto - Hardware-Accelerated Encryption

The Crypto bdev provides transparent encryption and decryption of data using hardware-accelerated cryptographic operations. It integrates with SPDK's acceleration framework to leverage Intel QAT, AES-NI, and other crypto accelerators.

## Architecture Overview

Crypto bdev intercepts I/O operations to encrypt writes and decrypt reads transparently:

```
Application
    ↓
Crypto Bdev (vbdev_crypto)
    ↓
┌─ WRITE ─┐           ┌─ READ ──┐
│ Encrypt │           │ Decrypt │
│    ↓    │           │    ↓    │
└─────────┘           └─────────┘
    ↓                       ↓
Base Bdev (any backend: NVMe, AIO, etc.)
    ↓
Physical Storage (encrypted data)
```

**Key Features:**
- **Transparent Encryption**: Applications see unencrypted data
- **Hardware Acceleration**: Leverages crypto accelerators (QAT, AES-NI)
- **Multiple Algorithms**: AES-CBC, AES-XTS support
- **Base Bdev Agnostic**: Works with any underlying storage

## Code References

### Core Implementation
- **Main Module**: `module/bdev/crypto/vbdev_crypto.c`
- **Header**: `module/bdev/crypto/vbdev_crypto.h`
- **RPC Interface**: `module/bdev/crypto/vbdev_crypto_rpc.c`
- **Build Config**: `module/bdev/crypto/Makefile`

### Function Table Implementation
**Location**: `module/bdev/crypto/vbdev_crypto.c:772-780`
```c
static const struct spdk_bdev_fn_table vbdev_crypto_fn_table = {
    .destruct                = vbdev_crypto_destruct,
    .submit_request          = vbdev_crypto_submit_request,
    .io_type_supported       = vbdev_crypto_io_type_supported,
    .get_io_channel          = vbdev_crypto_get_io_channel,
    .dump_info_json          = vbdev_crypto_dump_info_json,
    .get_memory_domains      = vbdev_crypto_get_memory_domains,
    .accel_sequence_supported = vbdev_crypto_sequence_supported,
};
```

### Key Function Implementations

#### **I/O Type Support** (`module/bdev/crypto/vbdev_crypto.c:764-770`)
```c
static bool
vbdev_crypto_io_type_supported(void *ctx, enum spdk_bdev_io_type io_type)
{
    struct vbdev_crypto *crypto_bdev = (struct vbdev_crypto *)ctx;
    
    // Forward to base bdev - crypto supports what base supports
    return spdk_bdev_io_type_supported(crypto_bdev->base_bdev, io_type);
}
```

#### **I/O Processing** (`module/bdev/crypto/vbdev_crypto.c:500-600`)
```c
static void
vbdev_crypto_submit_request(struct spdk_io_channel *ch, struct spdk_bdev_io *bdev_io)
{
    struct crypto_io_channel *crypto_ch = spdk_io_channel_get_ctx(ch);
    
    switch (bdev_io->type) {
    case SPDK_BDEV_IO_TYPE_READ:
        // Submit read to base, then decrypt on completion
        vbdev_crypto_submit_read(crypto_ch, bdev_io);
        break;
    case SPDK_BDEV_IO_TYPE_WRITE:
        // Encrypt data, then submit write to base  
        vbdev_crypto_submit_write(crypto_ch, bdev_io);
        break;
    default:
        // Pass through other operations unchanged
        spdk_bdev_io_resubmit(bdev_io, crypto_ch->base_ch);
        break;
    }
}
```

#### **Acceleration Sequence Support** (`module/bdev/crypto/vbdev_crypto.c:779`)
```c
static bool
vbdev_crypto_sequence_supported(void *ctx, enum spdk_bdev_io_type type)
{
    // Crypto operations can be part of acceleration sequences
    return type == SPDK_BDEV_IO_TYPE_READ || type == SPDK_BDEV_IO_TYPE_WRITE;
}
```

## Supported Features

### ✅ **Crypto Operations**
- **Encryption Algorithms**: AES-CBC, AES-XTS
- **Key Sizes**: 128-bit, 256-bit AES keys
- **Hardware Acceleration**: Intel QAT, AES-NI instruction set
- **Transparent Operation**: Applications unaware of encryption
- **Performance Optimization**: Acceleration sequence support

### 🔄 **Inherited from Base Bdev**
- **I/O Operations**: All operations supported by base bdev
- **Metadata**: Passes through base bdev metadata support
- **Zoned Storage**: ZNS features inherited from base
- **Hot-plug**: Dynamic configuration inherited
- **Memory Domains**: Base bdev memory requirements

### ✅ **Advanced Features** 
- **Memory Domains**: DMA-capable memory integration
- **Acceleration Sequences**: Integration with SPDK accel framework
- **Multiple Instances**: Multiple crypto bdevs with different keys
- **Configuration Management**: JSON-RPC interface

### ⚠️ **Crypto-Specific Considerations**
- **Key Management**: Keys stored in memory (not persistent)
- **Block Alignment**: Encryption requires block-aligned I/O
- **Performance Impact**: 10-50% overhead depending on hardware acceleration

## Configuration Examples

### **Basic Crypto Bdev Creation**
```bash
# Create crypto bdev with AES-CBC encryption
./scripts/rpc.py bdev_crypto_create nvme0n1 crypto_nvme0n1 crypto_aesni_mb AES_CBC

# Parameters:
# nvme0n1: Base bdev name
# crypto_nvme0n1: Crypto bdev name
# crypto_aesni_mb: Crypto PMD (software crypto using AES-NI)
# AES_CBC: Encryption algorithm
```

### **Hardware-Accelerated Crypto (Intel QAT)**
```bash
# Create crypto bdev using Intel QAT hardware
./scripts/rpc.py bdev_crypto_create \
    base_bdev \
    crypto_qat_bdev \
    crypto_qat \
    AES_XTS

# Requires Intel QAT hardware and drivers
# Provides much better performance than software crypto
```

### **Multiple Crypto Bdevs**
```bash
# Create multiple crypto bdevs with different keys
./scripts/rpc.py bdev_crypto_create disk1 crypto_disk1 crypto_aesni_mb AES_CBC
./scripts/rpc.py bdev_crypto_create disk2 crypto_disk2 crypto_aesni_mb AES_CBC

# Each crypto bdev uses a different encryption key
# Keys are generated automatically or can be specified
```

### **Stacking Crypto with Other Virtual Bdevs**
```bash
# Example: RAID of encrypted disks
./scripts/rpc.py bdev_crypto_create nvme0n1 crypto_nvme0 crypto_aesni_mb AES_CBC  
./scripts/rpc.py bdev_crypto_create nvme1n1 crypto_nvme1 crypto_aesni_mb AES_CBC
./scripts/rpc.py bdev_raid_create -n encrypted_raid0 -z 64 -r 0 -b "crypto_nvme0 crypto_nvme1"
```

## Supported Crypto PMDs

### **Software Crypto PMDs**
| PMD Name | Hardware | Algorithm Support | Performance |
|----------|----------|-------------------|-------------|
| `crypto_aesni_mb` | Intel AES-NI | AES-CBC, AES-XTS | Good |
| `crypto_openssl` | Software | AES-CBC, AES-XTS | Moderate |

### **Hardware Crypto PMDs**  
| PMD Name | Hardware | Algorithm Support | Performance |
|----------|----------|-------------------|-------------|
| `crypto_qat` | Intel QAT | AES-CBC, AES-XTS | Excellent |
| `crypto_aesni_gcm` | Intel AES-NI | AES-GCM | Good |

### **PMD Selection Guidelines**
- **Intel QAT**: Best performance for production workloads
- **AES-NI**: Good balance of performance and availability
- **OpenSSL**: Fallback option when hardware unavailable

## Performance Characteristics

### **Encryption Overhead**
| Acceleration | Read Overhead | Write Overhead | IOPS Impact |
|--------------|---------------|----------------|-------------|
| Intel QAT | +5-15μs | +10-30μs | -5 to -15% |
| AES-NI | +10-30μs | +20-50μs | -15 to -30% |
| Software | +50-200μs | +100-400μs | -50 to -70% |

### **Throughput Impact**
- **QAT Hardware**: ~5-15% throughput reduction
- **AES-NI**: ~15-30% throughput reduction  
- **Software Crypto**: ~50-70% throughput reduction

### **CPU Usage**
- **Hardware Crypto**: Minimal CPU impact
- **AES-NI**: Moderate CPU usage increase
- **Software**: Significant CPU usage increase

## Crypto Algorithm Details

### **AES-CBC (Cipher Block Chaining)**
```bash
# Good general-purpose encryption
./scripts/rpc.py bdev_crypto_create base_bdev crypto_cbc crypto_aesni_mb AES_CBC

# Characteristics:
# - Sequential processing (blocks depend on previous blocks)
# - Good security properties
# - Moderate performance
```

### **AES-XTS (XEX-based Tweaked-codebook mode)**
```bash
# Optimized for storage encryption
./scripts/rpc.py bdev_crypto_create base_bdev crypto_xts crypto_qat AES_XTS

# Characteristics:  
# - Parallel processing possible
# - Designed for storage devices
# - Better performance than CBC
# - Industry standard for storage encryption
```

## Key Management

### **Automatic Key Generation**
```bash
# SPDK generates random 256-bit keys automatically
./scripts/rpc.py bdev_crypto_create base crypto_auto crypto_aesni_mb AES_XTS
# Key is generated and stored in memory only
```

### **Key Security Considerations**
- **Memory Storage**: Keys stored in process memory
- **No Persistence**: Keys lost on process restart
- **Process Security**: Protect SPDK process from memory dumps
- **Key Rotation**: Not supported - would require data re-encryption

### **Production Key Management**
```c
// Example: External key management integration
// Applications should integrate with enterprise key management systems
// Keys should be loaded from secure key stores, not hardcoded
```

## Integration Examples

### **Encrypted Logical Volumes**
```bash
# Create encrypted LVS
./scripts/rpc.py bdev_crypto_create nvme0n1 crypto_nvme crypto_aesni_mb AES_XTS
./scripts/rpc.py bdev_lvol_create_lvstore crypto_nvme encrypted_lvs
./scripts/rpc.py bdev_lvol_create -l encrypted_lvs -n vol1 -s 10737418240

# Result: Logical volumes with transparent encryption
```

### **Encrypted RAID Arrays**
```bash
# Encrypt individual drives before RAID
./scripts/rpc.py bdev_crypto_create nvme0n1 crypto0 crypto_qat AES_XTS
./scripts/rpc.py bdev_crypto_create nvme1n1 crypto1 crypto_qat AES_XTS  
./scripts/rpc.py bdev_crypto_create nvme2n1 crypto2 crypto_qat AES_XTS

# Create RAID on encrypted bdevs
./scripts/rpc.py bdev_raid_create -n encrypted_raid5 -z 64 -r 5f -b "crypto0 crypto1 crypto2"
```

### **Stacked Virtual Bdevs**
```bash
# Example: Compressed encrypted storage
./scripts/rpc.py bdev_crypto_create nvme0n1 crypto_base crypto_aesni_mb AES_XTS
./scripts/rpc.py bdev_compress_create crypto_base compressed_crypto

# Or: Encrypted compressed storage  
./scripts/rpc.py bdev_compress_create nvme0n1 compress_base
./scripts/rpc.py bdev_crypto_create compress_base crypto_compress crypto_aesni_mb AES_XTS
```

## Performance Optimization

### **Hardware Selection**
```bash
# Check available crypto PMDs
./scripts/rpc.py accel_get_stats

# Verify QAT availability
lspci | grep -i quickassist
ls /dev/qat_*

# Check AES-NI support
grep -m1 -o aes /proc/cpuinfo
```

### **Configuration Tuning**
```bash
# Increase crypto device queue depth for QAT
# Configure in DPDK crypto device settings
# Adjust based on workload and hardware capabilities
```

### **I/O Patterns**
- **Large Block Sizes**: Better encryption efficiency
- **Sequential I/O**: Can leverage crypto pipeline better
- **Queue Depth**: Higher QD can hide crypto latency

## Security Considerations

### **Data Protection**
- **Data at Rest**: All data encrypted on storage device
- **Transparent to Apps**: Applications handle unencrypted data
- **Key Protection**: Critical - keys stored in process memory
- **Side Channel Attacks**: Hardware crypto provides better protection

### **Threat Model**
✅ **Protects Against:**
- **Storage Device Theft**: Data unreadable without keys
- **Cold Boot Attacks**: Data encrypted on storage
- **Forensic Analysis**: Storage contains only encrypted data

⚠️ **Does NOT Protect Against:**
- **Process Memory Dumps**: Keys visible in memory
- **Runtime Attacks**: Applications see unencrypted data
- **Side Channel Attacks**: Without hardware acceleration

### **Best Practices**
```bash
# Use hardware crypto when available
./scripts/rpc.py bdev_crypto_create base crypto crypto_qat AES_XTS

# Protect SPDK process
# - Run with minimal privileges
# - Disable core dumps
# - Monitor process access
# - Use memory protection features
```

## Troubleshooting

### **Common Issues**
```bash
# Crypto PMD not found
./scripts/rpc.py accel_get_stats  # Check available crypto devices
ldd $(which spdk_tgt) | grep crypto  # Check crypto library linking

# Performance issues
./scripts/rpc.py bdev_get_iostat -b crypto_bdev  # Monitor crypto bdev performance
./scripts/rpc.py accel_get_stats  # Check crypto device utilization

# QAT driver issues
ls /dev/qat_*  # Check QAT device files
dmesg | grep qat  # Check kernel messages
```

### **Debugging Steps**
```bash
# Test with software crypto first
./scripts/rpc.py bdev_crypto_create test_base test_crypto crypto_openssl AES_CBC

# Verify base bdev performance
./scripts/rpc.py bdev_get_iostat -b test_base

# Compare crypto vs non-crypto performance
fio --compare-performance
```

## Advanced Topics

### **Custom Crypto Integration**
```c
// Example: Integrating custom crypto accelerators
// See module/bdev/crypto/vbdev_crypto.c for patterns
// Integration requires SPDK accel framework support
```

### **Performance Analysis**
```bash
# Measure crypto overhead
./benchmark_crypto_overhead.sh

# Profile crypto operations
perf record -g ./spdk_tgt -c crypto_config.json
perf report --crypto-only
```

---

The Crypto bdev provides enterprise-grade transparent encryption for SPDK applications, leveraging hardware acceleration for optimal performance while maintaining compatibility with all underlying storage backends.