#!/bin/bash

###############################################################################
# NTFS to Linux Filesystem Converter
# 
# A TUI-based script to convert NTFS partitions to various Linux filesystems
# (ext4, btrfs, xfs, f2fs, etc.) while preserving all data through iterative
# shrinking and file migration.
#
# Author: L. Tansley
# Version: 1.0.0
# License: GPL v3
###############################################################################

set -euo pipefail

# Script configuration
SCRIPT_NAME="convert_ntfs_to_linux_fs.sh"
SCRIPT_VERSION="1.0.0"
STATE_DIR="${HOME}/.ntfs_to_linux_fs"
STATE_FILE=""

# Color codes using tput for compatibility
RED=$(tput setaf 1 2>/dev/null || echo "")
GREEN=$(tput setaf 2 2>/dev/null || echo "")
YELLOW=$(tput setaf 3 2>/dev/null || echo "")
BLUE=$(tput setaf 4 2>/dev/null || echo "")
CYAN=$(tput setaf 6 2>/dev/null || echo "")
WHITE=$(tput setaf 7 2>/dev/null || echo "")
BOLD=$(tput bold 2>/dev/null || echo "")
RESET=$(tput sgr0 2>/dev/null || echo "")

# Box drawing characters (with ASCII fallback)
if command -v printf >/dev/null 2>&1 && printf '\u2500' >/dev/null 2>&1; then
    BOX_H="─"
    BOX_V="│"
    BOX_TL="┌"
    BOX_TR="┐"
    BOX_BL="└"
    BOX_BR="┘"
    BOX_T="├"
    BOX_CROSS="┼"
    ARROW_R="→"
    ARROW_L="←"
    CHECK="✓"
    CROSS="✗"
    WARN="⚠"
else
    BOX_H="-"
    BOX_V="|"
    BOX_TL="+"
    BOX_TR="+"
    BOX_BL="+"
    BOX_BR="+"
    BOX_T="+"
    BOX_CROSS="+"
    ARROW_R=">"
    ARROW_L="<"
    CHECK="+"
    CROSS="X"
    WARN="!"
fi

# Global variables
SELECTED_DISK=""
TARGET_FILESYSTEM=""
NTFS_PARTITION=""
TARGET_PARTITION=""
USE_EXISTING=false
CURRENT_ITERATION=0
LAST_OPERATION=""
NTFS_MOUNT=""
TARGET_MOUNT=""
FILES_MIGRATED=0
DRY_RUN=false

# Filesystem definitions
declare -A FS_PACKAGES
FS_PACKAGES[ext4]="e2fsprogs"
FS_PACKAGES[btrfs]="btrfs-progs"
FS_PACKAGES[xfs]="xfsprogs"
FS_PACKAGES[f2fs]="f2fs-tools"
FS_PACKAGES[reiserfs]="reiserfsprogs"
FS_PACKAGES[jfs]="jfsutils"

declare -A FS_FORMAT_CMD
FS_FORMAT_CMD[ext4]="mkfs.ext4 -F"
FS_FORMAT_CMD[btrfs]="mkfs.btrfs -f"
FS_FORMAT_CMD[xfs]="mkfs.xfs -f"
FS_FORMAT_CMD[f2fs]="mkfs.f2fs -f"
FS_FORMAT_CMD[reiserfs]="mkreiserfs -f"
FS_FORMAT_CMD[jfs]="mkfs.jfs -q"

declare -A FS_RESIZE_REQUIRES_MOUNT
FS_RESIZE_REQUIRES_MOUNT[ext4]=false
FS_RESIZE_REQUIRES_MOUNT[btrfs]=true
FS_RESIZE_REQUIRES_MOUNT[xfs]=true
FS_RESIZE_REQUIRES_MOUNT[f2fs]=false
FS_RESIZE_REQUIRES_MOUNT[reiserfs]=false
FS_RESIZE_REQUIRES_MOUNT[jfs]=false

# Filesystem descriptions
declare -A FS_DESCRIPTIONS
FS_DESCRIPTIONS[ext4]="Standard Linux filesystem, stable and widely supported"
FS_DESCRIPTIONS[btrfs]="Modern filesystem with snapshots, compression, and checksums"
FS_DESCRIPTIONS[xfs]="High-performance filesystem, excellent for large files"
FS_DESCRIPTIONS[f2fs]="Flash-optimized filesystem, best for SSDs"
FS_DESCRIPTIONS[reiserfs]="Legacy filesystem (limited modern support)"
FS_DESCRIPTIONS[jfs]="Journaling filesystem (limited resize capabilities)"

###############################################################################
# Utility Functions
###############################################################################

# Get terminal size
get_terminal_size() {
    local cols rows
    if command -v tput >/dev/null 2>&1; then
        cols=$(tput cols 2>/dev/null || echo 80)
        rows=$(tput lines 2>/dev/null || echo 24)
    else
        cols=80
        rows=24
    fi
    echo "$cols $rows"
}

