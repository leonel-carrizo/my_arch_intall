#!/usr/bin/env bash

# =============================================================================
# MODULE: 01_preflight.sh
# DESCRIPTION: Environment validation and global variable initialization.
# AUTHOR: Leonel Carrizo
# ============================================================================
#
# PURPOSE:
#   This is the first module in the Arch Linux installation framework.
#   It validates the system environment and collects all necessary configuration
#   values before proceeding to disk partitioning and installation.
#
# WHAT IT DOES:
#   - Validates UEFI boot mode
#   - Checks internet connectivity (with fallback hosts)
#   - Synchronizes system clock via NTP
#   - Collects system configuration (locale, keymap, timezone)
#   - Collects hostname
#   - Collects swap preferences
#   - Collects disk selection
#   - Collects user credentials (username, root password, LUKS passphrase)
#   - Displays summary and requires confirmation before proceeding
#
# USAGE:
#   Run this script from an Arch Linux live environment (archiso).
#   Must be run as root.
#
# EXIT CODES:
#   0   - Success
#   1   - Error (UEFI not detected, no internet, invalid input, etc.)
#
# ENVIRONMENT VARIABLES EXPORTED (for use by subsequent modules):
#   TARGET_DISK      - The disk device to install to (e.g., /dev/nvme0n1)
#   TARGET_USER     - The username for the regular user account
#   TARGET_HOSTNAME - The system hostname
#   KEYMAP          - Keyboard layout (e.g., us, de, es)
#   LOCALE          - Locale setting (e.g., en_US.UTF-8)
#   TZONE           - Timezone (e.g., America/New_York)
#   SWAP_SIZE       - Swap size (e.g., 8G, 4G, or 0 for none)
#   LUKS_PASSWORD   - Passphrase for LUKS2 encryption
#   ROOT_PASSWORD   - Root user password
#
# SECURITY NOTES:
#   - Sensitive data (passwords) are cleared from memory on script exit
#   - Use 'trap' to ensure cleanup even on unexpected termination
#   - Passwords are never logged to file
#
# =============================================================================

set -euo pipefail

# Log file location - all non-sensitive operations are logged here
# This helps with debugging if something goes wrong during installation
readonly LOG_FILE='/tmp/install.log'
touch "$LOG_FILE"

# =============================================================================
# TRAP HANDLER
# =============================================================================
# Clear sensitive data from environment when script exits.
# This prevents passwords from remaining in memory or being visible in
# /proc/<pid>/environ after the script completes.
#
# TRIGGERED BY:
#   - Normal script completion (EXIT)
#   - Ctrl+C (INT)
#   - Kill signal (TERM)
# =============================================================================
trap 'clear_sensitive_data' EXIT INT TERM

clear_sensitive_data() {
    unset LUKS_PASSWORD ROOT_PASSWORD
}

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================
# Log messages to both console and log file with timestamp.
# All logged messages include ISO 8601 timestamp for traceability.
#
# Arguments:
#   $1 - The message to log
# =============================================================================
log(){
    local message
    message="$(date +'%Y-%m-%d %H:%M:%S') - $1"
    echo -e "$message" | tee -a "$LOG_FILE"
}

# =============================================================================
# ERROR HANDLING
# =============================================================================
# Log error message and exit with failure code.
# Called when critical errors occur that prevent installation.
#
# Arguments:
#   $1 - The error message to display
# =============================================================================
error_exit() {
    log "ERROR $1" >&2
    exit 1
}

# =============================================================================
# ENVIRONMENT VALIDATIONS
# =============================================================================

# Verify system booted in UEFI mode.
# Arch Linux requires UEFI for modern installations.
# The existence of /sys/firmware/efi/ indicates UEFI boot.
check_uefi() {
    log "Checking UEFI mode..."
    if [ ! -d "/sys/firmware/efi/" ]; then
        error_exit "System is not booted in UEFI mode. \
Initialization cannot proceed with system-boot."
    fi
    log "UEFI mode detected."
}

