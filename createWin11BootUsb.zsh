#!/usr/bin/env bash
set -euo pipefail

# create-win-usb.sh
# Create a UEFI-bootable Windows USB on macOS using GPT + FAT32.
# - Formats the target USB as GPT (not MBR)
# - Copies ISO contents
# - If sources/install.wim > 4GB, splits it via wimlib
#
# Usage:
#   ./create-win-usb.sh -i /path/to/Win.iso [-d diskX] [-n WINDOWSUSB] [-s 3800]
#
# Notes:
#   * Requires: rsync, hdiutil, diskutil
#   * Optional: Homebrew (for auto-install of wimlib), or preinstalled wimlib
#   * Target machines should boot in UEFI mode (common for modern PCs)

USB_NAME="WINDOWSUSB"
SPLIT_MB="3800"
DISK_ID=""
ISO_PATH=""

# --- Helpers -----------------------------------------------------------------

err() { echo "Error: $*" >&2; exit 1; }
info() { echo "==> $*"; }
confirm() {
  local prompt="$1"
  read -r -p "$prompt [y/N]: " ans
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

mount_rw_fat_if_needed() {
  # Workaround for occasional read-only FAT32 mount on newer macOS versions
  local vol_path="$1"
  if [[ ! -w "$vol_path" ]]; then
    info "Volume appears read-only, remounting FAT32 as read-write..."
    local dev
    dev="$(/usr/sbin/diskutil info "$vol_path" | awk -F': ' '/Device Node/{print $2}')"
    [[ -n "$dev" ]] || err "Could not determine device node for $vol_path"
    /usr/sbin/diskutil unmount "$dev" || true
    /bin/mkdir -p "$vol_path"
    /sbin/mount -w -t msdos "$dev" "$vol_path"
  fi
}

detect_iso_volume() {
  # Try to find the mounted ISO volume path. Prefer CCCOMA_* (Microsoft ISOs).
  local candidates=()
  while IFS= read -r line; do
    candidates+=("$line")
  done < <(ls /Volumes 2>/dev/null | grep -E '^CCCOMA_|^ESD-ISO|^ESD-USB|^DVD|^Windows' || true)

  if [[ ${#candidates[@]} -eq 1 ]]; then
    echo "/Volumes/${candidates[0]}"
    return
  fi

  # Fallback: pick the newest mount that isn't the USB target
  local newest
  newest="$(/bin/ls -t1 /Volumes 2>/dev/null | head -n1 || true)"
  [[ -n "$newest" ]] || err "Unable to detect ISO volume under /Volumes. Mount the ISO first."
  echo "/Volumes/$newest"
}

file_size_bytes() {
  # Prints size in bytes
  /bin/ls -ln "$1" | awk '{print $5}'
}

ensure_wimlib() {
  if have_cmd wimlib-imagex; then
    return 0
  fi
  info "wimlib not found."
  if have_cmd brew; then
    info "Installing wimlib via Homebrew..."
    brew install wimlib
  else
    err "wimlib is required to split install.wim >4GB. Please install Homebrew (https://brew.sh) and wimlib, then re-run."
  fi
}

get_wimlib_path() {
  # Find wimlib-imagex in PATH (works for both Intel and Apple Silicon Macs)
  command -v wimlib-imagex || echo "wimlib-imagex"
}

usage() {
  cat <<EOF
Usage: $0 -i /path/to/Windows.iso [-d diskX] [-n WINDOWSUSB] [-s 3800]

Options:
  -i   Path to Windows ISO (required)
  -d   Target disk identifier (e.g., disk2). If omitted, you'll be prompted.
  -n   USB volume name (default: ${USB_NAME})
  -s   Split size in MB for install.wim (default: ${SPLIT_MB})

This script:
  * Erases the target disk as GPT + FAT32
  * Copies ISO contents to the USB
  * Splits sources/install.wim to .swm chunks if >4GB
EOF
}

# --- Args --------------------------------------------------------------------

while getopts ":i:d:n:s:h" opt; do
  case "$opt" in
    i) ISO_PATH="$OPTARG" ;;
    d) DISK_ID="$OPTARG" ;;
    n) USB_NAME="$OPTARG" ;;
    s) SPLIT_MB="$OPTARG" ;;
    h|\?) usage; exit 0 ;;
  esac
done