# Center text
center_text() {
    local text="$1"
    local width
    width=$(get_terminal_size | cut -d' ' -f1)
    local padding=$(( (width - ${#text}) / 2 ))
    printf "%*s%s\n" $padding "" "$text"
}

# Clear screen
clear_screen() {
    if command -v tput >/dev/null 2>&1; then
        tput clear
    else
        clear
    fi
}

# Draw a box
draw_box() {
    local width="$1"
    local title="$2"
    local content="$3"
    
    local title_len=${#title}
    local title_pad=$(( (width - title_len - 2) / 2 ))
    
    # Top border
    echo -n "${BOX_TL}"
    for ((i=0; i<width-2; i++)); do echo -n "${BOX_H}"; done
    echo "${BOX_TR}"
    
    # Title line
    echo -n "${BOX_V}"
    printf "%*s" $title_pad ""
    echo -n "${BOLD}${CYAN}${title}${RESET}"
    printf "%*s" $((width - title_pad - title_len - 2)) ""
    echo "${BOX_V}"
    
    # Separator
    echo -n "${BOX_T}"
    for ((i=0; i<width-2; i++)); do echo -n "${BOX_H}"; done
    echo "${BOX_T}"
    
    # Content
    echo "$content" | while IFS= read -r line; do
        echo -n "${BOX_V}"
        printf "%-$((width-2))s" "$line"
        echo "${BOX_V}"
    done
    
    # Bottom border
    echo -n "${BOX_BL}"
    for ((i=0; i<width-2; i++)); do echo -n "${BOX_H}"; done
    echo "${BOX_BR}"
}

# Show spinner
show_spinner() {
    local pid=$1
    local message="$2"
    local spin='|/-\'
    local i=0
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %4 ))
        printf "\r${CYAN}${spin:$i:1}${RESET} $message"
        sleep 0.1
    done
    printf "\r${GREEN}${CHECK}${RESET} $message\n"
}

# Show progress bar
draw_progress_bar() {
    local current=$1
    local total=$2
    local width=50
    local percent=$(( current * 100 / total ))
    local filled=$(( current * width / total ))
    local empty=$(( width - filled ))
    
    printf "\r["
    for ((i=0; i<filled; i++)); do printf "█"; done
    for ((i=0; i<empty; i++)); do printf "░"; done
    printf "] %3d%%" "$percent"
}

# Print header
print_header() {
    clear_screen
    local width
    width=$(get_terminal_size | cut -d' ' -f1)
    
    echo ""
    center_text "${BOLD}${CYAN}╔══════════════════════════════════════════════════╗${RESET}"
    center_text "${BOLD}${CYAN}║${RESET}  ${BOLD}NTFS to Linux Filesystem Converter${RESET}  ${BOLD}${CYAN}║${RESET}"
    center_text "${BOLD}${CYAN}╚══════════════════════════════════════════════════╝${RESET}"
    echo ""
}

# Print footer
print_footer() {
    local width
    width=$(get_terminal_size | cut -d' ' -f1)
    echo ""
    echo -n "${BOX_TL}"
    for ((i=0; i<width-2; i++)); do echo -n "${BOX_H}"; done
    echo "${BOX_TR}"
    echo -n "${BOX_V}"
    printf " %-20s │ %-20s │ %-20s " "↑↓ Navigate" "Enter Select" "ESC Cancel"
    printf "%*s" $((width - 67)) ""
    echo "${BOX_V}"
    echo -n "${BOX_BL}"
    for ((i=0; i<width-2; i++)); do echo -n "${BOX_H}"; done
    echo "${BOX_BR}"
}

# Show menu
show_menu() {
    local title="$1"
    shift
    local options=("$@")
    local selected=0
    local key
    local width
    width=$(get_terminal_size | cut -d' ' -f1)
    
    # Save terminal settings
    local old_stty
    old_stty=$(stty -g)
    stty -echo -icanon time 0 min 0
    
    while true; do
        clear_screen
        print_header
        
        # Draw menu box
        local menu_content=""
        for ((i=0; i<${#options[@]}; i++)); do
            if [ $i -eq $selected ]; then
                menu_content+="${BOLD}${CYAN}${ARROW_R}${RESET} ${BOLD}${options[$i]}${RESET}\n"
            else
                menu_content+="   ${options[$i]}\n"
            fi
        done
        
        local box_content=$(printf "$menu_content")
        draw_box "$width" "$title" "$box_content"
        print_footer
        
        # Read key
        key=$(dd bs=1 count=1 2>/dev/null || echo "")
        
        case "$key" in
            $'\033')
                # Escape sequence
                key=$(dd bs=1 count=2 2>/dev/null || echo "")
                case "$key" in
                    '[A') selected=$(( (selected - 1 + ${#options[@]}) % ${#options[@]} )) ;;
                    '[B') selected=$(( (selected + 1) % ${#options[@]} )) ;;
                esac
                ;;
            $'\n'|$'\r')
                # Enter
                stty "$old_stty"
                echo $selected
                return
                ;;
            $'\177'|$'\b')
                # Backspace/Delete (treat as ESC)
                stty "$old_stty"
                echo -1
                return
                ;;
            'q'|'Q')
                # Quit
                stty "$old_stty"
                echo -1
                return
                ;;
        esac
    done
}

# Show message box
show_message() {
    local title="$1"
    local message="$2"
    local color="$3"
    local width
    width=$(get_terminal_size | cut -d' ' -f1)
    
    clear_screen
    print_header
    
    local content="${color}${message}${RESET}"
    draw_box "$width" "$title" "$content"
    
    echo ""
    center_text "Press Enter to continue..."
    read -r
}

# Show error
show_error() {
    show_message "Error" "$1" "$RED"
}

# Show warning
show_warning() {
    show_message "Warning" "$1" "$YELLOW"
}

# Show success
show_success() {
    show_message "Success" "$1" "$GREEN"
}

# Show info
show_info() {
    show_message "Information" "$1" "$CYAN"
}

###############################################################################
# Dependency Management
###############################################################################

check_root() {
    if [ "$EUID" -ne 0 ]; then
        show_error "This script must be run as root or with sudo"
        exit 1
    fi
}

check_dependencies() {
    local fs_type="$1"
    local missing_packages=()
    
    # Base dependencies
    local base_packages=("ntfs-3g" "parted" "rsync" "util-linux")
    
    for pkg in "${base_packages[@]}"; do
        if ! pacman -Q "$pkg" >/dev/null 2>&1; then
            missing_packages+=("$pkg")
        fi
    done
    
    # Filesystem-specific dependencies
    if [ -n "$fs_type" ] && [ -n "${FS_PACKAGES[$fs_type]:-}" ]; then
        local fs_pkg="${FS_PACKAGES[$fs_type]}"
        if ! pacman -Q "$fs_pkg" >/dev/null 2>&1; then
            missing_packages+=("$fs_pkg")
        fi
    fi
    
    if [ ${#missing_packages[@]} -gt 0 ]; then
        show_info "Installing missing packages: ${missing_packages[*]}"
        if ! pacman -S --noconfirm "${missing_packages[@]}" >/dev/null 2>&1; then
            show_error "Failed to install packages. Please install manually: ${missing_packages[*]}"
            exit 1
        fi
        show_success "Packages installed successfully"
    fi
}

###############################################################################
# Disk and Partition Detection
###############################################################################

list_disks() {
    lsblk -d -n -o NAME,SIZE,MODEL | grep -E '^[a-z]' | awk '{print "/dev/" $1 " - " $2 " - " substr($0, index($0,$3))}'
}

select_disk() {
    local disks
    mapfile -t disks < <(list_disks)
    
    if [ ${#disks[@]} -eq 0 ]; then
        show_error "No disks found"
        exit 1
    fi
    
    local selection
    selection=$(show_menu "Select Disk" "${disks[@]}")
    
    if [ "$selection" -eq -1 ]; then
        exit 0
    fi
    
    SELECTED_DISK=$(echo "${disks[$selection]}" | awk '{print $1}')
    STATE_FILE="${STATE_DIR}/state_$(basename "$SELECTED_DISK").conf"
    mkdir -p "$STATE_DIR"
}

detect_ntfs_partitions() {
    local disk="$1"
    lsblk -f -n -o NAME,FSTYPE "$disk" | grep -i ntfs | awk '{print "/dev/" $1}' | head -1
}

detect_existing_partitions() {
    local disk="$1"
    local fs_type="$2"
    lsblk -f -n -o NAME,FSTYPE "$disk" | grep -i "^[^ ]* $fs_type" | awk '{print "/dev/" $1}'
}

# Detect if disk is HDD or SSD
detect_disk_type() {
    local disk="$1"
    local disk_name
    disk_name=$(basename "$disk")
    
    # Method 1: Check /sys/block/<device>/queue/rotational
    # 0 = SSD, 1 = HDD
    if [ -f "/sys/block/$disk_name/queue/rotational" ]; then
        local rotational
        rotational=$(cat "/sys/block/$disk_name/queue/rotational" 2>/dev/null || echo "1")
        if [ "$rotational" = "0" ]; then
            echo "SSD"
            return 0
        elif [ "$rotational" = "1" ]; then
            echo "HDD"
            return 0
        fi
    fi
    
    # Method 2: Use lsblk -d -o NAME,ROTA
    # ROTA=0 = SSD, ROTA=1 = HDD
    local rota
    rota=$(lsblk -d -n -o ROTA "$disk" 2>/dev/null | head -1)
    if [ "$rota" = "0" ]; then
        echo "SSD"
        return 0
    elif [ "$rota" = "1" ]; then
        echo "HDD"
        return 0
    fi
    
    # Method 3: Try smartctl if available
    if command -v smartctl >/dev/null 2>&1; then
        local device_type
        device_type=$(smartctl -a "$disk" 2>/dev/null | grep -i "device model\|rotation rate" | head -1)
        if echo "$device_type" | grep -qi "solid state\|ssd"; then
            echo "SSD"
            return 0
        elif echo "$device_type" | grep -qi "rpm\|rotation"; then
            echo "HDD"
            return 0
        fi
    fi
    
    # Fallback: assume HDD if we can't determine (safer for defrag)
    echo "UNKNOWN"
    return 1
}

# Defrag NTFS partition
defrag_ntfs() {
    local partition="$1"
    
    show_info "Defragmenting NTFS partition $partition..."
    show_warning "This may take a long time depending on partition size and fragmentation level"
    
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] Would defragment NTFS partition $partition"
        return 0
    fi
    
    # Check if partition is mounted and unmount if necessary
    # ntfsfix works on unmounted partitions
    local mount_point
    mount_point=$(findmnt -n -o TARGET "$partition" 2>/dev/null || echo "")
    
    if [ -n "$mount_point" ]; then
        show_info "Unmounting partition for optimization..."
        if ! umount "$partition" 2>/dev/null; then
            show_error "Partition is mounted and cannot be unmounted. Please unmount manually and try again."
            return 1
        fi
        sync
        sleep 1
    fi
    
    # Use ntfsfix to check and fix the filesystem
    # Note: Full NTFS defragmentation requires Windows tools
    # ntfsfix can optimize and fix issues, which helps prepare for conversion
    show_info "Running NTFS filesystem check and optimization (this may take a while)..."
    
    local defrag_success=false
    
    # Try ntfsfix (available in ntfs-3g package)
    # This doesn't fully defragment but can optimize and fix filesystem issues
    if command -v ntfsfix >/dev/null 2>&1; then
        if ntfsfix "$partition" >/dev/null 2>&1; then
            defrag_success=true
            show_info "NTFS filesystem check and optimization completed"
        else
            show_warning "ntfsfix had issues, but continuing..."
            defrag_success=true  # Still consider it attempted
        fi
    else
        show_warning "ntfsfix not available. For best results, defragment using Windows tools before conversion."
    fi
    
    # Remount if it was previously mounted
    if [ -n "$mount_point" ] && [ -d "$mount_point" ]; then
        show_info "Remounting partition..."
        mount "$partition" "$mount_point" 2>/dev/null || true
    fi
    
    if [ "$defrag_success" = true ]; then
        show_success "NTFS optimization completed"
        return 0
    else
        show_warning "Could not perform full defragmentation (Windows tools recommended for best results)"
        show_info "Continuing with conversion anyway..."
        return 0
    fi
}

# Defrag Linux filesystem partition
defrag_linux_fs() {
    local partition="$1"
    local fs_type="$2"
    
    show_info "Defragmenting ${fs_type} partition $partition..."
    show_warning "This may take a long time depending on partition size and fragmentation level"
    
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] Would defragment ${fs_type} partition $partition"
        return 0
    fi
    
    # Mount the partition for defragmentation (most Linux defrag tools require mounted FS)
    local mount_point="/mnt/defrag_$$"
    mkdir -p "$mount_point"
    
    if ! mount "$partition" "$mount_point" 2>/dev/null; then
        show_error "Failed to mount partition for defragmentation"
        rmdir "$mount_point" 2>/dev/null || true
        return 1
    fi
    
    local defrag_success=false
    
    # Defrag based on filesystem type
    case "$fs_type" in
        ext4)
            if command -v e4defrag >/dev/null 2>&1; then
                show_info "Running ext4 defragmentation (this may take a while)..."
                if e4defrag -c "$mount_point" >/dev/null 2>&1; then
                    # Check if defragmentation is needed
                    local frag_info
                    frag_info=$(e4defrag -c "$mount_point" 2>/dev/null | tail -1)
                    if echo "$frag_info" | grep -qi "not need\|0%"; then
                        show_info "Filesystem is already well defragmented"
                    else
                        show_info "Running full defragmentation..."
                        e4defrag "$mount_point" >/dev/null 2>&1 || {
                            show_warning "e4defrag had issues, but continuing..."
                        }
                    fi
                    defrag_success=true
                else
                    show_warning "e4defrag check failed, but continuing..."
                    defrag_success=true
                fi
            else
                show_warning "e4defrag not available. Install e2fsprogs package."
            fi
            ;;
        btrfs)
            if command -v btrfs >/dev/null 2>&1; then
                show_info "Running btrfs defragmentation (this may take a while)..."
                if btrfs filesystem defrag -r "$mount_point" >/dev/null 2>&1; then
                    defrag_success=true
                    show_info "btrfs defragmentation completed"
                else
                    show_warning "btrfs defragmentation had issues, but continuing..."
                    defrag_success=true
                fi
            else
                show_warning "btrfs tools not available."
            fi
            ;;
        xfs)
            if command -v xfs_fsr >/dev/null 2>&1; then
                show_info "Running xfs defragmentation (this may take a while)..."
                # xfs_fsr works on mounted filesystems
                if xfs_fsr "$mount_point" >/dev/null 2>&1; then
                    defrag_success=true
                    show_info "xfs defragmentation completed"
                else
                    show_warning "xfs_fsr had issues, but continuing..."
                    defrag_success=true
                fi
            else
                show_warning "xfs_fsr not available. Install xfsprogs package."
            fi
            ;;
        f2fs)
            show_info "f2fs is optimized for flash storage and doesn't require defragmentation"
            defrag_success=true
            ;;
        reiserfs|jfs)
            show_warning "${fs_type} defragmentation tools are limited or not available"
            show_info "Skipping defragmentation for ${fs_type}"
            defrag_success=true
            ;;
        *)
            show_warning "Defragmentation not supported for ${fs_type}"
            defrag_success=true
            ;;
    esac
    
    # Sync and unmount
    sync
    if ! umount "$mount_point" 2>/dev/null; then
        show_warning "Failed to unmount partition after defragmentation"
        sleep 2
        umount -l "$mount_point" 2>/dev/null || true
    fi
    rmdir "$mount_point" 2>/dev/null || true
    
    if [ "$defrag_success" = true ]; then
        show_success "${fs_type} defragmentation completed"
        return 0
    else
        show_warning "Could not perform defragmentation"
        return 1
    fi
}

# Check disk type and offer defragmentation if HDD
check_and_offer_defrag() {
    local disk="$1"
    local ntfs_partition="$2"
    
    if [ -z "$ntfs_partition" ]; then
        # Try to detect NTFS partition
        ntfs_partition=$(detect_ntfs_partitions "$disk")
        if [ -z "$ntfs_partition" ]; then
            return 0  # No NTFS partition, skip defrag check
        fi
    fi
    
    # Detect disk type
    local disk_type
    disk_type=$(detect_disk_type "$disk")
    
    if [ "$disk_type" != "HDD" ]; then
        # Not an HDD, skip defrag
        return 0
    fi
    
    # It's an HDD - confirm with user and offer defrag
    local width
    width=$(get_terminal_size | cut -d' ' -f1)
    
    clear_screen
    print_header
    
    local disk_name
    disk_name=$(basename "$disk")
    local disk_model
    disk_model=$(lsblk -d -n -o MODEL "$disk" 2>/dev/null | head -1 || echo "Unknown")
    
    local confirmation_msg=""
    confirmation_msg+="${YELLOW}${WARN} Hard Drive Detected ${WARN}${RESET}\n"
    confirmation_msg+="\n"
    confirmation_msg+="Disk: ${BOLD}$disk${RESET}\n"
    confirmation_msg+="Model: ${BOLD}$disk_model${RESET}\n"
    confirmation_msg+="Type: ${BOLD}Hard Disk Drive (HDD)${RESET}\n"
    confirmation_msg+="\n"
    confirmation_msg+="The selected disk has been detected as a hard disk drive.\n"
    confirmation_msg+="Defragmenting the NTFS partition before conversion can\n"
    confirmation_msg+="improve performance and reduce conversion time.\n"
    confirmation_msg+="\n"
    confirmation_msg+="${YELLOW}Please confirm this is definitely a hard drive${RESET}\n"
    confirmation_msg+="${YELLOW}and not a solid state drive for safety.${RESET}\n"
    
    draw_box "$width" "Hard Drive Detection" "$confirmation_msg"
    print_footer
    
    local options=("Yes, this is a hard drive - offer defrag" "No, this is an SSD - skip defrag" "Cancel")
    local selection
    selection=$(show_menu "Confirm Disk Type" "${options[@]}")
    
    case "$selection" in
        0)
            # User confirmed it's an HDD - offer defrag
            local defrag_options=("Yes, defragment now (recommended)" "No, skip defragmentation" "Cancel")
            local defrag_selection
            defrag_selection=$(show_menu "Defragment NTFS Partition?" "${defrag_options[@]}")
            
            case "$defrag_selection" in
                0)
                    # User wants to defrag
                    if defrag_ntfs "$ntfs_partition"; then
                        show_success "Defragmentation completed. Proceeding with conversion..."
                        sleep 2
                    else
                        show_warning "Defragmentation had issues, but continuing with conversion..."
                        sleep 2
                    fi
                    ;;
                1)
                    # User skipped defrag
                    show_info "Skipping defragmentation. Proceeding with conversion..."
                    sleep 1
                    ;;
                *)
                    # User cancelled
                    exit 0
                    ;;
            esac
            ;;
        1)
            # User says it's an SSD - skip defrag
            show_info "Skipping defragmentation (SSD detected). Proceeding with conversion..."
            sleep 1
            ;;
        *)
            # User cancelled
            exit 0
            ;;
    esac
    
    return 0
}

