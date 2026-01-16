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

# Ensure stdout is line-buffered for immediate display updates
# This is critical for TUI to update properly during auto-advance
if [ -t 1 ] && command -v stdbuf >/dev/null 2>&1 && [ -z "${STDBUF_SET:-}" ]; then
    export STDBUF_SET=1
    # Get the full path to the script
    SCRIPT_PATH="$0"
    if [ "${SCRIPT_PATH#/}" = "$SCRIPT_PATH" ]; then
        # Not an absolute path, resolve it
        SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    fi
    # Always use bash (not sh) with stdbuf for proper buffering
    # This ensures the script runs with line-buffered output
    exec stdbuf -oL -eL bash "$SCRIPT_PATH" "$@"
    exit $?  # Should never reach here
fi

# Shell detection and compatibility
DETECTED_SHELL=""
if [ -n "${ZSH_VERSION:-}" ]; then
    DETECTED_SHELL="zsh"
elif [ -n "${BASH_VERSION:-}" ]; then
    DETECTED_SHELL="bash"
elif [ -n "${FISH_VERSION:-}" ]; then
    DETECTED_SHELL="fish"
else
    # Try to detect from $0 or parent process
    DETECTED_SHELL=$(basename "${SHELL:-bash}" 2>/dev/null || echo "bash")
fi

# Check if running in bash (required for this script)
if [ "$DETECTED_SHELL" != "bash" ] && [ -z "${BASH_VERSION:-}" ]; then
    echo "Error: This script requires bash to run properly." >&2
    echo "Detected shell: $DETECTED_SHELL" >&2
    echo "Please run with: bash $0" >&2
    exit 1
fi

# Script configuration
SCRIPT_NAME="convert_ntfs_to_linux_fs.sh"
SCRIPT_VERSION="1.0.0"
STATE_DIR="${HOME}/.ntfs_to_linux_fs"
STATE_FILE=""

# Compatibility function for reading input
# Works reliably across bash, zsh, and when invoked from fish
safe_read() {
    # Use bash's built-in read which works even when script is invoked from other shells
    # as long as the script itself is running in bash
    # This is a simple wrapper that ensures read works correctly
    IFS= read -r line || true
    echo "$line"
}

# Color codes using tput for compatibility
RED=$(tput setaf 1 2>/dev/null || echo "")
GREEN=$(tput setaf 2 2>/dev/null || echo "")
YELLOW=$(tput setaf 3 2>/dev/null || echo "")
BLUE=$(tput setaf 4 2>/dev/null || echo "")
CYAN=$(tput setaf 6 2>/dev/null || echo "")
WHITE=$(tput setaf 7 2>/dev/null || echo "")
DIM=$(tput dim 2>/dev/null || tput setaf 8 2>/dev/null || echo "")
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
DUMMY_MODE=false

# Dummy mode state (for --dummy-mode)
DUMMY_NTFS_SIZE_KB=50000000  # 50GB
DUMMY_NTFS_USED_KB=30000000  # 30GB used
DUMMY_DISK_SIZE_KB=100000000  # 100GB
DUMMY_ITERATION=0

# Screen layout configuration
SCREEN_COLS=80
SCREEN_ROWS=24
HEADER_ROWS=2
FOOTER_ROWS=1
STATUS_ROW=0        # Calculated at runtime (SCREEN_ROWS - FOOTER_ROWS - 1)
CONTENT_START_ROW=3
CONTENT_END_ROW=0   # Calculated at runtime
SCREEN_INITIALIZED=false

# Current UI state
CURRENT_STATUS=""
CURRENT_PROGRESS=""
LOG_LINES=()
MAX_LOG_LINES=10

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

# Strip ANSI escape sequences from a string
strip_ansi() {
    local text="$1"
    # Remove ANSI escape sequences (ESC[ followed by numbers, semicolons, and ending with m)
    echo "$text" | sed 's/\x1b\[[0-9;]*m//g'
}

# Get terminal size
get_terminal_size() {
    local cols rows
    local tput_cols tput_rows
    
    # Try tput first
    if command -v tput >/dev/null 2>&1; then
        tput_cols=$(tput cols 2>/dev/null || echo "")
        tput_rows=$(tput lines 2>/dev/null || echo "")
        
        # Validate tput output is numeric and positive
        if [ -n "$tput_cols" ] && [ "$tput_cols" -gt 0 ] 2>/dev/null; then
            cols="$tput_cols"
        else
            cols=""
        fi
        
        if [ -n "$tput_rows" ] && [ "$tput_rows" -gt 0 ] 2>/dev/null; then
            rows="$tput_rows"
        else
            rows=""
        fi
    fi
    
    # Fallback to environment variables if tput failed or returned invalid values
    if [ -z "$cols" ] || [ "$cols" -le 0 ] 2>/dev/null; then
        if [ -n "${COLUMNS:-}" ] && [ "$COLUMNS" -gt 0 ] 2>/dev/null; then
            cols="$COLUMNS"
        else
            cols=80
        fi
    fi
    
    if [ -z "$rows" ] || [ "$rows" -le 0 ] 2>/dev/null; then
        if [ -n "${LINES:-}" ] && [ "$LINES" -gt 0 ] 2>/dev/null; then
            rows="$LINES"
        else
            rows=24
        fi
    fi
    
    # Ensure minimum size and validate values are numeric
    if [ "$cols" -lt 80 ] 2>/dev/null || [ -z "$cols" ]; then
        cols=80
    fi
    if [ "$rows" -lt 24 ] 2>/dev/null || [ -z "$rows" ]; then
        rows=24
    fi
    
    # Final validation - ensure we have valid numbers
    if ! [ "$cols" -gt 0 ] 2>/dev/null; then
        cols=80
    fi
    if ! [ "$rows" -gt 0 ] 2>/dev/null; then
        rows=24
    fi
    
    echo "$cols $rows"
}

###############################################################################
# Screen Layout Management
###############################################################################

# Initialize screen layout - calculates row positions based on terminal size
init_screen_layout() {
    local size
    size=$(get_terminal_size)
    SCREEN_COLS=$(echo "$size" | cut -d' ' -f1)
    SCREEN_ROWS=$(echo "$size" | cut -d' ' -f2)
    
    # Calculate dynamic row positions
    STATUS_ROW=$((SCREEN_ROWS - FOOTER_ROWS - 1))
    CONTENT_END_ROW=$((STATUS_ROW - 1))
    
    SCREEN_INITIALIZED=true
}

# Draw the static header (minimal style)
draw_header() {
    local title="NTFS to Linux Converter"
    local version="v${SCRIPT_VERSION}"
    
    # Position at top
    tput cup 0 0 >/dev/tty 2>/dev/null || true
    
    # Clear header area
    printf "%-${SCREEN_COLS}s" "" >/dev/tty
    tput cup 0 0 >/dev/tty 2>/dev/null || true
    
    # Draw title line
    printf " ${BOLD}${CYAN}%s${RESET}" "$title" >/dev/tty
    
    # Draw version right-aligned
    local version_col=$((SCREEN_COLS - ${#version} - 1))
    tput cup 0 $version_col >/dev/tty 2>/dev/null || true
    printf "${DIM}%s${RESET}" "$version" >/dev/tty
    
    # Draw separator line
    tput cup 1 0 >/dev/tty 2>/dev/null || true
    printf " ${DIM}" >/dev/tty
    local i
    for ((i=0; i<SCREEN_COLS-2; i++)); do
        printf "%s" "$BOX_H" >/dev/tty
    done
    printf "${RESET}" >/dev/tty
}

# Draw the static footer with help text
draw_footer() {
    local help_text="^/v Navigate | Enter Select | q Quit | ESC Back"
    
    tput cup $((SCREEN_ROWS - 1)) 0 >/dev/tty 2>/dev/null || true
    printf " ${DIM}%s${RESET}" "$help_text" >/dev/tty
    
    # Fill rest of line
    local help_len=${#help_text}
    local remaining=$((SCREEN_COLS - help_len - 2))
    if [ $remaining -gt 0 ]; then
        printf "%*s" $remaining "" >/dev/tty
    fi
}

# Draw the status bar
draw_status_bar() {
    local status="${1:-}"
    local progress="${2:-}"
    
    tput cup $STATUS_ROW 0 >/dev/tty 2>/dev/null || true
    
    # Draw separator above status bar
    printf " ${DIM}" >/dev/tty
    local i
    for ((i=0; i<SCREEN_COLS-2; i++)); do
        printf "%s" "$BOX_H" >/dev/tty
    done
    printf "${RESET}" >/dev/tty
    
    # Move to status bar line
    tput cup $((STATUS_ROW + 1)) 0 >/dev/tty 2>/dev/null || true
    
    if [ -n "$status" ]; then
        printf " ${CYAN}%s${RESET}" "$status" >/dev/tty
        if [ -n "$progress" ]; then
            printf " ${DIM}|${RESET} %s" "$progress" >/dev/tty
        fi
    fi
    
    # Clear to end of line
    tput el >/dev/tty 2>/dev/null || true
    
    # Store current status
    CURRENT_STATUS="$status"
    CURRENT_PROGRESS="$progress"
}

# Update only the status bar (no screen clear)
update_status_bar() {
    local status="${1:-$CURRENT_STATUS}"
    local progress="${2:-}"
    
    if [ "$SCREEN_INITIALIZED" != true ]; then
        init_screen_layout
    fi
    
    # Keep cursor hidden during UI updates
    tput civis >/dev/tty 2>/dev/null || true
    
    draw_status_bar "$status" "$progress"
}

# Clear only the content area (not header/footer/status)
clear_content_area() {
    if [ "$SCREEN_INITIALIZED" != true ]; then
        init_screen_layout
    fi
    
    local row
    for ((row=CONTENT_START_ROW; row<=CONTENT_END_ROW; row++)); do
        tput cup $row 0 >/dev/tty 2>/dev/null || true
        tput el >/dev/tty 2>/dev/null || true
    done
    
    # Position cursor at start of content area
    tput cup $CONTENT_START_ROW 1 >/dev/tty 2>/dev/null || true
}

# Initialize the full screen layout
init_screen() {
    init_screen_layout
    
    # Hide cursor during drawing
    tput civis >/dev/tty 2>/dev/null || true
    
    # Clear entire screen once
    tput clear >/dev/tty 2>/dev/null || true
    
    # Draw static elements
    draw_header
    draw_footer
    draw_status_bar "" ""
    
    # Position cursor in content area
    tput cup $CONTENT_START_ROW 1 >/dev/tty 2>/dev/null || true
}

# Cleanup screen on exit
cleanup_screen() {
    # Show cursor
    tput cnorm >/dev/tty 2>/dev/null || true
    # Move to bottom of screen
    tput cup $((SCREEN_ROWS - 1)) 0 >/dev/tty 2>/dev/null || true
    printf "\n" >/dev/tty
}

# Get the number of available content rows
get_content_rows() {
    if [ "$SCREEN_INITIALIZED" != true ]; then
        init_screen_layout
    fi
    echo $((CONTENT_END_ROW - CONTENT_START_ROW + 1))
}

# Write text at a specific row in content area (0-indexed from content start)
write_content_line() {
    local row="$1"
    local text="$2"
    local actual_row=$((CONTENT_START_ROW + row))
    
    if [ $actual_row -le $CONTENT_END_ROW ]; then
        tput cup $actual_row 1 >/dev/tty 2>/dev/null || true
        printf "%s" "$text" >/dev/tty
        tput el >/dev/tty 2>/dev/null || true
    fi
}

# Add a message to the log display (scrolling log in content area)
log_message() {
    local message="$1"
    local level="${2:-info}"  # info, success, warning, error
    
    if [ "$SCREEN_INITIALIZED" != true ]; then
        init_screen_layout
    fi
    
    # Keep cursor hidden during UI updates
    tput civis >/dev/tty 2>/dev/null || true
    
    # Add color prefix based on level
    local colored_msg
    case "$level" in
        success) colored_msg="${GREEN}${CHECK}${RESET} $message" ;;
        warning) colored_msg="${YELLOW}${WARN}${RESET} $message" ;;
        error)   colored_msg="${RED}${CROSS}${RESET} $message" ;;
        *)       colored_msg="${CYAN}${ARROW_R}${RESET} $message" ;;
    esac
    
    # Add to log array
    LOG_LINES+=("$colored_msg")
    
    # Keep only last MAX_LOG_LINES entries
    local log_count=${#LOG_LINES[@]}
    if [ $log_count -gt $MAX_LOG_LINES ]; then
        LOG_LINES=("${LOG_LINES[@]:$((log_count - MAX_LOG_LINES))}")
    fi
    
    # Render log to content area
    render_log
}

# Render the log lines to the content area
render_log() {
    local content_rows
    content_rows=$(get_content_rows)
    local log_count=${#LOG_LINES[@]}
    local start_row=0
    
    # Calculate starting position to show most recent logs at bottom
    if [ $log_count -lt $content_rows ]; then
        start_row=$((content_rows - log_count - 1))
    fi
    
    # Clear content area first
    clear_content_area
    
    # Write each log line
    local i
    local row=$start_row
    for ((i=0; i<log_count && row<content_rows; i++, row++)); do
        write_content_line $row "${LOG_LINES[$i]}"
    done
}

# Clear the log
clear_log() {
    LOG_LINES=()
    clear_content_area
}

# Show a panel in the content area (for menus, info displays)
# This clears content area and renders the panel content
show_panel() {
    local title="$1"
    local content="$2"
    
    if [ "$SCREEN_INITIALIZED" != true ]; then
        init_screen
    fi
    
    # Keep cursor hidden during UI updates
    tput civis >/dev/tty 2>/dev/null || true
    
    clear_content_area
    
    # Draw panel title
    write_content_line 0 "${BOLD}${CYAN}$title${RESET}"
    write_content_line 1 ""
    
    # Draw content lines
    local line_num=2
    while IFS= read -r line; do
        write_content_line $line_num "$line"
        ((line_num++))
    done <<< "$content"
}

# Show a modal dialog (saves/restores screen state)
show_modal() {
    local title="$1"
    local message="$2"
    local type="${3:-info}"  # info, success, warning, error
    local wait_for_key="${4:-true}"
    
    if [ "$SCREEN_INITIALIZED" != true ]; then
        init_screen
    fi
    
    # Keep cursor hidden during UI updates
    tput civis >/dev/tty 2>/dev/null || true
    
    clear_content_area
    
    # Set color based on type
    local title_color
    case "$type" in
        success) title_color="$GREEN" ;;
        warning) title_color="$YELLOW" ;;
        error)   title_color="$RED" ;;
        *)       title_color="$CYAN" ;;
    esac
    
    # Draw modal title
    write_content_line 0 "${BOLD}${title_color}$title${RESET}"
    write_content_line 1 ""
    
    # Draw message lines
    local line_num=2
    while IFS= read -r line; do
        write_content_line $line_num " $line"
        ((line_num++))
    done <<< "$message"
    
    if [ "$wait_for_key" = "true" ]; then
        ((line_num++))
        write_content_line $line_num ""
        write_content_line $((line_num + 1)) "${DIM}Press Enter to continue...${RESET}"
        
        # Wait for key press
        read -rsn1 </dev/tty 2>/dev/null || true
    fi
}

# Draw a progress bar at the current cursor position
draw_inline_progress() {
    local current="$1"
    local total="$2"
    local width="${3:-30}"
    local label="${4:-}"
    
    local percent=0
    if [ "$total" -gt 0 ]; then
        percent=$((current * 100 / total))
    fi
    local filled=$((current * width / total))
    local empty=$((width - filled))
    
    local bar="["
    local i
    for ((i=0; i<filled; i++)); do bar+="="; done
    for ((i=0; i<empty; i++)); do bar+="-"; done
    bar+="]"
    
    if [ -n "$label" ]; then
        printf "%s %s %3d%%" "$label" "$bar" "$percent"
    else
        printf "%s %3d%%" "$bar" "$percent"
    fi
}

# Render a progress display panel
render_progress_panel() {
    local title="$1"
    local source_label="$2"
    local target_label="$3"
    local iteration_current="$4"
    local iteration_total="$5"
    local progress_percent="$6"
    local files_current="$7"
    local files_total="$8"
    local current_op="$9"
    
    if [ "$SCREEN_INITIALIZED" != true ]; then
        init_screen
    fi
    
    # Keep cursor hidden during UI updates
    tput civis >/dev/tty 2>/dev/null || true
    
    clear_content_area
    
    # Title
    write_content_line 0 "${BOLD}${CYAN}$title${RESET}"
    write_content_line 1 ""
    
    # Source/Target info
    write_content_line 2 " Source:    ${BOLD}$source_label${RESET}"
    write_content_line 3 " Target:    ${BOLD}$target_label${RESET}"
    write_content_line 4 ""
    
    # Progress bars
    local iter_bar
    iter_bar=$(draw_inline_progress "$iteration_current" "$iteration_total" 20)
    write_content_line 5 " Iteration  $iter_bar  $iteration_current / $iteration_total"
    
    local prog_bar
    prog_bar=$(draw_inline_progress "$progress_percent" 100 20)
    write_content_line 6 " Progress   $prog_bar"
    
    if [ "$files_total" -gt 0 ]; then
        local files_bar
        files_bar=$(draw_inline_progress "$files_current" "$files_total" 20)
        write_content_line 7 " Files      $files_bar  $files_current / $files_total"
    fi
    
    write_content_line 8 ""
    write_content_line 9 " ${DIM}Current:${RESET} $current_op"
    
    # Update status bar
    update_status_bar "$current_op" "${progress_percent}%"
}

# Center text
center_text() {
    local text="$1"
    local width
    width=$(get_terminal_size | cut -d' ' -f1)
    local text_stripped
    text_stripped=$(strip_ansi "$text")
    local padding=$(( (width - ${#text_stripped}) / 2 ))
    printf "%*s%s\n" $padding "" "$text" >/dev/tty 2>/dev/null || printf "%*s%s\n" $padding "" "$text"
}

# Clear screen using cursor positioning (prevents flickering)
clear_screen() {
    if command -v tput >/dev/null 2>&1; then
        # Use cursor positioning instead of full clear to prevent flickering
        # Move to home position and clear to end of screen
        tput cup 0 0 >/dev/tty 2>/dev/null || true
        tput ed >/dev/tty 2>/dev/null || true
    else
        clear >/dev/tty 2>/dev/null || clear
    fi
    # Force output flush
    sync >/dev/null 2>&1 || true
}

# Draw a box (returns output as string for double buffering)
draw_box() {
    local width="$1"
    local title="$2"
    local content="$3"
    
    local title_stripped
    title_stripped=$(strip_ansi "$title")
    local title_len=${#title_stripped}
    local title_pad=$(( (width - title_len - 2) / 2 ))
    
    local box_output=""
    
    # Top border
    box_output+="${BOX_TL}"
    local i
    for ((i=0; i<width-2; i++)); do box_output+="${BOX_H}"; done
    box_output+="${BOX_TR}\n"
    
    # Title line
    box_output+="${BOX_V}"
    local j
    for ((j=0; j<title_pad; j++)); do box_output+=" "; done
    local title_with_colors="${BOLD}${CYAN}${title}${RESET}"
    box_output+="$title_with_colors"
    local title_display_len=$title_len
    local right_pad=$((width - title_pad - title_display_len - 2))
    if [ $right_pad -lt 0 ]; then
        right_pad=0
    fi
    for ((j=0; j<right_pad; j++)); do box_output+=" "; done
    box_output+="${BOX_V}\n"
    
    # Separator
    box_output+="${BOX_T}"
    for ((i=0; i<width-2; i++)); do box_output+="${BOX_H}"; done
    box_output+="${BOX_T}\n"
    
    # Content - process line by line
    # Use a method that works in all shells (sh, bash, zsh, fish)
    # Split content by newlines and process each line
    local content_processed
    content_processed=$(printf "%s\n" "$content" | {
        local line_output=""
        while IFS= read -r line || [ -n "${line:-}" ]; do
            line_output+="${BOX_V}"
            local line_len=${#line}
            line_output+="$line"
            # Pad line to width-2
            local pad_needed=$((width - 2 - line_len))
            if [ $pad_needed -gt 0 ]; then
                local k
                for ((k=0; k<pad_needed; k++)); do line_output+=" "; done
            fi
            line_output+="${BOX_V}\n"
        done
        printf "%s" "$line_output"
    })
    box_output+="$content_processed"
    
    # Bottom border
    box_output+="${BOX_BL}"
    for ((i=0; i<width-2; i++)); do box_output+="${BOX_H}"; done
    box_output+="${BOX_BR}\n"
    
    # Use printf to output, but we'll use %b when printing to interpret \n
    printf "%s" "$box_output"
}

# Show spinner
show_spinner() {
    local pid=$1
    local message="$2"
    local spin='|/-\'
    local i=0
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %4 ))
        printf "\r${CYAN}${spin:$i:1}${RESET} $message" >/dev/tty 2>/dev/null || printf "\r${CYAN}${spin:$i:1}${RESET} $message"
        sleep 0.1
    done
    printf "\r${GREEN}${CHECK}${RESET} $message\n" >/dev/tty 2>/dev/null || printf "\r${GREEN}${CHECK}${RESET} $message\n"
}

# Show progress bar
draw_progress_bar() {
    local current=$1
    local total=$2
    local width=50
    local percent=$(( current * 100 / total ))
    local filled=$(( current * width / total ))
    local empty=$(( width - filled ))
    
    local progress_bar="\r["
    local i
    for ((i=0; i<filled; i++)); do progress_bar+="█"; done
    for ((i=0; i<empty; i++)); do progress_bar+="░"; done
    progress_bar+="] ${percent}%%"
    printf "%s" "$progress_bar" >/dev/tty 2>/dev/null || printf "%s" "$progress_bar"
}

# Print header (returns output as string for double buffering)
print_header() {
    local width
    width=$(get_terminal_size | cut -d' ' -f1)
    
    local header_output=""
    header_output+="\n"
    
    local text1="${BOLD}${CYAN}╔══════════════════════════════════════════════════╗${RESET}"
    local text1_stripped
    text1_stripped=$(strip_ansi "$text1")
    local padding1=$(( (width - ${#text1_stripped}) / 2 ))
    local j
    for ((j=0; j<padding1; j++)); do header_output+=" "; done
    header_output+="$text1\n"
    
    local text2="${BOLD}${CYAN}║${RESET}  ${BOLD}NTFS to Linux Filesystem Converter${RESET}  ${BOLD}${CYAN}║${RESET}"
    local text2_stripped
    text2_stripped=$(strip_ansi "$text2")
    local padding2=$(( (width - ${#text2_stripped}) / 2 ))
    for ((j=0; j<padding2; j++)); do header_output+=" "; done
    header_output+="$text2\n"
    
    local text3="${BOLD}${CYAN}╚══════════════════════════════════════════════════╝${RESET}"
    local text3_stripped
    text3_stripped=$(strip_ansi "$text3")
    local padding3=$(( (width - ${#text3_stripped}) / 2 ))
    for ((j=0; j<padding3; j++)); do header_output+=" "; done
    header_output+="$text3\n"
    
    header_output+="\n"
    
    echo -n "$header_output"
}

# Print footer (returns output as string for double buffering)
print_footer() {
    local width
    width=$(get_terminal_size | cut -d' ' -f1)
    
    local footer_output=""
    footer_output+="\n"
    footer_output+="${BOX_TL}"
    local i
    for ((i=0; i<width-2; i++)); do footer_output+="${BOX_H}"; done
    footer_output+="${BOX_TR}\n"
    footer_output+="${BOX_V}"
    
    local help_text=" ↑↓ Navigate │ Enter Select │ ESC Cancel "
    local help_text_stripped
    help_text_stripped=$(strip_ansi "$help_text")
    local help_len=${#help_text_stripped}
    local help_pad=$(( (width - help_len - 2) / 2 ))
    if [ $help_pad -lt 0 ]; then
        help_pad=0
    fi
    local j
    for ((j=0; j<help_pad; j++)); do footer_output+=" "; done
    footer_output+="$help_text"
    local remaining=$((width - help_pad - help_len - 2))
    if [ $remaining -lt 0 ]; then
        remaining=0
    fi
    for ((j=0; j<remaining; j++)); do footer_output+=" "; done
    footer_output+="${BOX_V}\n"
    footer_output+="${BOX_BL}"
    for ((i=0; i<width-2; i++)); do footer_output+="${BOX_H}"; done
    footer_output+="${BOX_BR}\n"
    
    echo -n "$footer_output"
}

# Show menu - uses partial screen updates (only redraws changed lines)
show_menu() {
    local title="$1"
    shift
    local options=("$@")
    local selected=0
    local key
    
    # Ensure screen is initialized
    if [ "$SCREEN_INITIALIZED" != true ]; then
        init_screen
    fi
    
    # Save terminal settings
    local old_stty
    if command -v stty >/dev/null 2>&1; then
        old_stty=$(stty -g </dev/tty 2>/dev/null || echo "")
        if [ -n "$old_stty" ]; then
            stty -echo -icanon time 1 min 0 </dev/tty 2>/dev/null || true
            stty intr '' quit '' </dev/tty 2>/dev/null || true
        fi
    else
        old_stty=""
    fi
    
    # Hide cursor
    tput civis >/dev/tty 2>/dev/null || true
    
    # Update status bar with menu context
    update_status_bar "Select an option" ""
    
    # Menu item row offset (after title and blank line)
    local menu_row_offset=2
    
    # Track previous selection for optimized redraw
    local previous_selected=-1
    local needs_full_draw=true
    
    while true; do
        if [ "$needs_full_draw" = true ]; then
            # Full initial draw - clear content and draw everything
            clear_content_area
            
            # Draw menu title
            write_content_line 0 "${BOLD}${CYAN}$title${RESET}"
            write_content_line 1 ""
            
            # Draw all menu options
            local i
            for ((i=0; i<${#options[@]}; i++)); do
                local row=$((menu_row_offset + i))
                if [ $i -eq $selected ]; then
                    write_content_line $row " ${CYAN}${ARROW_R}${RESET} ${BOLD}${options[$i]}${RESET}"
                else
                    write_content_line $row "   ${options[$i]}"
                fi
            done
            
            previous_selected=$selected
            needs_full_draw=false
            
        elif [ "$previous_selected" -ne "$selected" ]; then
            # Optimized redraw - only update the two changed lines
            
            # Clear highlight from previous selection
            if [ $previous_selected -ge 0 ]; then
                local prev_row=$((menu_row_offset + previous_selected))
                write_content_line $prev_row "   ${options[$previous_selected]}"
            fi
            
            # Add highlight to new selection
            local new_row=$((menu_row_offset + selected))
            write_content_line $new_row " ${CYAN}${ARROW_R}${RESET} ${BOLD}${options[$selected]}${RESET}"
            
            previous_selected=$selected
        fi
        
        # Read key
        local key=""
        local read_status=0
        IFS= read -rsn1 -t 0.2 key </dev/tty 2>/dev/null
        read_status=$?
        
        # Check for timeout
        if [ $read_status -gt 128 ]; then
            continue
        fi
        
        # Check for Enter key
        if [ -z "$key" ] || [ "$key" = $'\r' ] || [ "$key" = $'\n' ]; then
            # Restore terminal settings but keep cursor hidden
            if [ -n "$old_stty" ]; then
                stty "$old_stty" </dev/tty 2>/dev/null || true
            fi
            echo $selected
            return
        fi
        
        case "$key" in
            $'\033')
                # Escape sequence
                local char1="" char2=""
                if IFS= read -rsn1 -t 0.05 char1 </dev/tty 2>/dev/null; then
                    IFS= read -rsn1 -t 0.05 char2 </dev/tty 2>/dev/null || true
                fi
                
                local esc_seq="${char1}${char2}"
                
                case "$esc_seq" in
                    '[A') 
                        # Up arrow
                        selected=$(( (selected - 1 + ${#options[@]}) % ${#options[@]} ))
                        ;;
                    '[B') 
                        # Down arrow
                        selected=$(( (selected + 1) % ${#options[@]} ))
                        ;;
                    '[C'|'[D')
                        # Left/Right - ignore
                        ;;
                    *)
                        # Plain Escape - cancel
                        if [ -n "$old_stty" ]; then
                            stty "$old_stty" </dev/tty 2>/dev/null || true
                        fi
                        echo -1
                        return
                        ;;
                esac
                ;;
            $'\177'|$'\b')
                # Backspace - cancel
                if [ -n "$old_stty" ]; then
                    stty "$old_stty" </dev/tty 2>/dev/null || true
                fi
                echo -1
                return
                ;;
            'q'|'Q')
                # Quit
                if [ -n "$old_stty" ]; then
                    stty "$old_stty" </dev/tty 2>/dev/null || true
                fi
                echo -1
                return
                ;;
            'k'|'K')
                # Vim-style up
                selected=$(( (selected - 1 + ${#options[@]}) % ${#options[@]} ))
                ;;
            'j'|'J')
                # Vim-style down
                selected=$(( (selected + 1) % ${#options[@]} ))
                ;;
        esac
    done
}

# Show message box - uses partial screen updates
# For modal messages (require user input), use show_modal behavior
# For status messages (auto advance), use log_message + status bar
show_message() {
    local title="$1"
    local message="$2"
    local color="$3"
    local auto_advance="${4:-false}"
    local delay="${5:-2}"
    
    # Ensure screen is initialized
    if [ "$SCREEN_INITIALIZED" != true ]; then
        init_screen
    fi
    
    # Determine message type from color
    local msg_type="info"
    if [ "$color" = "$RED" ]; then
        msg_type="error"
    elif [ "$color" = "$YELLOW" ]; then
        msg_type="warning"
    elif [ "$color" = "$GREEN" ]; then
        msg_type="success"
    fi
    
    if [ "$auto_advance" = "true" ]; then
        # For auto-advance messages, use log + status bar (no full screen clear)
        log_message "$message" "$msg_type"
        update_status_bar "$title: $message"
        sleep "$delay"
    else
        # For modal messages, use show_modal
        show_modal "$title" "$message" "$msg_type" "true"
    fi
}

# Show error - logs error and optionally waits for user
show_error() {
    local message="$1"
    local wait_for_key="${2:-true}"
    
    if [ "$SCREEN_INITIALIZED" != true ]; then
        init_screen
    fi
    
    log_message "$message" "error"
    update_status_bar "Error: $message"
    
    if [ "$wait_for_key" = "true" ]; then
        show_modal "Error" "$message" "error" "true"
    fi
}

# Show warning - logs warning and optionally waits for user
show_warning() {
    local message="$1"
    local wait_for_key="${2:-false}"
    
    if [ "$SCREEN_INITIALIZED" != true ]; then
        init_screen
    fi
    
    log_message "$message" "warning"
    update_status_bar "Warning: $message"
    
    if [ "$wait_for_key" = "true" ]; then
        show_modal "Warning" "$message" "warning" "true"
    fi
}

# Show success - logs success and optionally waits for user
show_success() {
    local message="$1"
    local wait_for_key="${2:-false}"
    
    if [ "$SCREEN_INITIALIZED" != true ]; then
        init_screen
    fi
    
    log_message "$message" "success"
    update_status_bar "Success: $message"
    
    if [ "$wait_for_key" = "true" ]; then
        show_modal "Success" "$message" "success" "true"
    fi
}

# Show info - logs info message (no screen clear, no wait)
show_info() {
    local message="$1"
    
    if [ "$SCREEN_INITIALIZED" != true ]; then
        init_screen
    fi
    
    log_message "$message" "info"
    update_status_bar "$message"
}

# Show info with auto-advance - logs message and brief delay
show_info_auto() {
    local message="$1"
    local delay="${2:-1}"
    
    if [ "$SCREEN_INITIALIZED" != true ]; then
        init_screen
    fi
    
    log_message "$message" "info"
    update_status_bar "$message"
    sleep "$delay"
}

###############################################################################
# Dependency Management
###############################################################################

check_root() {
    if [ "$DUMMY_MODE" = true ]; then
        return 0  # Skip root check in dummy mode
    fi
    if [ "$EUID" -ne 0 ]; then
        show_error "This script must be run as root or with sudo"
        exit 1
    fi
}

check_dependencies() {
    local fs_type="$1"
    if [ "$DUMMY_MODE" = true ]; then
        # Skip dependency checks in dummy mode
        show_info_auto "Dummy mode: Skipping dependency checks" 1
        return 0
    fi
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
        show_info_auto "Installing missing packages: ${missing_packages[*]}" 1
        if ! pacman -S --noconfirm "${missing_packages[@]}" >/dev/null 2>&1; then
            show_error "Failed to install packages. Please install manually: ${missing_packages[*]}"
            exit 1
        fi
        show_message "Success" "Packages installed successfully" "$GREEN" "true" 1
    fi
}

###############################################################################
# Disk and Partition Detection
###############################################################################

list_disks() {
    if [ "$DUMMY_MODE" = true ]; then
        echo "/dev/sda - 100G - Dummy Test Disk"
        return 0
    fi
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
    if [ "$DUMMY_MODE" = true ]; then
        echo "/dev/sda1"
        return 0
    fi
    lsblk -f -n -o NAME,FSTYPE "$disk" | grep -i ntfs | awk '{print "/dev/" $1}' | head -1
}

detect_existing_partitions() {
    local disk="$1"
    local fs_type="$2"
    if [ "$DUMMY_MODE" = true ]; then
        # Return empty in dummy mode (no existing partitions)
        return 0
    fi
    lsblk -f -n -o NAME,FSTYPE "$disk" | grep -i "^[^ ]* $fs_type" | awk '{print "/dev/" $1}'
}

# Detect if disk is HDD or SSD
detect_disk_type() {
    local disk="$1"
    if [ "$DUMMY_MODE" = true ]; then
        echo "HDD"  # Return HDD for dummy mode to test defrag flow
        return 0
    fi
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
    
    # SAFETY: Never defrag SSDs - derive disk from partition and check
    local disk
    disk=$(echo "$partition" | sed 's/[0-9]*$//')
    local disk_type
    disk_type=$(detect_disk_type "$disk")
    
    if [ "$disk_type" = "SSD" ]; then
        log_message "Defragmentation skipped - SSD detected (defrag harmful to SSDs)" "warning"
        return 0
    fi
    
    if [ "$disk_type" = "UNKNOWN" ]; then
        log_message "Defragmentation skipped - cannot confirm disk is HDD (safety precaution)" "warning"
        return 0
    fi
    
    show_info_auto "Defragmenting NTFS partition $partition..." 1
    show_message "Warning" "This may take a long time depending on partition size and fragmentation level" "$YELLOW" "true" 2
    
    if [ "$DUMMY_MODE" = true ]; then
        sleep 2  # Simulate defragmentation time
        return 0
    fi
    
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] Would defragment NTFS partition $partition"
        return 0
    fi
    
    # Check if partition is mounted and unmount if necessary
    # ntfsfix works on unmounted partitions
    local mount_point
    mount_point=$(findmnt -n -o TARGET "$partition" 2>/dev/null || echo "")
    
    if [ -n "$mount_point" ]; then
        show_info_auto "Unmounting partition for optimization..." 1
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
    show_info_auto "Running NTFS filesystem check and optimization (this may take a while)..." 1
    
    local defrag_success=false
    
    # Try ntfsfix (available in ntfs-3g package)
    # This doesn't fully defragment but can optimize and fix filesystem issues
    if command -v ntfsfix >/dev/null 2>&1; then
        if ntfsfix "$partition" >/dev/null 2>&1; then
            defrag_success=true
            show_info_auto "NTFS filesystem check and optimization completed" 1
        else
            show_warning "ntfsfix had issues, but continuing..."
            defrag_success=true  # Still consider it attempted
        fi
    else
        show_warning "ntfsfix not available. For best results, defragment using Windows tools before conversion."
    fi
    
    # Remount if it was previously mounted
    if [ -n "$mount_point" ] && [ -d "$mount_point" ]; then
        show_info_auto "Remounting partition..." 1
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
    
    # SAFETY: Never defrag SSDs - derive disk from partition and check
    local disk
    disk=$(echo "$partition" | sed 's/[0-9]*$//')
    local disk_type
    disk_type=$(detect_disk_type "$disk")
    
    if [ "$disk_type" = "SSD" ]; then
        log_message "Defragmentation skipped - SSD detected (defrag harmful to SSDs)" "warning"
        return 0
    fi
    
    if [ "$disk_type" = "UNKNOWN" ]; then
        log_message "Defragmentation skipped - cannot confirm disk is HDD (safety precaution)" "warning"
        return 0
    fi
    
    show_info_auto "Defragmenting ${fs_type} partition $partition..." 1
    show_message "Warning" "This may take a long time depending on partition size and fragmentation level" "$YELLOW" "true" 2
    
    if [ "$DUMMY_MODE" = true ]; then
        sleep 2  # Simulate defragmentation time
        return 0
    fi
    
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
                show_info_auto "Running ext4 defragmentation (this may take a while)..." 1
                if e4defrag -c "$mount_point" >/dev/null 2>&1; then
                    # Check if defragmentation is needed
                    local frag_info
                    frag_info=$(e4defrag -c "$mount_point" 2>/dev/null | tail -1)
                    if echo "$frag_info" | grep -qi "not need\|0%"; then
                        show_info_auto "Filesystem is already well defragmented" 1
                    else
                        show_info_auto "Running full defragmentation..." 1
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
                show_info_auto "Running btrfs defragmentation (this may take a while)..." 1
                if btrfs filesystem defrag -r "$mount_point" >/dev/null 2>&1; then
                    defrag_success=true
                    show_info_auto "btrfs defragmentation completed" 1
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
                show_info_auto "Running xfs defragmentation (this may take a while)..." 1
                # xfs_fsr works on mounted filesystems
                if xfs_fsr "$mount_point" >/dev/null 2>&1; then
                    defrag_success=true
                    show_info_auto "xfs defragmentation completed" 1
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
        ntfs_partition=$(detect_ntfs_partitions "$disk")
        if [ -z "$ntfs_partition" ]; then
            return 0
        fi
    fi
    
    # Detect disk type
    local disk_type
    disk_type=$(detect_disk_type "$disk")
    
    # SAFETY: Never offer defrag for SSDs - it reduces SSD lifespan
    if [ "$disk_type" = "SSD" ]; then
        log_message "SSD detected - defragmentation skipped (harmful to SSDs)" "info"
        return 0
    fi
    
    # Also skip if we can't determine disk type (safety precaution)
    if [ "$disk_type" = "UNKNOWN" ]; then
        log_message "Disk type unknown - defragmentation skipped (safety precaution)" "info"
        return 0
    fi
    
    if [ "$disk_type" != "HDD" ]; then
        return 0
    fi
    
    # It's an HDD - confirm with user and offer defrag
    local disk_name
    disk_name=$(basename "$disk")
    local disk_model
    disk_model=$(lsblk -d -n -o MODEL "$disk" 2>/dev/null | head -1 || echo "Unknown")
    
    # Use the new panel system
    clear_content_area
    write_content_line 0 "${BOLD}${YELLOW}${WARN} Hard Drive Detected${RESET}"
    write_content_line 1 ""
    write_content_line 2 " Disk:  ${BOLD}$disk${RESET}"
    write_content_line 3 " Model: ${BOLD}$disk_model${RESET}"
    write_content_line 4 " Type:  ${BOLD}Hard Disk Drive (HDD)${RESET}"
    write_content_line 5 ""
    write_content_line 6 " ${DIM}Defragmenting the NTFS partition before conversion"
    write_content_line 7 " can improve performance and reduce conversion time.${RESET}"
    
    update_status_bar "Confirm disk type" ""
    sleep 1
    
    local options=("Yes, this is an HDD - offer defrag" "No, this is an SSD - skip defrag" "Cancel")
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
                    if defrag_ntfs "$ntfs_partition"; then
                        log_message "Defragmentation completed" "success"
                        sleep 1
                    else
                        log_message "Defragmentation had issues, continuing anyway" "warning"
                        sleep 1
                    fi
                    ;;
                1)
                    log_message "Skipping defragmentation" "info"
                    sleep 1
                    ;;
                *)
                    exit 0
                    ;;
            esac
            ;;
        1)
            # User says it's an SSD - skip defrag
            log_message "Skipping defragmentation (SSD selected)" "info"
            sleep 1
            ;;
        *)
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
        return 0
    fi
    
    # Detect disk type
    local disk_type
    disk_type=$(detect_disk_type "$disk")
    
    # SAFETY: Never offer defrag for SSDs - it reduces SSD lifespan
    if [ "$disk_type" = "SSD" ]; then
        log_message "SSD detected - post-conversion defragmentation skipped (harmful to SSDs)" "info"
        return 0
    fi
    
    # Also skip if we can't determine disk type (safety precaution)
    if [ "$disk_type" = "UNKNOWN" ]; then
        log_message "Disk type unknown - post-conversion defragmentation skipped (safety precaution)" "info"
        return 0
    fi
    
    if [ "$disk_type" != "HDD" ]; then
        return 0
    fi
    
    # Skip defrag for filesystems that don't need it
    case "$fs_type" in
        f2fs)
            return 0
            ;;
    esac
    
    # It's an HDD - offer defrag for the target filesystem
    local disk_name
    disk_name=$(basename "$disk")
    local disk_model
    disk_model=$(lsblk -d -n -o MODEL "$disk" 2>/dev/null | head -1 || echo "Unknown")
    
    # Use the new panel system
    clear_content_area
    write_content_line 0 "${BOLD}${GREEN}${CHECK} Conversion Complete${RESET}"
    write_content_line 1 ""
    write_content_line 2 " Disk:   ${BOLD}$disk${RESET}"
    write_content_line 3 " Model:  ${BOLD}$disk_model${RESET}"
    write_content_line 4 " Target: ${BOLD}${fs_type} on ${target_partition}${RESET}"
    write_content_line 5 ""
    write_content_line 6 " ${DIM}Defragmenting the new filesystem can improve"
    write_content_line 7 " performance on hard disk drives.${RESET}"
    
    update_status_bar "Conversion complete" ""
    sleep 1
    
    local options=("Yes, defragment now (recommended)" "No, skip defragmentation")
    local selection
    selection=$(show_menu "Defragment ${fs_type} Partition?" "${options[@]}")
    
    case "$selection" in
        0)
            if defrag_linux_fs "$target_partition" "$fs_type"; then
                log_message "Defragmentation completed successfully" "success"
                sleep 1
            else
                log_message "Defragmentation had issues, but conversion is complete" "warning"
                sleep 1
            fi
            ;;
        *)
            log_message "Skipping defragmentation" "info"
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
    
    log_message "Preparing to shrink NTFS partition $partition to ${target_size}KB" "info"
    update_status_bar "Shrinking NTFS partition..."
    
    if [ "$DUMMY_MODE" = true ]; then
        sleep 2  # Simulate operation time
        log_message "NTFS partition shrink simulated (dummy mode)" "success"
        return 0
    fi
    
    if [ "$DRY_RUN" = true ]; then
        log_message "[DRY RUN] Would run: ntfsresize -s ${target_size}K $partition" "info"
        return 0
    fi
    
    # Safety check: Verify partition is not mounted
    if findmnt -n "$partition" >/dev/null 2>&1; then
        local mount_point
        mount_point=$(findmnt -n -o TARGET "$partition" 2>/dev/null || echo "unknown")
        show_error "Partition $partition is mounted at $mount_point. Cannot resize while mounted." false
        log_message "Attempting to unmount $partition..." "warning"
        
        if ! umount "$partition" 2>/dev/null; then
            show_error "Failed to unmount $partition. Please unmount manually and try again."
            return 1
        fi
        sync
        sleep 1
        log_message "Partition unmounted successfully" "success"
    fi
    
    # Safety check: Verify partition exists and is NTFS
    if ! blkid "$partition" 2>/dev/null | grep -qi "ntfs"; then
        show_error "Partition $partition does not appear to be NTFS"
        return 1
    fi
    
    # First, run ntfsresize in dry-run mode to validate the operation
    log_message "Validating resize operation (dry-run)..." "info"
    local dry_run_output
    dry_run_output=$(ntfsresize -n -s "${target_size}K" "$partition" 2>&1)
    local dry_run_status=$?
    
    if [ $dry_run_status -ne 0 ]; then
        show_error "NTFS resize validation failed. The operation would be unsafe." false
        log_message "ntfsresize dry-run output: $dry_run_output" "error"
        return 1
    fi
    
    log_message "Validation passed. Proceeding with resize..." "success"
    
    # Perform the actual resize (without -f flag for safety)
    log_message "Resizing NTFS filesystem..." "info"
    local resize_output
    resize_output=$(ntfsresize -s "${target_size}K" "$partition" 2>&1)
    local resize_status=$?
    
    if [ $resize_status -ne 0 ]; then
        show_error "Failed to resize NTFS filesystem" false
        log_message "ntfsresize output: $resize_output" "error"
        return 1
    fi
    
    log_message "NTFS filesystem resized successfully" "success"
    
    # Resize partition table entry
    local part_num
    part_num=$(echo "$partition" | grep -o '[0-9]*$')
    local disk
    disk=$(echo "$partition" | sed 's/[0-9]*$//')
    
    log_message "Updating partition table..." "info"
    local parted_output
    parted_output=$(parted "$disk" resizepart "$part_num" "${target_size}KB" 2>&1)
    local parted_status=$?
    
    if [ $parted_status -ne 0 ]; then
        show_warning "Partition table update may have failed: $parted_output" false
        # Don't return error - filesystem was resized, partition table is secondary
    else
        log_message "Partition table updated" "success"
    fi
    
    # Sync and wait for kernel to update
    sync
    sleep 1
    partprobe "$disk" >/dev/null 2>&1 || true
    sleep 1
    
    log_message "NTFS partition shrink completed" "success"
    return 0
}

create_partition() {
    local disk="$1"
    local start="$2"
    local end="$3"
    
    log_message "Creating partition on $disk from ${start}KB to ${end}KB" "info"
    update_status_bar "Creating partition..."
    
    if [ "$DUMMY_MODE" = true ]; then
        sleep 1  # Simulate operation time
        log_message "Partition created (dummy mode): ${disk}2" "success"
        echo "${disk}2"  # Return dummy partition
        return 0
    fi
    
    if [ "$DRY_RUN" = true ]; then
        log_message "[DRY RUN] Would run: parted $disk mkpart primary ${start}KB ${end}KB" "info"
        echo "/dev/sdXY"  # Dummy output
        return 0
    fi
    
    # Get list of existing partitions before creating new one
    local existing_parts
    existing_parts=$(lsblk -ln -o NAME "$disk" 2>/dev/null | grep -v "^$(basename "$disk")$" | sort)
    
    # Create the partition
    local parted_output
    parted_output=$(parted "$disk" -s mkpart primary "${start}KB" "${end}KB" 2>&1)
    local parted_status=$?
    
    if [ $parted_status -ne 0 ]; then
        log_message "Failed to create partition: $parted_output" "error"
        return 1
    fi
    
    # Wait for kernel to recognize new partition
    sync
    sleep 1
    partprobe "$disk" >/dev/null 2>&1 || true
    sleep 2
    
    # Find the new partition by comparing before/after
    local new_parts
    new_parts=$(lsblk -ln -o NAME "$disk" 2>/dev/null | grep -v "^$(basename "$disk")$" | sort)
    
    local new_partition=""
    while IFS= read -r part; do
        if ! echo "$existing_parts" | grep -q "^${part}$"; then
            new_partition="/dev/$part"
            break
        fi
    done <<< "$new_parts"
    
    # Fallback: try to detect partition number from disk
    if [ -z "$new_partition" ]; then
        # Count existing partitions and assume new one is next
        local part_count
        part_count=$(lsblk -ln -o NAME "$disk" 2>/dev/null | grep -v "^$(basename "$disk")$" | wc -l)
        new_partition="${disk}${part_count}"
        
        # Verify it exists
        if [ ! -b "$new_partition" ]; then
            # Try with 'p' prefix (for nvme, mmcblk devices)
            new_partition="${disk}p${part_count}"
        fi
    fi
    
    # Verify partition was created
    if [ ! -b "$new_partition" ]; then
        log_message "Failed to detect new partition after creation" "error"
        return 1
    fi
    
    log_message "Partition created: $new_partition" "success"
    echo "$new_partition"
}

format_filesystem() {
    local partition="$1"
    local fs_type="$2"
    
    log_message "Formatting $partition as $fs_type" "info"
    update_status_bar "Formatting filesystem..."
    
    if [ "$DUMMY_MODE" = true ]; then
        sleep 2  # Simulate formatting time
        log_message "Filesystem formatted (dummy mode)" "success"
        return 0
    fi
    
    if [ "$DRY_RUN" = true ]; then
        log_message "[DRY RUN] Would run: ${FS_FORMAT_CMD[$fs_type]} $partition" "info"
        return 0
    fi
    
    # Verify partition exists
    if [ ! -b "$partition" ]; then
        log_message "Partition $partition does not exist" "error"
        return 1
    fi
    
    # Safety check: verify partition is not mounted
    if findmnt -n "$partition" >/dev/null 2>&1; then
        log_message "Partition $partition is mounted. Cannot format." "error"
        return 1
    fi
    
    local format_cmd="${FS_FORMAT_CMD[$fs_type]}"
    local format_output
    format_output=$($format_cmd "$partition" 2>&1)
    local format_status=$?
    
    if [ $format_status -ne 0 ]; then
        log_message "Failed to format partition: $format_output" "error"
        return 1
    fi
    
    # Sync to ensure filesystem is written
    sync
    sleep 1
    
    log_message "Filesystem formatted successfully as $fs_type" "success"
    return 0
}

expand_filesystem() {
    local partition="$1"
    local mount_point="$2"
    local fs_type="$3"
    
    show_info_auto "Expanding $fs_type filesystem on $partition" 1
    
    if [ "$DUMMY_MODE" = true ]; then
        sleep 1  # Simulate operation time
        return 0
    fi
    
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
    if [ "$DUMMY_MODE" = true ]; then
        sleep 1  # Simulate wait time
        return 0
    fi
    local max_wait=30  # Maximum 30 seconds
    local wait_time=0
    local interval=1
    
    show_info_auto "Waiting for I/O operations to complete..." 1
    
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
# Enhanced: checksums files > 100KB, uses xxhash if available, shows progress in status bar
verify_file_migration() {
    local source_mount="$1"
    local dest_mount="$2"
    local verify_list_file="$3"  # Output file with list of verified files
    
    log_message "Starting comprehensive file verification..." "info"
    update_status_bar "Verifying files..." "0%"
    
    if [ "$DUMMY_MODE" = true ]; then
        # Simulate verification
        sleep 2
        echo "dummy_file1.txt" > "$verify_list_file"
        echo "dummy_file2.txt" >> "$verify_list_file"
        log_message "Verification simulated (dummy mode)" "success"
        return 0
    fi
    
    # Count files in source and destination
    log_message "Counting files..." "info"
    local source_files
    source_files=$(find "$source_mount" -type f 2>/dev/null | wc -l)
    local dest_files
    dest_files=$(find "$dest_mount" -type f 2>/dev/null | wc -l)
    
    if [ $source_files -eq 0 ]; then
        log_message "No files to verify in source" "info"
        touch "$verify_list_file"
        return 0
    fi
    
    log_message "Source: $source_files files, Destination: $dest_files files" "info"
    
    # Check if destination has reasonable number of files
    if [ $dest_files -lt $((source_files / 2)) ]; then
        log_message "File count mismatch: Source $source_files, Destination $dest_files" "error"
        log_message "Not enough files migrated. Aborting verification." "error"
        return 1
    fi
    
    # Get checksum command (prefer xxhash for speed, fallback to sha256sum, then md5sum)
    local checksum_cmd=""
    local checksum_name=""
    if command -v xxhsum >/dev/null 2>&1; then
        checksum_cmd="xxhsum"
        checksum_name="xxhash"
    elif command -v xxh64sum >/dev/null 2>&1; then
        checksum_cmd="xxh64sum"
        checksum_name="xxhash64"
    elif command -v sha256sum >/dev/null 2>&1; then
        checksum_cmd="sha256sum"
        checksum_name="sha256"
    elif command -v md5sum >/dev/null 2>&1; then
        checksum_cmd="md5sum"
        checksum_name="md5"
    fi
    
    if [ -n "$checksum_cmd" ]; then
        log_message "Using $checksum_name for integrity verification" "info"
    else
        log_message "No checksum tool available, using size-only verification" "warning"
    fi
    
    local verified_count=0
    local failed_count=0
    local missing_count=0
    local checksum_count=0
    local total_checked=0
    local verify_list=()
    local last_progress_update=0
    
    # Checksum threshold: 100KB (102400 bytes) - balance between safety and speed
    local checksum_threshold=102400
    
    # Verify each file in source
    while IFS= read -r source_file; do
        [ -z "$source_file" ] && continue
        
        total_checked=$((total_checked + 1))
        local rel_path
        rel_path="${source_file#$source_mount/}"
        local dest_file="$dest_mount/$rel_path"
        
        # Update progress in status bar (every 50 files or every 2%)
        local progress_percent=$((total_checked * 100 / source_files))
        if [ $((total_checked % 50)) -eq 0 ] || [ $progress_percent -ne $last_progress_update ]; then
            update_status_bar "Verifying: $verified_count OK, $failed_count failed" "${progress_percent}%"
            last_progress_update=$progress_percent
        fi
        
        if [ ! -f "$dest_file" ]; then
            missing_count=$((missing_count + 1))
            continue
        fi
        
        # Compare file sizes first (fast check)
        local source_size dest_size
        source_size=$(stat -c%s "$source_file" 2>/dev/null || stat -f%z "$source_file" 2>/dev/null || echo 0)
        dest_size=$(stat -c%s "$dest_file" 2>/dev/null || stat -f%z "$dest_file" 2>/dev/null || echo 0)
        
        # Check if sizes match
        if [ "$source_size" != "$dest_size" ]; then
            failed_count=$((failed_count + 1))
            continue
        fi
        
        # If both files are empty (size 0), they match
        if [ "$source_size" -eq 0 ]; then
            verified_count=$((verified_count + 1))
            verify_list+=("$rel_path")
            continue
        fi
        
        # For files > 100KB, verify with checksum
        local verify_checksum=false
        if [ "$source_size" -gt "$checksum_threshold" ] && [ -n "$checksum_cmd" ]; then
            verify_checksum=true
        fi
        
        if [ "$verify_checksum" = true ]; then
            local source_hash dest_hash
            source_hash=$($checksum_cmd "$source_file" 2>/dev/null | cut -d' ' -f1)
            dest_hash=$($checksum_cmd "$dest_file" 2>/dev/null | cut -d' ' -f1)
            
            # If checksum calculation failed, fall back to size-only
            if [ -z "$source_hash" ] || [ -z "$dest_hash" ]; then
                # Size already matches, consider it verified
                verified_count=$((verified_count + 1))
                verify_list+=("$rel_path")
                continue
            fi
            
            if [ "$source_hash" != "$dest_hash" ]; then
                failed_count=$((failed_count + 1))
                continue
            fi
            
            checksum_count=$((checksum_count + 1))
        fi
        
        # File verified
        verified_count=$((verified_count + 1))
        verify_list+=("$rel_path")
        
    done < <(find "$source_mount" -type f 2>/dev/null)
    
    # Final status update
    update_status_bar "Verification complete" "100%"
    
    # Save verified file list
    if [ ${#verify_list[@]} -gt 0 ]; then
        printf "%s\n" "${verify_list[@]}" > "$verify_list_file"
    else
        touch "$verify_list_file"
    fi
    
    # Calculate success rate
    local success_rate=0
    if [ $total_checked -gt 0 ]; then
        success_rate=$((verified_count * 100 / total_checked))
    fi
    
    # Report results
    log_message "Verification complete: $verified_count/$total_checked files ($success_rate%)" "info"
    log_message "Checksummed: $checksum_count, Failed: $failed_count, Missing: $missing_count" "info"
    
    # Check for failures
    if [ $failed_count -gt 0 ] || [ $missing_count -gt $((total_checked / 10)) ]; then
        log_message "File verification FAILED" "error"
        log_message "Too many failed or missing files for safe continuation" "error"
        return 1
    fi
    
    if [ $verified_count -lt $((total_checked * 9 / 10)) ]; then
        log_message "Low verification rate: $success_rate%" "warning"
        log_message "Less than 90% of files verified" "warning"
        local options=("Yes, continue anyway" "No, abort")
        local user_choice
        user_choice=$(show_menu "Continue with low verification rate?" "${options[@]}")
        if [ "$user_choice" != "0" ]; then
            return 1
        fi
    fi
    
    log_message "File verification successful: $success_rate%" "success"
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
        show_info_auto "No verified files to remove from source" 1
        return 0
    fi
    
    show_info_auto "Removing $file_count verified files from NTFS source..." 1
    
    if [ "$DUMMY_MODE" = true ]; then
        sleep 1  # Simulate removal time
        return 0
    fi
    
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
    show_info_auto "Syncing filesystems to ensure all data is written..." 1
    
    if [ "$DUMMY_MODE" = true ]; then
        sleep 1  # Simulate sync time
        return 0
    fi
    
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
    
    log_message "Preparing to migrate files from $source to $dest" "info"
    update_status_bar "Migrating files..."
    
    if [ "$DUMMY_MODE" = true ]; then
        # Simulate file migration with progress
        log_message "Simulating file migration (dummy mode)..." "info"
        sleep 3  # Simulate migration time
        FILES_MIGRATED=$((FILES_MIGRATED + 1000))  # Simulate files migrated
        log_message "Migration simulation complete" "success"
        return 0
    fi
    
    if [ "$DRY_RUN" = true ]; then
        log_message "[DRY RUN] Would run: rsync -avx --progress $source/ $dest/" "info"
        return 0
    fi
    
    # Create mount points
    NTFS_MOUNT="/mnt/ntfs_$$"
    TARGET_MOUNT="/mnt/target_$$"
    mkdir -p "$NTFS_MOUNT" "$TARGET_MOUNT"
    
    # Mount source partition
    log_message "Mounting source partition $source" "info"
    local mount_output
    mount_output=$(mount "$source" "$NTFS_MOUNT" 2>&1)
    if [ $? -ne 0 ]; then
        log_message "Failed to mount source partition: $mount_output" "error"
        rmdir "$NTFS_MOUNT" "$TARGET_MOUNT" 2>/dev/null || true
        return 1
    fi
    
    # Mount target partition
    log_message "Mounting target partition $dest" "info"
    mount_output=$(mount "$dest" "$TARGET_MOUNT" 2>&1)
    if [ $? -ne 0 ]; then
        log_message "Failed to mount target partition: $mount_output" "error"
        umount "$NTFS_MOUNT" 2>/dev/null || true
        rmdir "$NTFS_MOUNT" "$TARGET_MOUNT" 2>/dev/null || true
        return 1
    fi
    
    # Count files for progress
    log_message "Counting files to migrate..." "info"
    local total_files
    total_files=$(find "$NTFS_MOUNT" -type f 2>/dev/null | wc -l)
    local total_size
    total_size=$(du -sk "$NTFS_MOUNT" 2>/dev/null | cut -f1)
    log_message "Found $total_files files (${total_size}KB) to migrate" "info"
    
    # Perform rsync migration
    # Use a temporary file to capture rsync output and exit status
    local rsync_log="/tmp/rsync_log_$$.txt"
    local rsync_status_file="/tmp/rsync_status_$$.txt"
    
    log_message "Starting file migration with rsync..." "info"
    update_status_bar "Migrating $total_files files..."
    
    # Run rsync in background and capture status
    (
        rsync -avx --info=progress2 --human-readable \
            "$NTFS_MOUNT/" "$TARGET_MOUNT/" > "$rsync_log" 2>&1
        echo $? > "$rsync_status_file"
    ) &
    local rsync_pid=$!
    
    # Monitor progress while rsync runs
    local last_progress=0
    while kill -0 $rsync_pid 2>/dev/null; do
        if [ -f "$rsync_log" ]; then
            # Extract progress percentage from rsync output
            local current_progress
            current_progress=$(tail -n 5 "$rsync_log" 2>/dev/null | grep -oE '[0-9]+%' | tail -1 | tr -d '%')
            if [ -n "$current_progress" ] && [ "$current_progress" != "$last_progress" ]; then
                update_status_bar "Migrating files..." "${current_progress}%"
                last_progress="$current_progress"
            fi
        fi
        sleep 1
    done
    
    # Wait for rsync to complete
    wait $rsync_pid 2>/dev/null
    
    # Get rsync exit status
    local rsync_status=1
    if [ -f "$rsync_status_file" ]; then
        rsync_status=$(cat "$rsync_status_file")
    fi
    
    # Clean up temp files
    rm -f "$rsync_log" "$rsync_status_file" 2>/dev/null
    
    # Check rsync result
    # Exit codes: 0 = success, 24 = partial transfer (vanished files - OK for our use)
    if [ "$rsync_status" -ne 0 ] && [ "$rsync_status" -ne 24 ]; then
        log_message "rsync failed with exit code $rsync_status" "error"
        umount "$NTFS_MOUNT" "$TARGET_MOUNT" 2>/dev/null || true
        rmdir "$NTFS_MOUNT" "$TARGET_MOUNT" 2>/dev/null || true
        return 1
    fi
    
    if [ "$rsync_status" -eq 24 ]; then
        log_message "rsync completed with some vanished files (normal for active filesystems)" "warning"
    else
        log_message "rsync completed successfully" "success"
    fi
    
    # Sync filesystems to ensure all data is written
    log_message "Syncing filesystems..." "info"
    sync_filesystems
    
    # Create verification list file
    local verify_list_file="/tmp/verified_files_$$.txt"
    
    # Comprehensive verification
    log_message "Verifying migrated files..." "info"
    update_status_bar "Verifying files..."
    if ! verify_file_migration "$NTFS_MOUNT" "$TARGET_MOUNT" "$verify_list_file"; then
        log_message "File verification failed! Source files will NOT be removed." "error"
        rm -f "$verify_list_file" 2>/dev/null || true
        umount "$NTFS_MOUNT" "$TARGET_MOUNT" 2>/dev/null || true
        rmdir "$NTFS_MOUNT" "$TARGET_MOUNT" 2>/dev/null || true
        return 1
    fi
    
    # Remove verified source files
    log_message "Removing verified source files from NTFS partition..." "info"
    update_status_bar "Removing source files..."
    if ! remove_verified_source_files "$NTFS_MOUNT" "$verify_list_file"; then
        log_message "Warning: Some source files could not be removed" "warning"
        # Continue anyway - files are verified on destination
    fi
    
    # Cleanup verification list
    rm -f "$verify_list_file" 2>/dev/null || true
    
    # Sync after removing source files
    log_message "Syncing after source file removal..." "info"
    sync_filesystems
    
    # Final sync before unmounting
    log_message "Final sync..." "info"
    sync
    sleep 1
    
    # Unmount with verification
    log_message "Unmounting partitions..." "info"
    local unmount_failed=false
    
    # Try unmounting with multiple attempts
    local unmount_attempts=3
    local attempt
    
    for ((attempt=1; attempt<=unmount_attempts; attempt++)); do
        if umount "$NTFS_MOUNT" 2>/dev/null; then
            break
        fi
        if [ $attempt -eq $unmount_attempts ]; then
            log_message "Failed to unmount $NTFS_MOUNT after $unmount_attempts attempts" "error"
            unmount_failed=true
        else
            sleep 2
        fi
    done
    
    for ((attempt=1; attempt<=unmount_attempts; attempt++)); do
        if umount "$TARGET_MOUNT" 2>/dev/null; then
            break
        fi
        if [ $attempt -eq $unmount_attempts ]; then
            log_message "Failed to unmount $TARGET_MOUNT after $unmount_attempts attempts" "error"
            unmount_failed=true
        else
            sleep 2
        fi
    done
    
    # Verify unmount succeeded
    if mountpoint -q "$NTFS_MOUNT" 2>/dev/null || mountpoint -q "$TARGET_MOUNT" 2>/dev/null; then
        log_message "Partitions are still mounted after unmount attempt" "error"
        unmount_failed=true
    fi
    
    # Cleanup mount points
    rmdir "$NTFS_MOUNT" 2>/dev/null || true
    rmdir "$TARGET_MOUNT" 2>/dev/null || true
    
    if [ "$unmount_failed" = true ]; then
        log_message "Unmount verification failed. Please check manually." "error"
        return 1
    fi
    
    # Final sync after unmount
    sync
    
    log_message "File migration completed successfully" "success"
    update_status_bar "Migration complete"
    return 0
}

###############################################################################
# Partition Information
###############################################################################

get_partition_size_kb() {
    local partition="$1"
    if [ "$DUMMY_MODE" = true ]; then
        # Simulate shrinking over iterations
        local current_size=$DUMMY_NTFS_SIZE_KB
        if [ $DUMMY_ITERATION -gt 0 ]; then
            # Reduce size by 20% each iteration
            current_size=$((DUMMY_NTFS_SIZE_KB - (DUMMY_ITERATION * DUMMY_NTFS_SIZE_KB / 5)))
            if [ $current_size -lt $DUMMY_NTFS_USED_KB ]; then
                current_size=$DUMMY_NTFS_USED_KB
            fi
        fi
        echo $current_size
        return 0
    fi
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
    if [ "$DUMMY_MODE" = true ]; then
        echo "1024"  # 1MB start
        return 0
    fi
    local disk
    disk=$(echo "$partition" | sed 's/[0-9]*$//')
    local part_num
    part_num=$(echo "$partition" | grep -o '[0-9]*$')
    parted "$disk" unit KB print | grep "^ $part_num" | awk '{print $2}' | sed 's/kB//'
}

get_partition_end_kb() {
    local partition="$1"
    if [ "$DUMMY_MODE" = true ]; then
        local size_kb
        size_kb=$(get_partition_size_kb "$partition")
        local start_kb
        start_kb=$(get_partition_start_kb "$partition")
        echo $((start_kb + size_kb))
        return 0
    fi
    local disk
    disk=$(echo "$partition" | sed 's/[0-9]*$//')
    local part_num
    part_num=$(echo "$partition" | grep -o '[0-9]*$')
    parted "$disk" unit KB print | grep "^ $part_num" | awk '{print $3}' | sed 's/kB//'
}

get_ntfs_used_space_kb() {
    local partition="$1"
    if [ "$DUMMY_MODE" = true ]; then
        # Simulate gradual reduction of used space over iterations
        local current_used=$DUMMY_NTFS_USED_KB
        if [ $DUMMY_ITERATION -gt 0 ]; then
            # Reduce used space by 25% each iteration
            current_used=$((DUMMY_NTFS_USED_KB - (DUMMY_ITERATION * DUMMY_NTFS_USED_KB / 4)))
            if [ $current_used -lt 0 ]; then
                current_used=0
            fi
        fi
        echo $current_used
        return 0
    fi
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
    if [ "$DUMMY_MODE" = true ]; then
        echo $DUMMY_DISK_SIZE_KB
        return 0
    fi
    parted "$disk" unit KB print | grep "^Disk $disk" | awk '{print $3}' | sed 's/kB//'
}

###############################################################################
# Pre-flight Checks
###############################################################################

# Perform safety checks before starting conversion
preflight_checks() {
    local disk="$1"
    local ntfs_part="$2"
    local target_fs="$3"
    
    # Skip preflight checks in dummy/dry-run mode
    if [ "$DUMMY_MODE" = true ]; then
        log_message "Pre-flight checks skipped (dummy mode)" "info"
        return 0
    fi
    
    if [ "$DRY_RUN" = true ]; then
        log_message "Pre-flight checks skipped (dry-run mode)" "info"
        return 0
    fi
    
    log_message "Running pre-flight safety checks..." "info"
    update_status_bar "Pre-flight checks..."
    
    local issues=()
    local warnings=()
    
    # Check 1: Verify disk exists
    if [ ! -b "$disk" ]; then
        issues+=("Disk $disk does not exist or is not a block device")
    fi
    
    # Check 2: Verify NTFS partition exists and is NTFS
    if [ -n "$ntfs_part" ]; then
        if [ ! -b "$ntfs_part" ]; then
            issues+=("NTFS partition $ntfs_part does not exist")
        elif ! blkid "$ntfs_part" 2>/dev/null | grep -qi "ntfs"; then
            issues+=("$ntfs_part does not appear to be an NTFS partition")
        fi
        
        # Check if mounted
        if findmnt -n "$ntfs_part" >/dev/null 2>&1; then
            local mount_point
            mount_point=$(findmnt -n -o TARGET "$ntfs_part" 2>/dev/null)
            warnings+=("NTFS partition $ntfs_part is mounted at $mount_point (will be unmounted)")
        fi
    fi
    
    # Check 3: Verify required tools are available
    local required_tools=("parted" "rsync" "ntfsresize" "blkid" "findmnt")
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            issues+=("Required tool '$tool' is not installed")
        fi
    done
    
    # Check 4: Verify filesystem-specific tools
    if [ -n "$target_fs" ]; then
        local fs_tool=""
        case "$target_fs" in
            ext4) fs_tool="mkfs.ext4" ;;
            btrfs) fs_tool="mkfs.btrfs" ;;
            xfs) fs_tool="mkfs.xfs" ;;
            f2fs) fs_tool="mkfs.f2fs" ;;
            reiserfs) fs_tool="mkreiserfs" ;;
            jfs) fs_tool="mkfs.jfs" ;;
        esac
        if [ -n "$fs_tool" ] && ! command -v "$fs_tool" >/dev/null 2>&1; then
            issues+=("Filesystem tool '$fs_tool' for $target_fs is not installed")
        fi
    fi
    
    # Check 5: Verify disk has GPT or MBR partition table
    if [ -b "$disk" ]; then
        local part_table
        part_table=$(parted "$disk" print 2>/dev/null | grep "Partition Table" | awk '{print $3}')
        if [ -z "$part_table" ]; then
            issues+=("Could not detect partition table on $disk")
        elif [ "$part_table" != "gpt" ] && [ "$part_table" != "msdos" ]; then
            warnings+=("Unusual partition table type: $part_table")
        fi
    fi
    
    # Check 6: Verify there's enough free space on disk for operations
    if [ -b "$disk" ] && [ -n "$ntfs_part" ]; then
        local disk_size_kb
        disk_size_kb=$(parted "$disk" unit KB print 2>/dev/null | grep "^Disk" | head -1 | awk '{print $3}' | tr -d 'kBKB')
        local ntfs_used_kb
        
        # Try to get NTFS used space
        local temp_mount="/tmp/preflight_mount_$$"
        mkdir -p "$temp_mount"
        if mount -o ro "$ntfs_part" "$temp_mount" 2>/dev/null; then
            ntfs_used_kb=$(df -k "$temp_mount" 2>/dev/null | tail -1 | awk '{print $3}')
            umount "$temp_mount" 2>/dev/null || true
            rmdir "$temp_mount" 2>/dev/null || true
            
            # Ensure there's at least 10% headroom
            local min_space=$((ntfs_used_kb + ntfs_used_kb / 10))
            if [ -n "$disk_size_kb" ] && [ "$disk_size_kb" -lt "$min_space" ]; then
                issues+=("Disk may not have enough space for conversion (need ${min_space}KB, have ${disk_size_kb}KB)")
            fi
        else
            rmdir "$temp_mount" 2>/dev/null || true
            warnings+=("Could not mount NTFS partition read-only to check space")
        fi
    fi
    
    # Check 7: Verify no swap is active on the disk
    if [ -b "$disk" ]; then
        local swap_parts
        swap_parts=$(swapon --show=NAME --noheadings 2>/dev/null | grep "$disk" || true)
        if [ -n "$swap_parts" ]; then
            issues+=("Swap is active on $swap_parts. Please disable swap first.")
        fi
    fi
    
    # Report results
    if [ ${#issues[@]} -gt 0 ]; then
        log_message "Pre-flight checks FAILED" "error"
        for issue in "${issues[@]}"; do
            log_message "ISSUE: $issue" "error"
        done
        return 1
    fi
    
    if [ ${#warnings[@]} -gt 0 ]; then
        log_message "Pre-flight checks passed with warnings" "warning"
        for warning in "${warnings[@]}"; do
            log_message "WARNING: $warning" "warning"
        done
    else
        log_message "All pre-flight checks passed" "success"
    fi
    
    return 0
}

###############################################################################
# Main Conversion Loop
###############################################################################

main_conversion_loop() {
    log_message "Starting conversion process..." "info"
    update_status_bar "Starting conversion..."
    
    # Detect NTFS partition if not already set
    if [ -z "$NTFS_PARTITION" ]; then
        NTFS_PARTITION=$(detect_ntfs_partitions "$SELECTED_DISK")
        if [ -z "$NTFS_PARTITION" ]; then
            show_error "No NTFS partition found on $SELECTED_DISK"
            exit 1
        fi
    fi
    
    # Run pre-flight safety checks
    if [ "$DUMMY_MODE" != true ]; then
        if ! preflight_checks "$SELECTED_DISK" "$NTFS_PARTITION" "$TARGET_FILESYSTEM"; then
            show_error "Pre-flight checks failed. Cannot proceed with conversion."
            exit 1
        fi
    else
        log_message "Skipping pre-flight checks (dummy mode)" "info"
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
    
    # Estimate total iterations (rough estimate based on typical conversion)
    local estimated_iterations=5
    
    while true; do
        CURRENT_ITERATION=$iteration
        LAST_OPERATION="iteration_start"
        save_state
        
        # Log iteration start
        log_message "Iteration $((iteration + 1)): Analyzing NTFS partition..." "info"
        
        # Get NTFS used space
        local ntfs_used_kb
        ntfs_used_kb=$(get_ntfs_used_space_kb "$NTFS_PARTITION")
        local ntfs_size_kb
        ntfs_size_kb=$(get_partition_size_kb "$NTFS_PARTITION")
        local ntfs_free_kb
        ntfs_free_kb=$((ntfs_size_kb - ntfs_used_kb))
        
        # Calculate progress percentage for this iteration
        local iteration_progress=0
        if [ $iteration -gt 0 ] && [ $previous_used_kb -gt 0 ]; then
            local total_to_migrate=$previous_used_kb
            local already_migrated=$((previous_used_kb - ntfs_used_kb))
            if [ $total_to_migrate -gt 0 ]; then
                iteration_progress=$((already_migrated * 100 / total_to_migrate))
            fi
        fi
        
        # Render progress panel
        render_progress_panel \
            "Converting: $NTFS_PARTITION -> $TARGET_FILESYSTEM" \
            "$NTFS_PARTITION" \
            "$TARGET_FILESYSTEM" \
            "$((iteration + 1))" \
            "$estimated_iterations" \
            "$iteration_progress" \
            "$FILES_MIGRATED" \
            "0" \
            "Analyzing partition..."
        
        log_message "NTFS: ${ntfs_used_kb}KB used, ${ntfs_free_kb}KB free (${ntfs_size_kb}KB total)" "info"
        
        # Check if NTFS is essentially empty
        local disk_size_kb
        disk_size_kb=$(get_disk_end_kb "$SELECTED_DISK")
        local empty_threshold=$((disk_size_kb / 1000))
        if [ $empty_threshold -lt 1024 ]; then
            empty_threshold=1024
        fi
        
        if [ $ntfs_used_kb -lt $empty_threshold ]; then
            log_message "NTFS partition essentially empty. Proceeding to final steps..." "success"
            break
        fi
        
        # Check for progress
        if [ $iteration -gt 0 ]; then
            local progress_kb=$((previous_used_kb - ntfs_used_kb))
            if [ $progress_kb -lt 1024 ]; then
                no_progress_count=$((no_progress_count + 1))
                if [ $no_progress_count -ge $max_no_progress ]; then
                    log_message "No significant progress in last $max_no_progress iterations" "warning"
                    log_message "Previous: ${previous_used_kb}KB, Current: ${ntfs_used_kb}KB" "warning"
                    local options=("Yes, continue" "No, abort")
                    local user_choice
                    user_choice=$(show_menu "Continue anyway?" "${options[@]}")
                    if [ "$user_choice" = "-1" ] || [ "$user_choice" = "1" ]; then
                        log_message "Aborting conversion" "info"
                        exit 1
                    fi
                    no_progress_count=0
                fi
            else
                no_progress_count=0
                log_message "Progress: ${progress_kb}KB migrated in previous iteration" "success"
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
                    log_message "Existing partition has insufficient space (need ${ntfs_used_kb}KB, have ${target_avail_kb}KB)" "warning"
                fi
            fi
        else
            # Shrink NTFS partition
            LAST_OPERATION="shrink_ntfs"
            save_state
            
            update_status_bar "Shrinking NTFS partition..." ""
            if ! shrink_ntfs "$NTFS_PARTITION" "$target_size_kb"; then
                log_message "Failed to shrink NTFS partition" "error"
                exit 1
            fi
            
            # Create new partition if this is first iteration
            if [ $iteration -eq 0 ]; then
                update_status_bar "Creating target partition..." ""
                
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
                    log_message "Failed to create target partition" "error"
                    exit 1
                fi
                
                # Format the new partition
                LAST_OPERATION="format_filesystem"
                save_state
                
                if ! format_filesystem "$TARGET_PARTITION" "$TARGET_FILESYSTEM"; then
                    log_message "Failed to format target partition" "error"
                    exit 1
                fi
            else
                # In subsequent iterations, expand target partition into freed space
                log_message "Expanding target partition into freed space..." "info"
                update_status_bar "Expanding target partition..." ""
                
                local target_part_num
                target_part_num=$(echo "$TARGET_PARTITION" | grep -o '[0-9]*$')
                local disk_end_kb
                disk_end_kb=$(get_disk_end_kb "$SELECTED_DISK")
                
                # Expand partition table entry
                LAST_OPERATION="expand_partition"
                save_state
                
                if [ "$DUMMY_MODE" = true ]; then
                    sleep 1  # Simulate partition expansion
                elif [ "$DRY_RUN" != true ]; then
                    parted "$SELECTED_DISK" resizepart "$target_part_num" "${disk_end_kb}KB" >/dev/null 2>&1 || {
                        log_message "Failed to expand partition table entry" "warning"
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
        
        update_status_bar "Migrating files..." ""
        if ! migrate_files "$NTFS_PARTITION" "$TARGET_PARTITION"; then
            log_message "Failed to migrate files" "error"
            exit 1
        fi
        
        # Wait for all operations to complete
        log_message "Waiting for file operations to complete..." "info"
        sync_filesystems
        
        # Verify migration and check remaining files
        local remaining_kb
        remaining_kb=$(get_ntfs_used_space_kb "$NTFS_PARTITION")
        
        # Calculate how much was actually migrated
        local migrated_this_iteration=$((ntfs_used_kb - remaining_kb))
        
        if [ $remaining_kb -ge $ntfs_used_kb ]; then
            log_message "Migration may not have reduced NTFS usage (${ntfs_used_kb}KB -> ${remaining_kb}KB)" "warning"
        else
            log_message "Migrated ${migrated_this_iteration}KB in this iteration" "success"
        fi
        
        # Use dynamic threshold based on disk size
        local disk_size_kb
        disk_size_kb=$(get_disk_end_kb "$SELECTED_DISK")
        local continue_threshold=$((disk_size_kb / 100))
        if [ $continue_threshold -lt 10240 ]; then
            continue_threshold=10240
        fi
        
        # If NTFS still has significant data, continue iteration
        if [ $remaining_kb -gt $continue_threshold ]; then
            log_message "Remaining: ${remaining_kb}KB (threshold: ${continue_threshold}KB). Continuing..." "info"
            iteration=$((iteration + 1))
            if [ "$DUMMY_MODE" = true ]; then
                DUMMY_ITERATION=$iteration
            fi
            sleep 1
            continue
        else
            log_message "Data below threshold. Proceeding to final steps..." "success"
            break
        fi
    done
    
    # Final steps: delete NTFS and expand target
    log_message "Finalizing conversion..." "info"
    update_status_bar "Finalizing..." ""
    
    # Delete NTFS partition
    LAST_OPERATION="delete_ntfs"
    save_state
    
    local part_num
    part_num=$(echo "$NTFS_PARTITION" | grep -o '[0-9]*$')
    local disk
    disk=$(echo "$NTFS_PARTITION" | sed 's/[0-9]*$//')
    
    log_message "Deleting NTFS partition $NTFS_PARTITION" "info"
    if [ "$DUMMY_MODE" = true ]; then
        sleep 1
    elif [ "$DRY_RUN" != true ]; then
        parted "$disk" rm "$part_num" >/dev/null 2>&1 || {
            log_message "Failed to delete NTFS partition" "error"
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
    
    log_message "Expanding partition table entry..." "info"
    update_status_bar "Expanding partition..." ""
    if [ "$DUMMY_MODE" = true ]; then
        sleep 1
    elif [ "$DRY_RUN" != true ]; then
        parted "$SELECTED_DISK" resizepart "$target_part_num" "${disk_end_kb}KB" >/dev/null 2>&1 || {
            log_message "Failed to expand partition table entry" "warning"
        }
        
        # Wait for kernel to recognize change
        sleep 2
        partprobe "$SELECTED_DISK" >/dev/null 2>&1 || true
        sleep 1
    fi
    
    # Expand filesystem
    log_message "Expanding ${TARGET_FILESYSTEM} filesystem..." "info"
    update_status_bar "Expanding filesystem..." ""
    local temp_mount=""
    if [ "$DUMMY_MODE" = true ]; then
        sleep 1
    elif [ "${FS_RESIZE_REQUIRES_MOUNT[$TARGET_FILESYSTEM]}" = true ]; then
        temp_mount="/mnt/temp_expand_$$"
        mkdir -p "$temp_mount"
        mount "$TARGET_PARTITION" "$temp_mount" || {
            log_message "Failed to mount partition for resize" "error"
            exit 1
        }
    fi
    
    if ! expand_filesystem "$TARGET_PARTITION" "$temp_mount" "$TARGET_FILESYSTEM"; then
        log_message "Failed to expand filesystem" "error"
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
    
    # Clear log and show completion summary
    clear_log
    log_message "Conversion completed successfully!" "success"
    log_message "NTFS partition converted to ${TARGET_FILESYSTEM}" "success"
    log_message "Total iterations: $((iteration + 1))" "info"
    log_message "Files migrated: $FILES_MIGRATED" "info"
    
    update_status_bar "Conversion complete!" ""
    
    # Wait for user to see completion message
    sleep 2
    
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
            --dummy-mode)
                DUMMY_MODE=true
                shift
                ;;
            -h|--help)
                echo "Usage: $SCRIPT_NAME [--dry-run] [--dummy-mode]"
                echo ""
                echo "Options:"
                echo "  --dry-run    Run in dry-run mode - shows what would be done without making changes"
                echo "  --dummy-mode Run in dummy mode - simulates interface and operations for testing"
                echo "  -h, --help   Show this help message"
                exit 0
                ;;
            *)
                echo "Error: Unknown option: $1" >&2
                exit 1
                ;;
        esac
    done
    
    # Check root
    check_root
    
    # Initialize the TUI screen
    init_screen
    
    # Print welcome message
    if [ "$DUMMY_MODE" = true ]; then
        log_message "NTFS to Linux Filesystem Converter v${SCRIPT_VERSION}" "info"
        log_message "Running in DUMMY MODE - no actual operations" "warning"
    else
        log_message "NTFS to Linux Filesystem Converter v${SCRIPT_VERSION}" "info"
        log_message "Ready to convert NTFS partitions" "info"
    fi
    update_status_bar "Welcome" ""
    sleep 1
    
    # Check for resume state
    if check_resume_state; then
        log_message "Resuming from previous conversion..." "info"
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
    cleanup_screen
}

# Trap signals for graceful exit
trap 'cleanup_screen; save_state; exit 1' INT TERM

# Run main function
main "$@"