[[ -n "$ISO_PATH" ]] || { usage; err "ISO path is required (-i)"; }
[[ -f "$ISO_PATH" ]] || err "ISO not found: $ISO_PATH"

# --- Validate ISO file -------------------------------------------------------

info "Validating ISO file..."

# Check file extension
if [[ ! "$ISO_PATH" =~ \.(iso|ISO)$ ]]; then
  err "File does not have .iso extension: $ISO_PATH"
fi

# Check if file is actually an ISO (check for ISO 9660 signature)
# ISO 9660 has "CD001" at byte offset 32769 (0x8001)
if have_cmd dd && have_cmd xxd; then
  ISO_SIGNATURE=$(dd if="$ISO_PATH" bs=1 skip=32769 count=5 2>/dev/null | xxd -p)
  if [[ "$ISO_SIGNATURE" != "4344303031" ]]; then  # "CD001" in hex
    err "File does not appear to be a valid ISO image (missing ISO 9660 signature): $ISO_PATH"
  fi
  info "✓ ISO file signature validated"
else
  # Fallback: check file command if available
  if have_cmd file; then
    FILE_TYPE=$(file -b "$ISO_PATH")
    if [[ ! "$FILE_TYPE" =~ (ISO|9660|UDF|boot) ]]; then
      err "File does not appear to be a valid ISO image: $ISO_PATH"
    fi
    info "✓ ISO file type validated"
  else
    info "⚠ Could not verify ISO signature (dd/xxd/file not available), proceeding anyway..."
  fi
fi

# --- Select disk -------------------------------------------------------------

if [[ -z "$DISK_ID" ]]; then
  info "Available disks:"
  /usr/sbin/diskutil list
  read -r -p "Enter the identifier of your USB drive (e.g., disk2): " DISK_ID
fi

[[ -n "$DISK_ID" ]] || err "No disk identifier provided."
[[ -e "/dev/$DISK_ID" ]] || err "/dev/$DISK_ID does not exist."

# --- Validate USB disk -------------------------------------------------------

info "Validating disk /dev/$DISK_ID..."

# Check if disk is removable (external)
DISK_INFO=$(/usr/sbin/diskutil info "/dev/$DISK_ID" 2>&1)
if [[ $? -ne 0 ]]; then
  err "Failed to get disk information for /dev/$DISK_ID"
fi

# Check for removable media flag
if ! echo "$DISK_INFO" | grep -qi "Removable Media:.*Yes\|Protocol:.*USB\|Device Location:.*External"; then
  echo "$DISK_INFO" | grep -E "Removable Media:|Protocol:|Device Location:" || true
  err "Disk /dev/$DISK_ID does not appear to be a removable USB drive. Refusing to proceed for safety."
fi

# Additional check: ensure it's not an internal disk
if echo "$DISK_INFO" | grep -qi "Device Location:.*Internal\|Protocol:.*SATA\|Protocol:.*PCI"; then
  echo "$DISK_INFO" | grep -E "Removable Media:|Protocol:|Device Location:" || true
  err "Disk /dev/$DISK_ID appears to be an internal disk. Refusing to proceed for safety."
fi

# Check if it's the boot disk
BOOT_DISK=$(/usr/sbin/diskutil info / | awk -F'[:/ ]+' '/Device Node/{print $3}')
if [[ "/dev/$DISK_ID" == "/dev/$BOOT_DISK" ]] || [[ "$DISK_ID" == "$BOOT_DISK" ]]; then
  err "Disk /dev/$DISK_ID is your boot disk! Refusing to proceed for safety."
fi

# Display key disk information for user confirmation
echo ""
echo "Disk Information:"
echo "$DISK_INFO" | grep -E "Device Node:|Media Name:|Device / Media Name:|Total Size:|Protocol:|Removable Media:|Device Location:" || true
echo ""

info "✓ Disk validated as removable USB drive"

info "You selected /dev/$DISK_ID."
echo "!!! WARNING: This will ERASE /dev/$DISK_ID completely."
read -r -p "Type ERASE to continue: " CONFIRM_ERASE
[[ "$CONFIRM_ERASE" == "ERASE" ]] || err "Aborted by user."

# --- Unmount + Erase as GPT + FAT32 -----------------------------------------