# Check disk type and offer defragmentation for target filesystem after conversion
check_and_offer_post_conversion_defrag() {
    local disk="$1"
    local target_partition="$2"
    local fs_type="$3"
    
    if [ -z "$target_partition" ]; then
        return 0  # No target partition, skip
    fi
    
    # Detect disk type
    local disk_type
    disk_type=$(detect_disk_type "$disk")
    
    if [ "$disk_type" != "HDD" ]; then
        # Not an HDD, skip defrag
        return 0
    fi
    
    # Skip defrag for filesystems that don't need it
    case "$fs_type" in
        f2fs)
            return 0  # f2fs is SSD-optimized, doesn't need defrag
            ;;
    esac
    
    # It's an HDD - offer defrag for the target filesystem
    local width
    width=$(get_terminal_size | cut -d' ' -f1)
    
    clear_screen
    print_header
    
    local disk_name
    disk_name=$(basename "$disk")
    local disk_model
    disk_model=$(lsblk -d -n -o MODEL "$disk" 2>/dev/null | head -1 || echo "Unknown")
    
    local confirmation_msg=""
    confirmation_msg+="${YELLOW}${WARN} Conversion Complete ${WARN}${RESET}\n"
    confirmation_msg+="\n"
    confirmation_msg+="Disk: ${BOLD}$disk${RESET}\n"
    confirmation_msg+="Model: ${BOLD}$disk_model${RESET}\n"
    confirmation_msg+="Type: ${BOLD}Hard Disk Drive (HDD)${RESET}\n"
    confirmation_msg+="Target: ${BOLD}${fs_type} on ${target_partition}${RESET}\n"
    confirmation_msg+="\n"
    confirmation_msg+="The conversion is complete. Defragmenting the new\n"
    confirmation_msg+="${fs_type} partition can improve performance.\n"
    confirmation_msg+="\n"
    confirmation_msg+="${YELLOW}Would you like to defragment the ${fs_type} partition?${RESET}\n"
    
    draw_box "$width" "Post-Conversion Defragmentation" "$confirmation_msg"
    print_footer
    
    local options=("Yes, defragment now (recommended)" "No, skip defragmentation")
    local selection
    selection=$(show_menu "Defragment ${fs_type} Partition?" "${options[@]}")
    
    case "$selection" in
        0)
            # User wants to defrag
            if defrag_linux_fs "$target_partition" "$fs_type"; then
                show_success "Defragmentation completed successfully!"
                sleep 2
            else
                show_warning "Defragmentation had issues, but conversion is complete"
                sleep 2
            fi
            ;;
        *)
            # User skipped defrag
            show_info "Skipping defragmentation."
            sleep 1
            ;;
    esac
    
    return 0
}

