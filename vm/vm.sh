#!/usr/bin/bash

SCRIPT_DIR="$(dirname "$(realpath "$0")")"

CMD="${1:-help}"
shift

USAGE_COMMANDS=("help" "status" "start" "stop" "destroy" "ssh" "console" "snapshot" "restore")

VM_NAME="mayastor-test"

CLOUD_IMAGE="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"

WORKSPACE_DIR="$(realpath "$SCRIPT_DIR/..")"

# Source config file if provided via --config flag (scan args without consuming them)
for arg in "$@"; do
  if [[ "$arg" == "--config" ]]; then
    # Find the next argument after --config
    found_config=false
    for ((i=1; i<=$#; i++)); do
      if [[ "${!i}" == "--config" && $((i+1)) -le $# ]]; then
        CONFIG_FILE="${!$((i+1))}"
        if [[ -f "$CONFIG_FILE" ]]; then
          echo "Sourcing config file: $CONFIG_FILE"
          source "$CONFIG_FILE"
        else
          echo "Warning: Config file not found: $CONFIG_FILE"
        fi
        found_config=true
        break
      fi
    done
    break
  fi
done

# VM Configuration - can be overridden by environment variables or CLI flags
VM_DISK_SIZE="${VM_DISK_SIZE:-100G}"
ADDITIONAL_DISK_COUNT="${ADDITIONAL_DISK_COUNT:-3}"
ADDITIONAL_DISK_SIZE="${ADDITIONAL_DISK_SIZE:-1G}"
WORKSPACE_MOUNT_ENABLED="${WORKSPACE_MOUNT_ENABLED:-true}"
WORKSPACE_SOURCE_PATH="${WORKSPACE_SOURCE_PATH:-$WORKSPACE_DIR}"
VM_MEMORY="${VM_MEMORY:-16384}"
VM_CPUS="${VM_CPUS:-16}"
VM_NETWORK="${VM_NETWORK:-bridge=virbr0}"

# Parse CLI flags
parse_flags() {
  local TEMP
  TEMP=$(getopt -o h --long help,disk-size:,additional-disks:,additional-disk-size:,no-workspace,workspace-path:,memory:,cpus:,network:,config: -n 'vm.sh' -- "$@")

  if [ $? != 0 ]; then
    echo "Failed parsing options." >&2
    exit 1
  fi

  eval set -- "$TEMP"

  while true; do
    case "$1" in
      --disk-size)
        VM_DISK_SIZE="$2"
        shift 2
        ;;
      --additional-disks)
        ADDITIONAL_DISK_COUNT="$2"
        shift 2
        ;;
      --additional-disk-size)
        ADDITIONAL_DISK_SIZE="$2"
        shift 2
        ;;
      --no-workspace)
        WORKSPACE_MOUNT_ENABLED="false"
        shift
        ;;
      --workspace-path)
        WORKSPACE_SOURCE_PATH="$2"
        WORKSPACE_MOUNT_ENABLED="true"
        shift 2
        ;;
      --memory)
        VM_MEMORY="$2"
        shift 2
        ;;
      --cpus)
        VM_CPUS="$2"
        shift 2
        ;;
      --network)
        VM_NETWORK="$2"
        shift 2
        ;;
      --config)
        # Already handled above, just consume
        shift 2
        ;;
      -h|--help)
        cmd_help
        exit 0
        ;;
      --)
        shift
        break
        ;;
      *)
        echo "Internal error!"
        exit 1
        ;;
    esac
  done

  # Return remaining arguments
  echo "$@"
}

# Parse flags if any arguments contain dashes (indicating flags)
if [[ "$*" == *--* ]]; then
  REMAINING_ARGS=$(parse_flags "$@")
  eval set -- "$REMAINING_ARGS"
fi