# =============================================================================
# NETWORK CONNECTIVITY CHECK
# =============================================================================
# Verify internet connectivity before proceeding.
# Uses multiple fallback hosts to avoid false negatives from a single host.
# Recursively retries if no connection is available.
#
# Note: Uses archlinux.org, google.com, and cloudflare.com as test targets.
# These are reliable, globally distributed hosts.
# =============================================================================
check_internet() {
    log "Checking internet connectivity..."
    local hosts=("archlinux.org" "google.com" "cloudflare.com")
    local connected=false
    
    for host in "${hosts[@]}"; do
        if ping -c 1 "$host" &>/dev/null; then
            connected=true
            break
        fi
    done
    
    if [ "$connected" = false ]; then
        log "Internet unreachable. Please configure your network (use 'iwctl' for WiFi)."
        echo "Press Enter to retry or Ctrl+C to abort."
        read -r
        check_internet
        return
    fi
    log "Internet connection established."
}

# =============================================================================
# SYSTEM CLOCK SYNCHRONIZATION
# =============================================================================
# Set system time via NTP (Network Time Protocol).
# Critical for:
#   - SSL/TLS certificate validation
#   - Package manager operations
#   - Filesystem integrity
# =============================================================================
update_clock() {
    log "Updating system clock via NTP..."
    timedatectl set-ntp true || error_exit "Failed to enable NTP"
    log "Clock synchronized: $(date)"
}

# =============================================================================
# SYSTEM CONFIGURATION
# =============================================================================

# Collect locale, keyboard layout, and timezone settings.
# These are essential for proper system operation and localization.
#
# KEYMAP:   Keyboard layout (affects console and TTY)
# LOCALE:   Language and character encoding settings
# TZONE:    System timezone for clock and logging
get_locale_config() {
    log "Configuring locale and keyboard..."
    
    # Keyboard layout selection
    # Default is 'us' which is universally available
    while true; do
        echo "Available keymaps: $(ls /usr/share/kbd/keymaps/**/*.map.gz 2>/dev/null | sed 's|.*/||;s|\.map.gz||' | head -20)..."
        read -rp "Enter keyboard layout (default: us): " KEYMAP
        KEYMAP=${KEYMAP:-us}
        if [ -f "/usr/share/kbd/keymaps/**/*.map.gz" ] || [ "$KEYMAP" = "us" ]; then
            export KEYMAP
            log "Keyboard layout set to: $KEYMAP"
            break
        else
            echo "Invalid keymap. Try again."
        fi
    done
    
    # Locale selection
    # Format: language_TERRITORY.encoding (e.g., en_US.UTF-8)
    # Only UTF-8 encodings are supported in modern Arch Linux
    while true; do
        read -rp "Enter locale (default: en_US.UTF-8): " LOCALE
        LOCALE=${LOCALE:-en_US.UTF-8}
        if [[ "$LOCALE" =~ ^[a-z]{2}_[A-Z]{2}\.UTF-8$ ]]; then
            export LOCALE
            log "Locale set to: $LOCALE"
            break
        else
            echo "Invalid locale format. Use like: en_US.UTF-8"
        fi
    done
    
    # Timezone selection
    # Must be a valid timezone file under /usr/share/zoneinfo/
    # Format: Region/City (e.g., America/New_York, Europe/London)
    while true; do
        read -rp "Enter timezone (default: America/New_York): " TZONE
        TZONE=${TZONE:-America/New_York}
        if [ -f "/usr/share/zoneinfo/$TZONE" ]; then
            export TZONE
            log "Timezone set to: $TZONE"
            break
        else
            echo "Invalid timezone. Try again (e.g., Europe/London, Asia/Tokyo)."
        fi
    done
}