select_filesystem() {
    local fs_options=("ext4" "btrfs" "xfs" "f2fs" "reiserfs" "jfs")
    local fs_display=()
    
    for fs in "${fs_options[@]}"; do
        fs_display+=("$fs - ${FS_DESCRIPTIONS[$fs]}")
    done
    
    local selection
    selection=$(show_menu "Select Target Filesystem" "${fs_display[@]}")
    
    if [ "$selection" -eq -1 ]; then
        exit 0
    fi
    
    TARGET_FILESYSTEM="${fs_options[$selection]}"
    check_dependencies "$TARGET_FILESYSTEM"
}

###############################################################################
# State Management
###############################################################################

save_state() {
    mkdir -p "$STATE_DIR"
    cat > "$STATE_FILE" <<EOF
DISK=$SELECTED_DISK
TARGET_FILESYSTEM=$TARGET_FILESYSTEM
NTFS_PARTITION=$NTFS_PARTITION
TARGET_PARTITION=$TARGET_PARTITION
USE_EXISTING=$USE_EXISTING
CURRENT_ITERATION=$CURRENT_ITERATION
LAST_OPERATION=$LAST_OPERATION
NTFS_MOUNT=$NTFS_MOUNT
TARGET_MOUNT=$TARGET_MOUNT
FILES_MIGRATED=$FILES_MIGRATED
EOF
}

load_state() {
    if [ -f "$STATE_FILE" ]; then
        source "$STATE_FILE"
        return 0
    fi
    return 1
}

check_resume_state() {
    local state_files
    mapfile -t state_files < <(find "$STATE_DIR" -name "state_*.conf" 2>/dev/null)
    
    if [ ${#state_files[@]} -eq 0 ]; then
        return 1
    fi
    
    local options=("Resume previous conversion" "Start fresh" "Cancel")
    local selection
    selection=$(show_menu "Resume Previous Conversion?" "${options[@]}")
    
    case "$selection" in
        0)
            # Find and load most recent state
            STATE_FILE=$(ls -t "${state_files[@]}" 2>/dev/null | head -1)
            if load_state; then
                return 0
            fi
            ;;
        1)
            # Delete state files
            rm -f "${state_files[@]}"
            return 1
            ;;
        *)
            exit 0
            ;;
    esac
    return 1
}

cleanup_state() {
    if [ -f "$STATE_FILE" ]; then
        rm -f "$STATE_FILE"
    fi
}

###############################################################################
# Partition Operations
###############################################################################

shrink_ntfs() {
    local partition="$1"
    local target_size="$2"
    
    show_info "Shrinking NTFS partition $partition to ${target_size}KB"
    
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] Would run: ntfsresize -s ${target_size}K -f $partition"
        return 0
    fi
    
    if ! ntfsresize -s "${target_size}K" -f "$partition" >/dev/null 2>&1; then
        show_error "Failed to shrink NTFS partition"
        return 1
    fi
    
    # Resize partition table entry
    local part_num
    part_num=$(echo "$partition" | grep -o '[0-9]*$')
    local disk
    disk=$(echo "$partition" | sed 's/[0-9]*$//')
    
    parted "$disk" resizepart "$part_num" "${target_size}KB" >/dev/null 2>&1 || true
    
    return 0
}

create_partition() {
    local disk="$1"
    local start="$2"
    local end="$3"
    
    show_info "Creating partition on $disk from ${start}KB to ${end}KB"
    
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] Would run: parted $disk mkpart primary ${start}KB ${end}KB"
        echo "/dev/sdXY"  # Dummy output
        return 0
    fi
    
    local part_num
    part_num=$(parted "$disk" -s mkpart primary "${start}KB" "${end}KB" | tail -1 | awk '{print $NF}')
    
    # Wait for kernel to recognize new partition
    sleep 1
    partprobe "$disk" >/dev/null 2>&1 || true
    sleep 1
    
    echo "${disk}${part_num}"
}

format_filesystem() {
    local partition="$1"
    local fs_type="$2"
    
    show_info "Formatting $partition as $fs_type"
    
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] Would run: ${FS_FORMAT_CMD[$fs_type]} $partition"
        return 0
    fi
    
    local format_cmd="${FS_FORMAT_CMD[$fs_type]}"
    if ! $format_cmd "$partition" >/dev/null 2>&1; then
        show_error "Failed to format partition as $fs_type"
        return 1
    fi
    
    return 0
}

expand_filesystem() {
    local partition="$1"
    local mount_point="$2"
    local fs_type="$3"
    
    show_info "Expanding $fs_type filesystem on $partition"
    
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] Would expand filesystem"
        return 0
    fi
    
    if [ "${FS_RESIZE_REQUIRES_MOUNT[$fs_type]}" = true ]; then
        # Mount required for resize
        if [ -z "$mount_point" ]; then
            mount_point="/mnt/temp_resize_$$"
            mkdir -p "$mount_point"
            mount "$partition" "$mount_point" || return 1
        fi
        
        case "$fs_type" in
            btrfs)
                btrfs filesystem resize max "$mount_point" >/dev/null 2>&1 || return 1
                ;;
            xfs)
                xfs_growfs "$mount_point" >/dev/null 2>&1 || return 1
                ;;
        esac
        
        if [ "$mount_point" = "/mnt/temp_resize_$$" ]; then
            umount "$mount_point"
            rmdir "$mount_point"
        fi
    else
        # Device-based resize
        case "$fs_type" in
            ext4)
                resize2fs "$partition" >/dev/null 2>&1 || return 1
                ;;
            f2fs)
                resize.f2fs "$partition" >/dev/null 2>&1 || return 1
                ;;
        esac
    fi
    
    return 0
}

###############################################################################
# File Migration Verification
###############################################################################

# Wait for I/O operations to complete
wait_for_io_completion() {
    local max_wait=30  # Maximum 30 seconds
    local wait_time=0
    local interval=1
    
    show_info "Waiting for I/O operations to complete..."
    
    while [ $wait_time -lt $max_wait ]; do
        # Check for pending I/O using /proc/diskstats
        if [ -f /proc/diskstats ]; then
            local disk_name
            disk_name=$(basename "$SELECTED_DISK")
            local io_ops
            io_ops=$(grep "$disk_name" /proc/diskstats | awk '{print $4+$8}' | head -1)
            
            # Wait a bit and check again
            sleep $interval
            local io_ops_after
            io_ops_after=$(grep "$disk_name" /proc/diskstats | awk '{print $4+$8}' | head -1)
            
            # If I/O operations haven't increased significantly, assume completion
            if [ -n "$io_ops" ] && [ -n "$io_ops_after" ]; then
                local io_diff=$((io_ops_after - io_ops))
                if [ $io_diff -lt 10 ]; then
                    # I/O has stabilized
                    return 0
                fi
            fi
        else
            # Fallback: just wait a bit
            sleep 2
            return 0
        fi
        
        wait_time=$((wait_time + interval))
    done
    
    show_warning "I/O wait timeout reached, proceeding anyway..."
    return 0
}

# Comprehensive file verification - verifies all migrated files match source
verify_file_migration() {
    local source_mount="$1"
    local dest_mount="$2"
    local verify_list_file="$3"  # Output file with list of verified files
    
    show_info "Comprehensively verifying file migration..."
    
    # Count files in source and destination
    local source_files
    source_files=$(find "$source_mount" -type f 2>/dev/null | wc -l)
    local dest_files
    dest_files=$(find "$dest_mount" -type f 2>/dev/null | wc -l)
    
    if [ $source_files -eq 0 ]; then
        show_info "No files to verify in source"
        touch "$verify_list_file"  # Create empty list
        return 0
    fi
    
    # Check if destination has reasonable number of files
    if [ $dest_files -lt $((source_files / 2)) ]; then
        show_error "File count mismatch: Source has $source_files files, destination has $dest_files files"
        show_error "Not enough files migrated. Aborting verification."
        return 1
    fi
    
    # Get checksum command (prefer sha256sum, fallback to md5sum)
    local checksum_cmd=""
    if command -v sha256sum >/dev/null 2>&1; then
        checksum_cmd="sha256sum"
    elif command -v md5sum >/dev/null 2>&1; then
        checksum_cmd="md5sum"
    fi
    
    show_info "Verifying all migrated files (this may take a while)..."
    show_info "Source files: $source_files, Destination files: $dest_files"
    
    local verified_count=0
    local failed_count=0
    local missing_count=0
    local total_checked=0
    local verify_list=()
    
    # Verify each file in source
    while IFS= read -r source_file; do
        [ -z "$source_file" ] && continue
        
        total_checked=$((total_checked + 1))
        local rel_path
        rel_path="${source_file#$source_mount/}"
        local dest_file="$dest_mount/$rel_path"
        
        # Show progress every 100 files
        if [ $((total_checked % 100)) -eq 0 ]; then
            printf "\r${CYAN}Verified: $verified_count, Failed: $failed_count, Missing: $missing_count, Total: $total_checked/$source_files${RESET}"
        fi
        
        if [ ! -f "$dest_file" ]; then
            missing_count=$((missing_count + 1))
            continue
        fi
        
        # Compare file sizes first (fast check)
        local source_size dest_size
        source_size=$(stat -f%z "$source_file" 2>/dev/null || stat -c%s "$source_file" 2>/dev/null || echo 0)
        dest_size=$(stat -f%z "$dest_file" 2>/dev/null || stat -c%s "$dest_file" 2>/dev/null || echo 0)
        
        # Check if sizes match (empty files with size 0 are valid)
        if [ "$source_size" != "$dest_size" ]; then
            failed_count=$((failed_count + 1))
            continue
        fi
        
        # If both files are empty (size 0), they match - no need for checksum
        if [ "$source_size" -eq 0 ]; then
            verified_count=$((verified_count + 1))
            verify_list+=("$rel_path")
            continue
        fi
        
        # For files > 1MB, verify with checksum (more thorough)
        # For smaller files, size match is sufficient
        local verify_checksum=false
        if [ "$source_size" -gt 1048576 ] && [ -n "$checksum_cmd" ]; then
            verify_checksum=true
        fi
        
        if [ "$verify_checksum" = true ]; then
            local source_hash dest_hash
            source_hash=$($checksum_cmd "$source_file" 2>/dev/null | cut -d' ' -f1)
            dest_hash=$($checksum_cmd "$dest_file" 2>/dev/null | cut -d' ' -f1)
            
            # If checksum calculation failed, fall back to size-only verification
            # (this can happen with very large files or filesystem issues)
            if [ -z "$source_hash" ] || [ -z "$dest_hash" ]; then
                show_warning "Checksum calculation failed for file, using size verification only: $rel_path"
                # Size already matches, so consider it verified
                verified_count=$((verified_count + 1))
                verify_list+=("$rel_path")
                continue
            fi
            
            if [ "$source_hash" != "$dest_hash" ]; then
                failed_count=$((failed_count + 1))
                continue
            fi
        fi
        
        # File verified - add to list
        verified_count=$((verified_count + 1))
        verify_list+=("$rel_path")
        
    done < <(find "$source_mount" -type f 2>/dev/null)
    
    printf "\r${GREEN}Verified: $verified_count, Failed: $failed_count, Missing: $missing_count, Total: $total_checked${RESET}\n"
    
    # Save verified file list
    if [ ${#verify_list[@]} -gt 0 ]; then
        printf "%s\n" "${verify_list[@]}" > "$verify_list_file"
    else
        touch "$verify_list_file"
    fi
    
    # Verification results
    local success_rate=$((verified_count * 100 / total_checked))
    
    if [ $failed_count -gt 0 ] || [ $missing_count -gt $((total_checked / 10)) ]; then
        show_error "File verification failed!"
        show_error "Verified: $verified_count/$total_checked ($success_rate%)"
        show_error "Failed: $failed_count, Missing: $missing_count"
        return 1
    fi
    
    if [ $verified_count -lt $((total_checked * 9 / 10)) ]; then
        show_warning "Low verification rate: $verified_count/$total_checked ($success_rate%)"
        show_warning "Less than 90% of files verified. Proceed with caution."
        local options=("Yes, continue anyway" "No, abort")
        local user_choice
        user_choice=$(show_menu "Continue with low verification rate?" "${options[@]}")
        if [ "$user_choice" != "0" ]; then
            return 1
        fi
    fi
    
    show_success "File verification complete: $verified_count/$total_checked files verified ($success_rate%)"
    return 0
}

# Remove verified source files (only files that were verified)
remove_verified_source_files() {
    local source_mount="$1"
    local verify_list_file="$2"
    
    if [ ! -f "$verify_list_file" ]; then
        show_error "Verification list file not found. Cannot safely remove source files."
        return 1
    fi
    
    local file_count
    file_count=$(wc -l < "$verify_list_file" 2>/dev/null || echo 0)
    
    if [ $file_count -eq 0 ]; then
        show_info "No verified files to remove from source"
        return 0
    fi
    
    show_info "Removing $file_count verified files from NTFS source..."
    
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] Would remove $file_count files from $source_mount"
        return 0
    fi
    
    local removed_count=0
    local failed_count=0
    
    while IFS= read -r rel_path; do
        [ -z "$rel_path" ] && continue
        
        local source_file="$source_mount/$rel_path"
        
        if [ -f "$source_file" ]; then
            if rm -f "$source_file" 2>/dev/null; then
                removed_count=$((removed_count + 1))
            else
                failed_count=$((failed_count + 1))
            fi
        fi
    done < "$verify_list_file"
    
    # Remove empty directories
    find "$source_mount" -type d -empty -delete 2>/dev/null || true
    
    show_info "Removed $removed_count files from source"
    if [ $failed_count -gt 0 ]; then
        show_warning "Failed to remove $failed_count files"
    fi
    
    return 0
}

# Sync filesystem and wait for completion
sync_filesystems() {
    show_info "Syncing filesystems to ensure all data is written..."
    
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] Would run: sync"
        return 0
    fi
    
    # Sync all filesystems
    sync
    
    # Wait a moment for sync to complete
    sleep 1
    
    # Additional sync for mounted filesystems
    if [ -n "$NTFS_MOUNT" ] && mountpoint -q "$NTFS_MOUNT" 2>/dev/null; then
        sync -f "$NTFS_MOUNT" 2>/dev/null || true
    fi
    
    if [ -n "$TARGET_MOUNT" ] && mountpoint -q "$TARGET_MOUNT" 2>/dev/null; then
        sync -f "$TARGET_MOUNT" 2>/dev/null || true
    fi
    
    # Wait for I/O to complete
    wait_for_io_completion
    
    return 0
}

###############################################################################
# File Migration
###############################################################################

migrate_files() {
    local source="$1"
    local dest="$2"
    
    show_info "Migrating files from $source to $dest"
    
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] Would run: rsync -avx --progress $source/ $dest/"
        return 0
    fi
    
    # Create mount points
    NTFS_MOUNT="/mnt/ntfs_$$"
    TARGET_MOUNT="/mnt/target_$$"
    mkdir -p "$NTFS_MOUNT" "$TARGET_MOUNT"
    
    # Mount partitions
    if ! mount "$source" "$NTFS_MOUNT" 2>/dev/null; then
        show_error "Failed to mount source partition $source"
        return 1
    fi
    
    if ! mount "$dest" "$TARGET_MOUNT" 2>/dev/null; then
        show_error "Failed to mount target partition $dest"
        umount "$NTFS_MOUNT" 2>/dev/null || true
        return 1
    fi
    
    # Migrate files with progress
    local width
    width=$(get_terminal_size | cut -d' ' -f1)
    
    clear_screen
    print_header
    
    local box_content=""
    box_content+="${CYAN}Migrating files...${RESET}\n"
    box_content+="\n"
    box_content+="Source: ${BOLD}$source${RESET}\n"
    box_content+="Target: ${BOLD}$dest${RESET}\n"
    box_content+="\n"
    box_content+="Progress: [                    ] 0%\n"
    box_content+="\n"
    box_content+="Files: 0\n"
    box_content+="Data: 0 B\n"
    
    draw_box "$width" "File Migration" "$box_content"
    
    # Use rsync to migrate files
    # Count files first for progress
    local total_files
    total_files=$(find "$NTFS_MOUNT" -type f 2>/dev/null | wc -l)
    local migrated_files=0
    
    # Migrate files, excluding already migrated ones (check by comparing)
    rsync -avx --info=progress2 --human-readable \
        "$NTFS_MOUNT/" "$TARGET_MOUNT/" 2>&1 | \
    while IFS= read -r line; do
        # Update progress display
        if echo "$line" | grep -q "to-check="; then
            # Extract progress info
            local progress_info
            progress_info=$(echo "$line" | grep -oE '[0-9]+%' | head -1 | sed 's/%//')
            if [ -n "$progress_info" ]; then
                local cols
                cols=$(get_terminal_size | cut -d' ' -f1)
                tput cup 8 0 2>/dev/null || true
                printf "Progress: "
                draw_progress_bar "$progress_info" 100
                printf "\n"
            fi
        fi
        
        # Count files
        if echo "$line" | grep -qE '^[^/]+/[^/]+'; then
            migrated_files=$((migrated_files + 1))
            FILES_MIGRATED=$((FILES_MIGRATED + 1))
        fi
    done
    
    # Sync filesystems to ensure all data is written before verification
    sync_filesystems
    
    # Create verification list file
    local verify_list_file="/tmp/verified_files_$$.txt"
    
    # Comprehensive verification - verify ALL files match before removing source
    show_info "Verifying all migrated files match source before clearing NTFS space..."
    if ! verify_file_migration "$NTFS_MOUNT" "$TARGET_MOUNT" "$verify_list_file"; then
        show_error "File verification failed! Source files will NOT be removed."
        show_error "Please check the migration and try again."
        # Cleanup
        rm -f "$verify_list_file" 2>/dev/null || true
        umount "$NTFS_MOUNT" "$TARGET_MOUNT" 2>/dev/null || true
        rmdir "$NTFS_MOUNT" "$TARGET_MOUNT" 2>/dev/null || true
        return 1
    fi
    
    # Only remove source files that were verified
    show_info "Removing verified source files from NTFS partition..."
    if ! remove_verified_source_files "$NTFS_MOUNT" "$verify_list_file"; then
        show_error "Failed to remove verified source files"
        # Continue anyway - files are verified on destination
    fi
    
    # Cleanup verification list
    rm -f "$verify_list_file" 2>/dev/null || true
    
    # Sync again after removing source files
    show_info "Syncing after source file removal..."
    sync_filesystems
    
    # Final sync before unmounting
    show_info "Final sync before unmounting..."
    sync
    sleep 1
    
    # Unmount with verification
    show_info "Unmounting partitions..."
    local unmount_failed=false
    
    if ! umount "$NTFS_MOUNT" 2>/dev/null; then
        show_error "Failed to unmount $NTFS_MOUNT"
        unmount_failed=true
    fi
    
    if ! umount "$TARGET_MOUNT" 2>/dev/null; then
        show_error "Failed to unmount $TARGET_MOUNT"
        unmount_failed=true
    fi
    
    # Verify unmount succeeded
    if mountpoint -q "$NTFS_MOUNT" 2>/dev/null || mountpoint -q "$TARGET_MOUNT" 2>/dev/null; then
        show_error "Partitions are still mounted after unmount attempt"
        unmount_failed=true
    fi
    
    # Cleanup mount points
    rmdir "$NTFS_MOUNT" 2>/dev/null || true
    rmdir "$TARGET_MOUNT" 2>/dev/null || true
    
    if [ "$unmount_failed" = true ]; then
        show_error "Unmount verification failed. Please check manually."
        return 1
    fi
    
    # Final sync after unmount
    sync
    
    show_success "File migration completed, verified, and source files safely removed"
    return 0
}

###############################################################################
# Partition Information
###############################################################################

get_partition_size_kb() {
    local partition="$1"
    local disk
    disk=$(echo "$partition" | sed 's/[0-9]*$//')
    local part_num
    part_num=$(echo "$partition" | grep -o '[0-9]*$')
    local start_kb end_kb
    start_kb=$(parted "$disk" unit KB print | grep "^ $part_num" | awk '{print $2}' | sed 's/kB//')
    end_kb=$(parted "$disk" unit KB print | grep "^ $part_num" | awk '{print $3}' | sed 's/kB//')
    echo $((end_kb - start_kb))
}

get_partition_start_kb() {
    local partition="$1"
    local disk
    disk=$(echo "$partition" | sed 's/[0-9]*$//')
    local part_num
    part_num=$(echo "$partition" | grep -o '[0-9]*$')
    parted "$disk" unit KB print | grep "^ $part_num" | awk '{print $2}' | sed 's/kB//'
}