cmd_help() {
  echo "Usage: $0 <command> [options]"
  echo
  echo "Commands:"
  echo "  help      - Show this help"
  echo "  status    - Show VM status"
  echo "  start     - Start or create VM"
  echo "  stop      - Stop VM gracefully"
  echo "  destroy   - Destroy VM and remove disk"
  echo "  ssh       - SSH into VM"
  echo "  console   - Connect to VM console (Ctrl+] to exit)"
  echo "  snapshot  - Save VM state"
  echo "  restore   - Restore VM from snapshot"
  echo
  echo "VM Configuration Options:"
  echo "  --config FILE              - Source environment variables from config file"
  echo "  --disk-size SIZE           - Main VM disk size (default: 100G)"
  echo "  --additional-disks COUNT   - Number of additional storage disks (default: 3)"
  echo "  --additional-disk-size SIZE - Size of each additional disk (default: 1G)"
  echo "  --no-workspace             - Disable workspace folder mounting"
  echo "  --workspace-path PATH      - Custom workspace source path to mount"
  echo "  --memory SIZE              - VM memory in MB (default: 16384)"
  echo "  --cpus COUNT               - Number of vCPUs (default: 16)"
  echo "  --network CONFIG           - Network configuration (default: bridge=virbr0)"
  echo "  -h, --help                 - Show this help"
  echo
  echo "Environment Variables:"
  echo "  VM_DISK_SIZE, ADDITIONAL_DISK_COUNT, ADDITIONAL_DISK_SIZE"
  echo "  WORKSPACE_MOUNT_ENABLED, WORKSPACE_SOURCE_PATH"
  echo "  VM_MEMORY, VM_CPUS, VM_NETWORK"
  echo
  echo "Examples:"
  echo "  $0 start --memory 8192 --cpus 8"
  echo "  $0 start --disk-size 50G --additional-disks 5 --additional-disk-size 2G"
  echo "  $0 start --no-workspace"
  echo "  $0 start --config my-vm-config.env"
}

cmd_status() {
  echo "VM Status for: $VM_NAME"
  virsh list --all | grep -E "(Id|$VM_NAME)" || echo "VM not found"
  echo
  if virsh dominfo "$VM_NAME" &>/dev/null; then
    echo "VM Info:"
    virsh dominfo "$VM_NAME"
    echo
    echo "Network Info:"
    virsh domifaddr "$VM_NAME" 2>/dev/null || echo "No network info available"
  fi
}

cmd_start() {
  # Check if VM exists and use virtsh start in that case. otherwise we will use virt-install

  # Check if VM exists and start it if it does
  if virsh dominfo "$VM_NAME" &>/dev/null; then
    echo "VM $VM_NAME exists, starting..."
    virsh start "$VM_NAME"
    return $?
  fi

  echo "VM $VM_NAME doesn't exist, creating new VM..."

  # On virt-install ensure we have the cloud image downloaded.
  # Build new 100G disk image from cloud image for actual usage.

  local memory="$VM_MEMORY"
  local vcpus="$VM_CPUS"
  local image_name="mayastor-test-vm.qcow2"
  local network="$VM_NETWORK"

  # Download cloud image if not exists
  mkdir -p isos
  local cloud_image_file="isos/noble-server-cloudimg-amd64.img"
  if [[ ! -f "$cloud_image_file" ]]; then
    echo "Downloading cloud image..."
    (cd isos && wget "$CLOUD_IMAGE" -O noble-server-cloudimg-amd64.img)
  else
    echo "Cloud image already exists"
  fi

  # Remove old disk image and create fresh one
  if [[ -f "$image_name" ]]; then
    echo "Removing old disk image..."
    rm "$image_name"
  fi

  echo "Creating new ${VM_DISK_SIZE} disk image..."
  qemu-img create -f qcow2 -F qcow2 -b isos/noble-server-cloudimg-amd64.img "$image_name" "$VM_DISK_SIZE"

  # Create storage devices for Mayastor testing
  if [[ "$ADDITIONAL_DISK_COUNT" -gt 0 ]]; then
    echo "Creating ${ADDITIONAL_DISK_COUNT}x${ADDITIONAL_DISK_SIZE} storage devices for Mayastor testing..."
    for ((i=1; i<=ADDITIONAL_DISK_COUNT; i++)); do
      local storage_disk="${VM_NAME}-storage${i}.qcow2"
      if [[ -f "$storage_disk" ]]; then
        rm "$storage_disk"
      fi
      qemu-img create -f qcow2 "$storage_disk" "$ADDITIONAL_DISK_SIZE"
    done
  else
    echo "No additional storage devices requested (additional-disks=0)"
  fi

  # Build virt-install command with dynamic disk and filesystem options
  local virt_install_cmd=(
    virt-install
    --name "$VM_NAME"
    --noautoconsole
    --import
    --memory "$memory"
    --vcpus "$vcpus"
    --os-variant ubuntu24.04
    --disk bus=virtio,path="$image_name"
  )

  # Add additional storage disks
  for ((i=1; i<=ADDITIONAL_DISK_COUNT; i++)); do
    virt_install_cmd+=(--disk bus=virtio,path="${VM_NAME}-storage${i}.qcow2")
  done

  # Add workspace filesystem if enabled
  if [[ "$WORKSPACE_MOUNT_ENABLED" == "true" ]]; then
    virt_install_cmd+=(--filesystem type=mount,accessmode=passthrough,source="$WORKSPACE_SOURCE_PATH",target=workspace)
  fi

  # Add remaining options
  virt_install_cmd+=(
    --network "$network"
    --machine q35
    --iommu model=intel
    --cloud-init user-data=user-data.yaml
  )

  # Execute the command
  "${virt_install_cmd[@]}"

}