# =============================================================================
# HOSTNAME CONFIGURATION
# =============================================================================
# Collect the system hostname.
# This is the name that will identify the machine on the network.
#
# VALIDATION RULES:
#   - Must start and end with alphanumeric character
#   - Can contain hyphens and underscores in the middle
#   - Single character names are allowed
# =============================================================================
get_hostname_config() {
    while true; do
        read -rp "Enter hostname: " HOSTNAME
        if [[ "$HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*[a-zA-Z0-9]$|^[a-zA-Z0-9]$ ]]; then
            export TARGET_HOSTNAME="$HOSTNAME"
            log "Hostname set to: $TARGET_HOSTNAME"
            break
        else
            echo "Invalid hostname. Use alphanumeric characters, hyphens, or underscores."
        fi
    done
}

# =============================================================================
# SWAP CONFIGURATION
# =============================================================================
# Configure swap space - essential for:
#   - Hibernation (suspend to disk)
#   - Memory overcommit handling
#   - Preventing OOM (Out of Memory) kills
#
# AUTO CALCULATION:
#   RAM < 8GB  -> 2GB swap
#   RAM < 16GB -> 4GB swap
#   RAM >= 16GB -> 8GB swap
#
# NOTE: These are conservative recommendations. For hibernate support,
# swap should be at least equal to RAM size.
# =============================================================================
get_swap_config() {
    while true; do
        echo "Swap options: "
        echo "  1) Calculate automatically (based on RAM size)"
        echo "  2) Fixed size (e.g., 8G)"
        echo "  3) No swap (not recommended)"
        read -rp "Choose swap size [1]: " SWAP_CHOICE
        SWAP_CHOICE=${SWAP_CHOICE:-1}
        
        case "$SWAP_CHOICE" in
            1)
                # Auto-calculate based on available RAM
                local ram_kb
                ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
                local ram_gb=$((ram_kb / 1024 / 1024))
                if [ "$ram_gb" -lt 8 ]; then
                    export SWAP_SIZE="2G"
                elif [ "$ram_gb" -lt 16 ]; then
                    export SWAP_SIZE="4G"
                else
                    export SWAP_SIZE="8G"
                fi
                log "Auto-calculated swap size: $SWAP_SIZE"
                break
                ;;
            2)
                # Manual size specification
                # Format: number followed by G (gigabytes) or M (megabytes)
                read -rp "Enter swap size (e.g., 8G, 4G): " SWAP_SIZE
                if [[ "$SWAP_SIZE" =~ ^[0-9]+[GM]$ ]]; then
                    export SWAP_SIZE
                    log "Swap size set to: $SWAP_SIZE"
                    break
                else
                    echo "Invalid format. Use like: 8G or 4G"
                fi
                ;;
            3)
                # No swap - useful for systems with plenty of RAM
                # or when planning to use zram (compressed RAM disk) instead
                export SWAP_SIZE="0"
                log "Swap disabled"
                break
                ;;
            *)
                echo "Invalid option. Choose 1, 2, or 3."
                ;;
        esac
    done
}

# =============================================================================
# DISK SELECTION
# =============================================================================
# Allow user to select which disk to install Arch Linux on.
#
# INTERACTIVE FEATURES:
#   - Lists all available disks with size and model info
#   - 'r' refreshes the disk list
#   - 'b' goes back to previous step
#   - Validates that the selected disk exists in /dev/
#
# WARNING: This will ERASE all data on the selected disk!
# =============================================================================
get_disk_input() {
    while true; do
        echo "--- Available Disks ---"
        if ! lsblk -dno NAME,SIZE,MODEL 2>/dev/null | grep -v "loop"; then
            error_exit "Failed to list available disks."
        fi
        echo "-----------------------"
        echo "Press 'b' to go back, 'r' to refresh the list."
        read -rp "Enter the disk name to use (e.g., nvme0n1, sda): " DISK_NAME
        
        case "$DISK_NAME" in
            b|B)
                return
                ;;
            r|R)
                continue
                ;;
        esac
        
        if [ -b "/dev/$DISK_NAME" ]; then
            export TARGET_DISK="/dev/$DISK_NAME"
            log "Target disk set to $TARGET_DISK"
            break
        else
            echo "Invalid disk: /dev/$DISK_NAME not found. Try again."
        fi
    done
}

