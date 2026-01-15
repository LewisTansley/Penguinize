# NTFS to Linux Filesystem Converter

A beautiful TUI-based bash script for converting NTFS partitions to various Linux filesystems (ext4, btrfs, xfs, f2fs, reiserfs, jfs) while preserving all data through an iterative shrinking and file migration process.

## Features

- 🎨 **Beautiful TUI Interface** - Modern terminal interface with box-drawing characters, colors, and smooth animations
- 🔄 **Iterative Conversion** - Safely converts partitions by iteratively shrinking NTFS and migrating files
- 💾 **Resume Capability** - Can resume from any point if interrupted
- 🎯 **Multiple Filesystems** - Supports ext4, btrfs, xfs, f2fs, reiserfs, and jfs
- 🔍 **Existing Partition Detection** - Detects and offers to use existing target filesystem partitions
- 🛡️ **Safety Features** - Dry-run mode, state tracking, and comprehensive error handling
- 📦 **Auto Dependency Management** - Automatically installs required packages via pacman

## Requirements

- Arch Linux (or compatible distribution with pacman)
- Root/sudo access
- Terminal with ANSI color support (recommended)
- Minimum terminal size: 80x24

## Installation

1. Clone or download this repository:
   ```bash
   git clone <repository-url>
   cd ConvertCLI
   ```

2. Make the script executable:
   ```bash
   chmod +x convert_ntfs_to_linux_fs.sh
   ```

3. Run with sudo:
   ```bash
   sudo ./convert_ntfs_to_linux_fs.sh
   ```

## Usage

### Basic Usage

```bash
sudo ./convert_ntfs_to_linux_fs.sh
```

### Dry Run Mode

Test the conversion without making changes:

```bash
sudo ./convert_ntfs_to_linux_fs.sh --dry-run
```

### Help

```bash
./convert_ntfs_to_linux_fs.sh --help
```

## How It Works

The script uses an iterative process to safely convert NTFS partitions:

1. **Detection**: Scans for NTFS partitions on selected disk
2. **Selection**: Interactive menu to select target filesystem type
3. **Analysis**: Calculates used space on NTFS partition
4. **Iterative Process**:
   - Shrinks NTFS partition to used space + safety buffer
   - Creates/expands target filesystem partition in freed space
   - Migrates files from NTFS to target filesystem
   - Repeats until NTFS is empty
5. **Finalization**: Deletes NTFS partition and expands target to fill disk

## Supported Filesystems

| Filesystem | Package | Features |
|------------|---------|----------|
| **ext4** | `e2fsprogs` | Standard Linux filesystem, stable and widely supported |
| **btrfs** | `btrfs-progs` | Modern filesystem with snapshots, compression, and checksums |
| **xfs** | `xfsprogs` | High-performance filesystem, excellent for large files |
| **f2fs** | `f2fs-tools` | Flash-optimized filesystem, best for SSDs |
| **reiserfs** | `reiserfsprogs` | Legacy filesystem (limited modern support) |
| **jfs** | `jfsutils` | Journaling filesystem (limited resize capabilities) |

## State Management

The script automatically saves state after each major operation to:
```
~/.ntfs_to_linux_fs/state_<device>.conf
```

If the script is interrupted, you can resume by running it again - it will detect the saved state and offer to continue.

## Safety Features

- **Dry-run mode**: Preview changes without modifying disk
- **State tracking**: Automatic save/restore of conversion progress
- **Error handling**: Graceful error recovery with clear messages
- **Verification**: Checks partition integrity before operations
- **Signal handling**: Saves state on Ctrl+C or termination

## Keyboard Navigation

- **↑/↓**: Navigate menu options
- **Enter**: Select option
- **ESC**: Cancel/exit
- **q**: Quit (in some menus)

## Troubleshooting

### Script fails with "No disks found"
- Ensure you have block devices available
- Check that `lsblk` command works
- Verify you're running as root

### Package installation fails
- Ensure pacman is available and configured
- Check internet connection
- Verify Arch Linux repositories are set up

### Conversion fails mid-process
- Check state file in `~/.ntfs_to_linux_fs/`
- Run script again to resume
- Verify disk has sufficient free space
- Check filesystem integrity with appropriate tools

### Terminal display issues
- Ensure terminal supports ANSI colors
- Try increasing terminal size
- Check `$TERM` environment variable
- Script will fallback to ASCII-only mode if needed

## Limitations

- **NTFS only**: Only converts from NTFS (not other Windows filesystems)
- **Single partition**: Converts one NTFS partition at a time
- **Arch Linux**: Designed for Arch Linux with pacman (may work on other distros with modifications)
- **Resize requirements**: Some filesystems (btrfs, xfs) require mount points for resize operations

## Filesystem-Specific Notes

### ext4
- Standard choice for most use cases
- Excellent compatibility and performance
- Device-based resize (no mount required)

### btrfs
- Requires mount point for resize operations
- Supports online resize
- Advanced features like snapshots and compression

### xfs
- Requires mount point for resize operations
- Can only grow, not shrink
- Excellent for large files and high-performance workloads

### f2fs
- Optimized for flash storage
- Device-based resize
- Best performance on SSDs

## Contributing

Contributions are welcome! Please ensure:
- Code follows bash best practices
- TUI elements are compatible with various terminals
- Error handling is comprehensive
- Documentation is updated

## Author

L. Tansley

## License

GPL v3 - see LICENSE file for details

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

## Disclaimer

**WARNING**: This script performs destructive operations on disk partitions. Always:
- Backup important data before use
- Test with dry-run mode first
- Use on non-critical systems initially
- Ensure you understand the conversion process

The author is not responsible for data loss. Use at your own risk.

## Version

Current version: 1.0.0

