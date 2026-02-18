#!/usr/bin/env bash

# =============================================================================
# MODULE: 01_preflight.sh
# DESCRIPTION: Environment validation and global variable initialization.
# AUTHOR: Leonel Carrizo
# ============================================================================

set -euo pipefail

# Log file for debugging
readonly LOG_FILE='/tmp/install.log'
touch "$LOG_FILE"

# TRAP HANDLER
# Clear sensitive data from environment when script exits.
# This prevents passwords from remaining in memory or being visible in
# /proc/<pid>/environ after the script completes.
#
# TRIGGERED BY:
#   - Normal script completion (EXIT)
#   - Ctrl+C (INT)
#   - Kill signal (TERM)
trap 'clear_sensitive_data' EXIT INT TERM

clear_sensitive_data() {
    unset LUKS_PASSWORD ROOT_PASSWORD
}

# LOGGING FUNCTIONS
log(){
    local message
    message="$(date +'%Y-%m-%d %H:%M:%S') - $1"
    echo -e "$message" | tee -a "$LOG_FILE"
}

# ERROR HANDLING
error_exit() {
    log "ERROR $1" >&2
    exit 1
}

# ENVIRONMENT VALIDATIONS

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

# NETWORK CONNECTIVITY CHECK
# Verify internet connectivity before proceeding.
# Uses multiple fallback hosts to avoid false negatives from a single host.
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

# SYSTEM CLOCK SYNCHRONIZATION
# Set system time via NTP (Network Time Protocol).
update_clock() {
    log "Updating system clock via NTP..."
    timedatectl set-ntp true || error_exit "Failed to enable NTP"
    log "Clock synchronized: $(date)"
}

# SYSTEM CONFIGURATION

# Collect locale, keymap, and timezone settings.
get_locale_config() {
    log "Configuring locale and keyboard..."
    
    # Keyboard layout selection (default: us)
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
    
    # Locale selection (e.g., en_US.UTF-8)
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
    
    # Timezone selection (e.g., America/New_York)
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

# HOSTNAME CONFIGURATION
# Collect the system hostname.
# This is the name that will identify the machine on the network.
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

# SWAP CONFIGURATION
# Configure swap space (essential for hibernation, OOM prevention).
# Auto-calculation: <8GB RAM→2G, <16GB→4G, ≥16GB→8G.
# For hibernation, swap should equal or exceed RAM.
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
                # Auto-calculate based on RAM: <8GB→2G, <16GB→4G, ≥16GB→8G
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
                # Manual size: number followed by G or M
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

# DISK SELECTION
# Allow user to select which disk to install Arch Linux on.
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

# USER CREDENTIALS COLLECTION
# Collect username, root password, and LUKS passphrase.
# Passwords are not echoed, require confirmation, and cleared on exit.
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
    
    # LUKS encryption passphrase (required at boot)
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

# CONFIGURATION SUMMARY
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

# FINAL CONFIRMATION
# Require yes/no confirmation before proceeding.
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

# MAIN EXECUTION FLOW
# Orchestrates: clock sync → validation → config → disk → credentials → confirm
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
    
    # Disk selection with confirmation loop
    while $redo_disk; do
        get_disk_input
        show_summary
        read -rp "Confirm disk selection? [Y/n]: " disk_confirm
        disk_confirm=${disk_confirm:-y}
        if [[ "$disk_confirm" =~ ^[yY]$ ]]; then
            redo_disk=false
        fi
    done
    
    # User credentials with confirmation loop
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

# SCRIPT ENTRY POINT
# Run main() only if script is executed directly (not sourced).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi
