#!/usr/bin/env bash
set -euo pipefail

# create-win-usb.sh
# Create a UEFI-bootable Windows USB on macOS using GPT + FAT32.
# - Formats the target USB as GPT (not MBR)
# - Copies ISO contents
# - If sources/install.wim > 4GB, splits it via wimlib
#
# Usage:
#   sudo ./create-win-usb.sh -i /path/to/Win.iso [-d diskX] [-n WINDOWSUSB] [-s 3800]
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

need_root() {
  if [[ $EUID -ne 0 ]]; then
    err "Please run as root (e.g., sudo $0 ...)"
  fi
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
    info "Homebrew not found."
    if confirm "Install Homebrew automatically to get wimlib?"; then
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || true)"
      eval "$(/usr/local/bin/brew shellenv 2>/dev/null || true)"
      brew install wimlib
    else
      err "wimlib is required to split install.wim >4GB. Install it and re-run."
    fi
  fi
}

usage() {
  cat <<EOF
Usage: sudo $0 -i /path/to/Windows.iso [-d diskX] [-n WINDOWSUSB] [-s 3800]

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

need_root

# --- Select disk -------------------------------------------------------------

if [[ -z "$DISK_ID" ]]; then
  info "Available disks:"
  /usr/sbin/diskutil list
  read -r -p "Enter the identifier of your USB drive (e.g., disk2): " DISK_ID
fi

[[ -n "$DISK_ID" ]] || err "No disk identifier provided."
[[ -e "/dev/$DISK_ID" ]] || err "/dev/$DISK_ID does not exist."

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

info "Mounting ISO: $ISO_PATH"
/usr/bin/hdiutil attach -nobrowse -readonly "$ISO_PATH" >/tmp/winiso.attach.out
ISO_VOL="$(detect_iso_volume)"
[[ -d "$ISO_VOL" ]] || err "Could not locate mounted ISO volume."

info "ISO mounted at: $ISO_VOL"

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
  /usr/local/bin/wimlib-imagex split "$WIM_PATH" "$USB_VOL/sources/install.swm" "$SPLIT_MB"
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