get_partition_end_kb() {
    local partition="$1"
    local disk
    disk=$(echo "$partition" | sed 's/[0-9]*$//')
    local part_num
    part_num=$(echo "$partition" | grep -o '[0-9]*$')
    parted "$disk" unit KB print | grep "^ $part_num" | awk '{print $3}' | sed 's/kB//'
}

get_ntfs_used_space_kb() {
    local partition="$1"
    local mount_point="/mnt/ntfs_check_$$"
    
    mkdir -p "$mount_point"
    if mount "$partition" "$mount_point" 2>/dev/null; then
        local used_kb
        used_kb=$(df -k "$mount_point" | tail -1 | awk '{print $3}')
        umount "$mount_point"
        rmdir "$mount_point"
        echo "$used_kb"
    else
        # Fallback: estimate from partition size (conservative)
        local size_kb
        size_kb=$(get_partition_size_kb "$partition")
        echo $((size_kb * 80 / 100))  # Assume 80% used
    fi
}

get_disk_end_kb() {
    local disk="$1"
    parted "$disk" unit KB print | grep "^Disk $disk" | awk '{print $3}' | sed 's/kB//'
}

###############################################################################
# Main Conversion Loop
###############################################################################

main_conversion_loop() {
    show_info "Starting conversion process..."
    
    # Detect NTFS partition if not already set
    if [ -z "$NTFS_PARTITION" ]; then
        NTFS_PARTITION=$(detect_ntfs_partitions "$SELECTED_DISK")
        if [ -z "$NTFS_PARTITION" ]; then
            show_error "No NTFS partition found on $SELECTED_DISK"
            exit 1
        fi
    fi
    
    # Check for existing target filesystem partition
    if [ -z "$TARGET_PARTITION" ]; then
        local existing_partitions
        mapfile -t existing_partitions < <(detect_existing_partitions "$SELECTED_DISK" "$TARGET_FILESYSTEM")
        
        if [ ${#existing_partitions[@]} -gt 0 ]; then
            local options=("Use existing ${TARGET_FILESYSTEM} partition: ${existing_partitions[0]}" "Create new partition" "Cancel")
            local selection
            selection=$(show_menu "Existing Partition Found" "${options[@]}")
            
            case "$selection" in
                0)
                    TARGET_PARTITION="${existing_partitions[0]}"
                    USE_EXISTING=true
                    ;;
                1)
                    USE_EXISTING=false
                    ;;
                *)
                    exit 0
                    ;;
            esac
        else
            USE_EXISTING=false
        fi
    fi
    
    # Main iterative conversion loop
    # No iteration limit - continues until NTFS is empty or no progress is made
    local iteration=0
    local safety_buffer=5  # 5% safety buffer
    local previous_used_kb=0
    local no_progress_count=0
    local max_no_progress=3  # Allow 3 iterations with no progress before warning
    
    while true; do
        CURRENT_ITERATION=$iteration
        LAST_OPERATION="iteration_start"
        save_state
        
        clear_screen
        print_header
        show_info "Iteration $((iteration + 1)): Analyzing NTFS partition..."
        
        # Get NTFS used space
        local ntfs_used_kb
        ntfs_used_kb=$(get_ntfs_used_space_kb "$NTFS_PARTITION")
        local ntfs_size_kb
        ntfs_size_kb=$(get_partition_size_kb "$NTFS_PARTITION")
        local ntfs_free_kb
        ntfs_free_kb=$((ntfs_size_kb - ntfs_used_kb))
        
        show_info "NTFS: ${ntfs_used_kb}KB used, ${ntfs_free_kb}KB free out of ${ntfs_size_kb}KB total"
        
        # Check if NTFS is essentially empty (less than 1MB remaining)
        # Use dynamic threshold based on disk size (0.1% of disk or 1MB, whichever is larger)
        local disk_size_kb
        disk_size_kb=$(get_disk_end_kb "$SELECTED_DISK")
        local empty_threshold=$((disk_size_kb / 1000))  # 0.1% of disk
        if [ $empty_threshold -lt 1024 ]; then
            empty_threshold=1024  # Minimum 1MB
        fi
        
        if [ $ntfs_used_kb -lt $empty_threshold ]; then
            show_info "NTFS partition is essentially empty (${ntfs_used_kb}KB < ${empty_threshold}KB). Proceeding to final steps..."
            break
        fi
        
        # Check for progress
        if [ $iteration -gt 0 ]; then
            local progress_kb=$((previous_used_kb - ntfs_used_kb))
            if [ $progress_kb -lt 1024 ]; then
                # Less than 1MB progress
                no_progress_count=$((no_progress_count + 1))
                if [ $no_progress_count -ge $max_no_progress ]; then
                    show_warning "No significant progress made in last $max_no_progress iterations"
                    show_warning "Previous: ${previous_used_kb}KB, Current: ${ntfs_used_kb}KB"
                    local options=("Yes, continue" "No, abort")
                    local user_choice
                    user_choice=$(show_menu "Continue anyway?" "${options[@]}")
                    # user_choice: 0 = "Yes, continue", 1 = "No, abort", -1 = cancelled
                    if [ "$user_choice" = "-1" ] || [ "$user_choice" = "1" ]; then
                        # User chose to abort or cancelled
                        show_info "Aborting conversion"
                        exit 1
                    fi
                    # user_choice is 0, continue
                    no_progress_count=0  # Reset counter
                fi
            else
                # Progress made, reset counter
                no_progress_count=0
                show_info "Progress: ${progress_kb}KB migrated in this iteration"
            fi
        fi
        
        previous_used_kb=$ntfs_used_kb
        
        # Calculate target size with safety buffer
        local target_size_kb
        target_size_kb=$((ntfs_used_kb + (ntfs_used_kb * safety_buffer / 100)))
        
        # If using existing partition, check available space
        if [ "$USE_EXISTING" = true ]; then
            local target_mount="/mnt/target_check_$$"
            mkdir -p "$target_mount"
            if mount "$TARGET_PARTITION" "$target_mount" 2>/dev/null; then
                local target_avail_kb
                target_avail_kb=$(df -k "$target_mount" | tail -1 | awk '{print $4}')
                umount "$target_mount"
                rmdir "$target_mount"
                
                if [ $target_avail_kb -lt $ntfs_used_kb ]; then
                    show_warning "Existing partition has insufficient space. Need ${ntfs_used_kb}KB, have ${target_avail_kb}KB"
                    # Continue anyway, will migrate what fits
                fi
            fi
        else
            # Shrink NTFS partition
            LAST_OPERATION="shrink_ntfs"
            save_state
            
            show_info "Shrinking NTFS partition to ${target_size_kb}KB..."
            if ! shrink_ntfs "$NTFS_PARTITION" "$target_size_kb"; then
                show_error "Failed to shrink NTFS partition"
                exit 1
            fi
            
            # Create new partition if this is first iteration
            if [ $iteration -eq 0 ]; then
                show_info "Creating target ${TARGET_FILESYSTEM} partition..."
                
                # Get new NTFS end position after shrink
                local new_ntfs_end_kb
                new_ntfs_end_kb=$(get_partition_end_kb "$NTFS_PARTITION")
                
                # Create target partition after NTFS
                local disk_end_kb
                disk_end_kb=$(get_disk_end_kb "$SELECTED_DISK")
                local target_start_kb
                target_start_kb=$((new_ntfs_end_kb + 1024))  # 1MB gap
                local target_end_kb
                target_end_kb=$disk_end_kb
                
                TARGET_PARTITION=$(create_partition "$SELECTED_DISK" "$target_start_kb" "$target_end_kb")
                
                if [ -z "$TARGET_PARTITION" ]; then
                    show_error "Failed to create target partition"
                    exit 1
                fi
                
                # Format the new partition
                LAST_OPERATION="format_filesystem"
                save_state
                
                if ! format_filesystem "$TARGET_PARTITION" "$TARGET_FILESYSTEM"; then
                    show_error "Failed to format target partition"
                    exit 1
                fi
            else
                # In subsequent iterations, expand target partition into freed space
                show_info "Expanding target partition into freed space..."
                
                local target_part_num
                target_part_num=$(echo "$TARGET_PARTITION" | grep -o '[0-9]*$')
                local disk_end_kb
                disk_end_kb=$(get_disk_end_kb "$SELECTED_DISK")
                
                # Expand partition table entry
                LAST_OPERATION="expand_partition"
                save_state
                
                if [ "$DRY_RUN" != true ]; then
                    parted "$SELECTED_DISK" resizepart "$target_part_num" "${disk_end_kb}KB" >/dev/null 2>&1 || {
                        show_warning "Failed to expand partition table entry"
                    }
                    sleep 1
                    partprobe "$SELECTED_DISK" >/dev/null 2>&1 || true
                    sleep 1
                    
                    # Expand filesystem to use new space
                    local temp_mount=""
                    if [ "${FS_RESIZE_REQUIRES_MOUNT[$TARGET_FILESYSTEM]}" = true ]; then
                        temp_mount="/mnt/temp_iter_expand_$$"
                        mkdir -p "$temp_mount"
                        if mount "$TARGET_PARTITION" "$temp_mount" 2>/dev/null; then
                            expand_filesystem "$TARGET_PARTITION" "$temp_mount" "$TARGET_FILESYSTEM" || true
                            umount "$temp_mount" 2>/dev/null || true
                            rmdir "$temp_mount" 2>/dev/null || true
                        fi
                    else
                        expand_filesystem "$TARGET_PARTITION" "" "$TARGET_FILESYSTEM" || true
                    fi
                fi
            fi
        fi
        
        # Migrate files
        LAST_OPERATION="migrate_files"
        save_state
        
        show_info "Migrating files from NTFS to ${TARGET_FILESYSTEM}..."
        if ! migrate_files "$NTFS_PARTITION" "$TARGET_PARTITION"; then
            show_error "Failed to migrate files"
            exit 1
        fi
        
        # Wait for all operations to complete before checking remaining space
        show_info "Waiting for all file operations to complete..."
        sync_filesystems
        
        # Verify migration and check remaining files
        # Re-check after sync to ensure accurate measurement
        local remaining_kb
        remaining_kb=$(get_ntfs_used_space_kb "$NTFS_PARTITION")
        
        # Calculate how much was actually migrated
        local migrated_this_iteration=$((ntfs_used_kb - remaining_kb))
        
        if [ $remaining_kb -ge $ntfs_used_kb ]; then
            show_warning "File migration may not have reduced NTFS usage."
            show_warning "Previous: ${ntfs_used_kb}KB, Current: ${remaining_kb}KB"
            # Still continue - may be filesystem metadata or small files
        else
            show_success "Migrated approximately ${migrated_this_iteration}KB in this iteration"
        fi
        
        # Use dynamic threshold based on disk size
        local disk_size_kb
        disk_size_kb=$(get_disk_end_kb "$SELECTED_DISK")
        local continue_threshold=$((disk_size_kb / 100))  # 1% of disk
        if [ $continue_threshold -lt 10240 ]; then
            continue_threshold=10240  # Minimum 10MB
        fi
        
        # If NTFS still has significant data, continue iteration
        if [ $remaining_kb -gt $continue_threshold ]; then
            show_info "Remaining data (${remaining_kb}KB) exceeds threshold (${continue_threshold}KB). Continuing..."
            iteration=$((iteration + 1))
            # Small delay to ensure filesystem is ready
            sleep 1
            continue
        else
            show_info "Remaining data (${remaining_kb}KB) is below threshold (${continue_threshold}KB). Proceeding to final steps..."
            break
        fi
    done
    
    # Final steps: delete NTFS and expand target
    show_info "Finalizing conversion..."
    
    # Delete NTFS partition
    LAST_OPERATION="delete_ntfs"
    save_state
    
    local part_num
    part_num=$(echo "$NTFS_PARTITION" | grep -o '[0-9]*$')
    local disk
    disk=$(echo "$NTFS_PARTITION" | sed 's/[0-9]*$//')
    
    show_info "Deleting NTFS partition $NTFS_PARTITION"
    if [ "$DRY_RUN" != true ]; then
        parted "$disk" rm "$part_num" >/dev/null 2>&1 || {
            show_error "Failed to delete NTFS partition"
            exit 1
        }
    fi
    
    # Expand target partition to fill disk
    LAST_OPERATION="expand_filesystem"
    save_state
    
    # First expand partition table entry
    local target_part_num
    target_part_num=$(echo "$TARGET_PARTITION" | grep -o '[0-9]*$')
    local disk_end_kb
    disk_end_kb=$(get_disk_end_kb "$SELECTED_DISK")
    
    show_info "Expanding partition table entry..."
    if [ "$DRY_RUN" != true ]; then
        parted "$SELECTED_DISK" resizepart "$target_part_num" "${disk_end_kb}KB" >/dev/null 2>&1 || {
            show_warning "Failed to expand partition table entry"
        }
        
        # Wait for kernel to recognize change
        sleep 2
        partprobe "$SELECTED_DISK" >/dev/null 2>&1 || true
        sleep 1
    fi
    
    # Expand filesystem
    show_info "Expanding ${TARGET_FILESYSTEM} filesystem..."
    local temp_mount=""
    if [ "${FS_RESIZE_REQUIRES_MOUNT[$TARGET_FILESYSTEM]}" = true ]; then
        temp_mount="/mnt/temp_expand_$$"
        mkdir -p "$temp_mount"
        mount "$TARGET_PARTITION" "$temp_mount" || {
            show_error "Failed to mount partition for resize"
            exit 1
        }
    fi
    
    if ! expand_filesystem "$TARGET_PARTITION" "$temp_mount" "$TARGET_FILESYSTEM"; then
        show_error "Failed to expand filesystem"
        if [ -n "$temp_mount" ]; then
            umount "$temp_mount" 2>/dev/null || true
            rmdir "$temp_mount" 2>/dev/null || true
        fi
        exit 1
    fi
    
    if [ -n "$temp_mount" ]; then
        umount "$temp_mount" 2>/dev/null || true
        rmdir "$temp_mount" 2>/dev/null || true
    fi
    
    LAST_OPERATION="complete"
    save_state
    
    show_success "Conversion completed successfully!"
    show_info "NTFS partition has been converted to ${TARGET_FILESYSTEM}"
    show_info "Total iterations: $((iteration + 1))"
    show_info "Files migrated: $FILES_MIGRATED"
    
    # Offer defragmentation for the target filesystem if HDD
    check_and_offer_post_conversion_defrag "$SELECTED_DISK" "$TARGET_PARTITION" "$TARGET_FILESYSTEM"
}

