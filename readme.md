# Windows 11 Bootable USB Creator for macOS

A bash script to create a UEFI-bootable Windows 11 USB drive on macOS using GPT partitioning and FAT32 formatting.

## Overview

This script automates the process of creating a bootable Windows installation USB drive from a Windows ISO file on macOS. It handles the complexities of:

- GPT (GUID Partition Table) partitioning for UEFI boot compatibility
- FAT32 formatting (required for UEFI boot)
- Handling large `install.wim` files (>4GB) that exceed FAT32's file size limit
- Automatic detection of already-mounted ISOs
- Safety checks to prevent accidental erasure of internal drives

## Features

- ✅ **UEFI Boot Compatible**: Uses GPT + FAT32 for modern UEFI systems
- ✅ **Large File Handling**: Automatically splits `install.wim` files larger than 4GB into `.swm` chunks
- ✅ **Safety Checks**: Validates that target disk is a removable USB drive
- ✅ **ISO Validation**: Verifies ISO file integrity before processing
- ✅ **Smart Mounting**: Detects already-mounted ISOs to avoid errors
- ✅ **Progress Indicators**: Shows real-time progress during file copying

## Prerequisites

### Required Tools (Built-in on macOS)

These tools are included with macOS:
- `diskutil` - Disk management utility
- `hdiutil` - Disk image handling utility
- `rsync` - File synchronization and copying

### Optional Tools

#### wimlib (Required only for large install.wim files > 4GB)

**wimlib** is needed to split large Windows installation files that exceed FAT32's 4GB file size limit.

**Installation via Homebrew:**

```bash
# Install Homebrew if you don't have it
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install wimlib
brew install wimlib
```

The script will automatically attempt to install wimlib via Homebrew if needed and a large `install.wim` file is detected.

## Requirements

- **macOS**: 10.13 (High Sierra) or later
- **USB Drive**: 8GB minimum (16GB+ recommended for Windows 11)
- **Windows ISO**: Official Windows 10/11 ISO file
- **Admin Rights**: Required for disk operations (script will prompt for password)

## Usage

### Basic Usage

```bash
./createWinBootUSb.zsh -i /path/to/Windows.iso -d diskX -n WIN11
```

### Parameters

| Parameter | Required | Description | Default |
|-----------|----------|-------------|---------|
| `-i` | **Yes** | Path to Windows ISO file | - |
| `-d` | No | Target disk identifier (e.g., `disk2`, `disk5`) | Interactive prompt |
| `-n` | No | USB volume name | `WINDOWSUSB` |
| `-s` | No | Split size in MB for install.wim | `3800` |
| `-h` | No | Show help message | - |

### Interactive Mode

If you omit the `-d` parameter, the script will show available disks and prompt you to select one:

```bash
./createWinBootUSb.zsh -i ~/Downloads/Win11.iso
```

### Examples

**Example 1: Basic usage with disk selection**
```bash
./createWinBootUSb.zsh -i ~/Downloads/Win11_22H2_English_x64.iso -d disk2 -n WIN11
```

**Example 2: Custom split size for install.wim**
```bash
./createWinBootUSb.zsh -i ~/Downloads/Win11.iso -d disk3 -n WINDOWS -s 4000
```

**Example 3: Let the script prompt for disk selection**
```bash
./createWinBootUSb.zsh -i ~/Downloads/Win11.iso
```

## How It Works

### Process Flow

1. **Validation**
   - Validates ISO file exists and has correct signature (ISO 9660)
   - Validates target disk is a removable USB drive (not internal/boot disk)
   - Displays disk information for user confirmation

2. **Disk Preparation**
   - Unmounts any existing volumes on the target disk
   - Erases disk with GPT partition table
   - Formats as FAT32 (MS-DOS) for UEFI compatibility

3. **ISO Mounting**
   - Checks if ISO is already mounted (to avoid errors)
   - Mounts ISO if not already mounted
   - Detects mount point automatically

4. **File Copying**
   - **Small install.wim (≤4GB)**: Copies all ISO contents directly
   - **Large install.wim (>4GB)**: 
     - Copies all files except `install.wim`
     - Splits `install.wim` into multiple `.swm` files
     - Windows installer automatically recognizes split files

5. **Cleanup**
   - Flushes disk write cache
   - Unmounts ISO
   - Ejects USB drive

### Why GPT + FAT32?

- **GPT (GUID Partition Table)**: Required for UEFI boot on modern systems
- **FAT32**: Only filesystem that works for UEFI boot across all systems
- **4GB Limitation**: FAT32 has a 4GB file size limit, which is why large `install.wim` files must be split

## Safety Features

The script includes multiple safety checks:

1. **Removable Drive Check**: Ensures target is a USB drive (checks protocol, location, removable flag)
2. **Boot Disk Protection**: Prevents selection of your Mac's boot disk
3. **Internal Disk Protection**: Rejects internal SATA/PCI drives
4. **Explicit Confirmation**: Requires typing "ERASE" to proceed
5. **ISO Validation**: Verifies ISO file signature before processing

## Troubleshooting

### "Resource temporarily unavailable" when mounting ISO

**Cause**: ISO is already mounted from a previous attempt

**Solution**: The script now automatically detects already-mounted ISOs. If you still encounter this:
```bash
# Check mounted ISOs
hdiutil info | grep -A 5 "image-path"

# Unmount if needed
hdiutil detach /Volumes/MOUNTED_ISO_NAME
```

### "wimlib-imagex: No such file or directory"

**Cause**: wimlib is not installed or not in PATH

**Solution**: 
```bash
# Install wimlib
brew install wimlib

# Verify installation
which wimlib-imagex
```

### USB drive not recognized by Windows PC

**Cause**: BIOS/UEFI settings on target PC

**Solution**:
- Ensure target PC is set to UEFI boot mode (not Legacy/CSM)
- Check boot order in BIOS/UEFI settings
- Some older systems may not support UEFI boot

### "Disk does not appear to be a removable USB drive"

**Cause**: Safety check preventing accidental erasure

**Solution**: 
- Ensure you're using an external USB drive
- Check disk information with: `diskutil info /dev/diskX`
- If it's truly a USB drive but detected as internal, you may need to override (not recommended)

## Technical Details

### File Structure on USB

```
/Volumes/WIN11/
├── autorun.inf
├── boot/
├── bootmgr
├── bootmgr.efi
├── efi/
├── sources/
│   ├── boot.wim
│   ├── install.swm      # (Split file 1 if >4GB)
│   ├── install2.swm     # (Split file 2 if >4GB)
│   ├── install3.swm     # (Split file 3 if >4GB)
│   └── ...
└── setup.exe
```

### Partition Scheme

```
/dev/diskX
├── EFI System Partition (200MB, FAT32)
└── Main Partition (Remaining space, FAT32, labeled as USB_NAME)
```

### Split File Details

When `install.wim` exceeds 4GB:
- Split into chunks (default: 3800MB each)
- Named sequentially: `install.swm`, `install2.swm`, `install3.swm`, etc.
- Windows Setup automatically recognizes and uses split archives
- Original `install.wim` is not copied to USB

## Compatibility

### Supported Windows Versions
- Windows 11 (all editions)
- Windows 10 (all editions)
- Windows Server 2016/2019/2022

### Supported macOS Versions
- Tested on macOS 10.13+ (High Sierra and later)
- Works on both Intel and Apple Silicon Macs

### Target PC Requirements
- UEFI firmware (most PCs from 2012+)
- USB boot support
- UEFI mode enabled (not Legacy/CSM)

## License

This script is provided as-is for personal and educational use.

## Credits

- Uses `wimlib` for WIM file manipulation (https://wimlib.net/)
- Inspired by various Windows USB creation tools for macOS

## Contributing

Feel free to submit issues or pull requests for improvements!

---

**Note**: This script is for creating Windows installation media only. You still need a valid Windows license to install and activate Windows.