cmd_stop() {
  # todo: optional '--force' flag
  virsh shutdown "$VM_NAME"
}

cmd_destroy() {
  # destroy VM and remove disk image
  echo "Destroying VM and cleaning up..."

  # Stop VM if running
  virsh destroy "$VM_NAME" 2>/dev/null || true

  # Get disk path before undefining VM
  local disk_path
  disk_path=$(virsh dumpxml "$VM_NAME" 2>/dev/null | grep "source file=" | grep -oE "'/[^']*'" | tr -d "'")

  # Undefine VM
  virsh undefine "$VM_NAME" 2>/dev/null || true

  # Remove disk image if it exists and matches our naming pattern
  if [[ -n "$disk_path" && -f "$disk_path" ]]; then
    echo "Removing disk image: $disk_path"
    rm -f "$disk_path"
  fi

  # Clean up additional storage disks and snapshot files
  local storage_disks=("${VM_NAME}"-storage*.qcow2)
  if [[ -f "${storage_disks[0]}" ]]; then
    echo "Removing additional storage disks..."
    rm -f "${VM_NAME}"-storage*.qcow2
  fi

  if [[ -f "${VM_NAME}.snapshot" ]]; then
    echo "Removing snapshot file..."
    rm -f "${VM_NAME}.snapshot"
  fi

  echo "VM $VM_NAME destroyed and cleaned up"
}

cmd_console() {
  echo "Connecting to VM console (Ctrl+] to exit)..."
  virsh console "$VM_NAME"
}

cmd_ssh() {
  local vm_ip

  # Use guest agent to get IP (most reliable)
  vm_ip=$(virsh domifaddr "$VM_NAME" --source agent 2>/dev/null | grep -E 'enp[0-9]+s[0-9]+' | head -1 | grep -oE '192\.168\.[0-9]+\.[0-9]+')

  if [[ -z "$vm_ip" ]]; then
    echo "Error: Could not get VM IP address"
    echo "Make sure VM is running and guest agent is installed"
    return 1
  fi

  echo "Connecting to VM at $vm_ip..."
  ssh -o StrictHostKeyChecking=no ubuntu@"$vm_ip"
}

cmd_snapshot() {
  virsh save "$VM_NAME" "${VM_NAME}.snapshot"
}

cmd_restore() {
  virsh restore "${VM_NAME}.snapshot"
}

# Command dispatcher
case "$CMD" in
  help)
    cmd_help
    ;;
  status)
    cmd_status
    ;;
  start)
    cmd_start
    ;;
  stop)
    cmd_stop
    ;;
  destroy)
    cmd_destroy
    ;;
  ssh)
    cmd_ssh
    ;;
  console)
    cmd_console
    ;;
  snapshot)
    cmd_snapshot
    ;;
  restore)
    cmd_restore
    ;;
  *)
    echo "Unknown command: $CMD"
    echo "Run '$0 help' for usage"
    exit 1
    ;;
esac