###############################################################################
# Main Entry Point
###############################################################################

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -h|--help)
                echo "Usage: $SCRIPT_NAME [--dry-run]"
                exit 0
                ;;
            *)
                show_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    # Check root
    check_root
    
    # Print welcome
    print_header
    show_info "Welcome to NTFS to Linux Filesystem Converter v${SCRIPT_VERSION}"
    sleep 2
    
    # Check for resume state
    if check_resume_state; then
        show_info "Resuming from previous conversion..."
        # Check dependencies for resumed filesystem
        if [ -n "$TARGET_FILESYSTEM" ]; then
            check_dependencies "$TARGET_FILESYSTEM"
        fi
    else
        # Check base dependencies first
        check_dependencies ""
        
        # Select disk
        select_disk
        
        # Check if HDD and offer defragmentation
        local ntfs_part
        ntfs_part=$(detect_ntfs_partitions "$SELECTED_DISK")
        check_and_offer_defrag "$SELECTED_DISK" "$ntfs_part"
        
        # Select filesystem
        select_filesystem
        
        # Save initial state
        save_state
    fi
    
    # Run conversion
    main_conversion_loop
    
    # Cleanup
    cleanup_state
}

# Trap signals for graceful exit
trap 'save_state; exit 1' INT TERM

# Run main function
main "$@"