info "Unmounting /dev/$DISK_ID ..."
/usr/sbin/diskutil unmountDisk "/dev/$DISK_ID" || true

info "Erasing /dev/$DISK_ID as GPT + FAT32 (${USB_NAME}) ..."
/usr/sbin/diskutil eraseDisk MS-DOS "$USB_NAME" GPT "/dev/$DISK_ID"

USB_VOL="/Volumes/$USB_NAME"
# Give macOS a moment to mount the new volume
sleep 2
mount_rw_fat_if_needed "$USB_VOL"

# --- Mount ISO ---------------------------------------------------------------

# Check if ISO is already mounted
info "Checking if ISO is already mounted..."
ALREADY_MOUNTED=""
HDIUTIL_OUTPUT=$(/usr/bin/hdiutil info 2>/dev/null) || HDIUTIL_OUTPUT=""

if [[ -n "$HDIUTIL_OUTPUT" ]]; then
  # Look for our ISO path, then find the mount point in following lines
  FOUND_ISO=false
  while IFS= read -r line; do
    if [[ "$line" == *"$ISO_PATH"* ]]; then
      FOUND_ISO=true
    elif [[ "$FOUND_ISO" == true && "$line" == *"/Volumes/"* ]]; then
      # Extract mount point (format: /dev/diskX /Volumes/...)
      ALREADY_MOUNTED=$(echo "$line" | grep -o '/Volumes/[^[:space:]]*' | head -1)
      break
    fi
  done <<< "$HDIUTIL_OUTPUT"
fi

if [[ -n "$ALREADY_MOUNTED" && -d "$ALREADY_MOUNTED" ]]; then
  info "ISO already mounted at: $ALREADY_MOUNTED"
  ISO_VOL="$ALREADY_MOUNTED"
else
  info "Mounting ISO: $ISO_PATH"
  /usr/bin/hdiutil attach -nobrowse -readonly "$ISO_PATH" >/tmp/winiso.attach.out || err "Failed to mount ISO"
  ISO_VOL="$(detect_iso_volume)"
  [[ -d "$ISO_VOL" ]] || err "Could not locate mounted ISO volume."
  info "ISO mounted at: $ISO_VOL"
fi

# --- Determine WIM path/size -------------------------------------------------

WIM_PATH="$ISO_VOL/sources/install.wim"
ESD_PATH="$ISO_VOL/sources/install.esd"

if [[ -f "$WIM_PATH" ]]; then
  INSTALL_PATH="$WIM_PATH"
elif [[ -f "$ESD_PATH" ]]; then
  # Some ISOs ship install.esd instead; typically <4GB, can be copied directly
  INSTALL_PATH="$ESD_PATH"
else
  err "Neither install.wim nor install.esd found in $ISO_VOL/sources/"
fi

INSTALL_SIZE="$(file_size_bytes "$INSTALL_PATH")"
FOUR_GB=$((4*1024*1024*1024))

# --- Copy files --------------------------------------------------------------

info "Copying files to USB (this may take a while)..."
if [[ "$INSTALL_PATH" == "$WIM_PATH" && "$INSTALL_SIZE" -gt "$FOUR_GB" ]]; then
  info "install.wim > 4GB; copying all except install.wim, then splitting..."
  /usr/bin/rsync -avh --progress --exclude="sources/install.wim" "$ISO_VOL"/ "$USB_VOL"
  ensure_wimlib

  # Ensure target sources dir exists
  /bin/mkdir -p "$USB_VOL/sources"

  info "Splitting install.wim into ${SPLIT_MB}MB chunks as install.swm..."
  WIMLIB_CMD="$(get_wimlib_path)"
  "$WIMLIB_CMD" split "$WIM_PATH" "$USB_VOL/sources/install.swm" "$SPLIT_MB"
else
  info "No split needed; copying entire ISO contents..."
  /usr/bin/rsync -avh --progress "$ISO_VOL"/ "$USB_VOL"
fi

# --- Sync, detach, eject -----------------------------------------------------

info "Flushing writes..."
/bin/sync

info "Detaching ISO..."
/usr/bin/hdiutil detach "$ISO_VOL" || true

info "Ejecting USB disk..."
/usr/sbin/diskutil eject "/dev/$DISK_ID" || true

info "All done! Your GPT/FAT32 Windows USB (${USB_NAME}) is ready for UEFI boot."