# =============================================================================
# USER CREDENTIALS COLLECTION
# =============================================================================
# Collect all authentication information:
#   1. Username  - Regular user account (used for daily tasks)
#   2. Root password - Administrator account (full system access)
#   3. LUKS passphrase - Disk encryption password (required at boot)
#
# VALIDATION RULES:
#   Username: Must start with lowercase letter or underscore,
#             can contain lowercase letters, numbers, underscores, hyphens
#
# SECURITY:
#   - Passwords are never echoed to the screen (-s flag)
#   - Passwords are cleared from memory on script exit
#   - Confirmation is required to prevent typos
# =============================================================================
get_user_credentials() {
    # Username collection
    while true; do
        echo "--- User Configuration (Press 'b' to go back) ---"
        read -rp "Enter new username: " USERNAME
        
        if [[ "$USERNAME" =~ ^[bB]$ ]]; then
            return
        fi
        
        if [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
            export TARGET_USER="$USERNAME"
            log "User set to: $TARGET_USER"
            break 
        else
            echo "Invalid username. Use lowercase, numbers, and underscores/hyphen only."
        fi
    done
    
    # Root password collection
    while true; do
        echo "--- Root Password (Press 'b' to go back) ---"
        read -rsp "Enter root password: " ROOT_PASS1
        echo
        if [[ "$ROOT_PASS1" =~ ^[bB]$ ]]; then
            return
        fi
        read -rsp "Confirm root password: " ROOT_PASS2
        echo
        if [ "$ROOT_PASS1" = "$ROOT_PASS2" ] && [ -n "$ROOT_PASS1" ]; then
            export ROOT_PASSWORD="$ROOT_PASS1"
            log "Root password set."
            break 
        else
            echo "Passwords do not match or are empty. Try again."
        fi
    done
    
    # LUKS encryption passphrase
    # This password encrypts the root partition and is required at every boot
    while true; do
        echo "--- LUKS Encryption (Press 'b' to go back) ---"
        read -rsp "Enter LUKS2 encryption passphrase: " PASS1
        echo
        if [[ "$PASS1" =~ ^[bB]$ ]]; then
            return
        fi
        read -rsp "Confirm passphrase: " PASS2
        echo
        if [ "$PASS1" = "$PASS2" ] && [ -n "$PASS1" ]; then
            export LUKS_PASSWORD="$PASS1"
            log "LUKS passphrase set."
            break 
        else
            echo "Passwords do not match or are empty. Try again."
        fi
    done
}

# =============================================================================
# CONFIGURATION SUMMARY
# =============================================================================
# Display all collected configuration values for review.
# Called multiple times throughout the process for confirmation.
# =============================================================================
show_summary() {
    echo
    echo "========================================="
    echo "         CONFIGURATION SUMMARY          "
    echo "========================================="
    echo "  Hostname:      $TARGET_HOSTNAME"
    echo "  Locale:        $LOCALE"
    echo "  Keymap:        $KEYMAP"
    echo "  Timezone:      $TZONE"
    echo "  Disk:          $TARGET_DISK"
    echo "  User:          $TARGET_USER"
    echo "  Swap:          $SWAP_SIZE"
    echo "========================================="
    echo
}

# =============================================================================
# FINAL CONFIRMATION
# =============================================================================
# Require explicit yes/no confirmation before proceeding.
# If user declines, the entire configuration process restarts.
#
# This prevents accidental installations with wrong settings.
# =============================================================================
get_confirmation() {
    local confirm
    while true; do
        read -rp "Proceed with these settings? [Y/n]: " confirm
        confirm=${confirm:-y}
        
        case "$confirm" in
            y|Y)
                return 0
                ;;
            n|N)
                log "Configuration rejected. Restarting..."
                main
                return
                ;;
            *)
                echo "Please enter y or n."
                ;;
        esac
    done
}

# =============================================================================
# MAIN EXECUTION FLOW
# =============================================================================
# Orchestrates the preflight process in logical order:
#
# 1. Clock sync (must be first for SSL/package operations)
# 2. Environment validation (UEFI, internet)
# 3. System configuration (locale, hostname, swap)
# 4. Disk selection with confirmation
# 5. User credentials with confirmation
# 6. Final confirmation
# 7. Clear sensitive data and exit
# =============================================================================
main() {
    update_clock
    log "Starting Pre-flight Module"
    check_uefi
    check_internet
    get_locale_config
    get_hostname_config
    get_swap_config
    
    local redo_disk=true
    local redo_creds=true
    
    # Disk selection with its own confirmation loop
    # Allows user to go back and change disk if they selected wrong one
    while $redo_disk; do
        get_disk_input
        show_summary
        read -rp "Confirm disk selection? [Y/n]: " disk_confirm
        disk_confirm=${disk_confirm:-y}
        if [[ "$disk_confirm" =~ ^[yY]$ ]]; then
            redo_disk=false
        fi
    done
    
    # User credentials with separate confirmation
    while $redo_creds; do
        get_user_credentials
        show_summary
        read -rp "Confirm user credentials? [Y/n]: " cred_confirm
        cred_confirm=${cred_confirm:-y}
        if [[ "$cred_confirm" =~ ^[yY]$ ]]; then
            redo_creds=false
        fi
    done
    
    show_summary
    get_confirmation
    log "Pre-flight complete. Environment is ready for Step 2."
    clear_sensitive_data
}

# =============================================================================
# SCRIPT ENTRY POINT
# =============================================================================
# Only run main() if script is executed directly (not sourced).
# This allows other scripts to source this file and use its functions.
# =============================================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi
