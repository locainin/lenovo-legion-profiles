#!/usr/bin/env bash

set -euo pipefail

# Resolve paths relative to the repo so the script can run from anywhere
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Track the source files that will be copied into system locations
source_script="$repo_root/legion-fnq-override.sh"
source_unit="$repo_root/systemd/legion-fnq-override.service"
# These are the live paths systemd and the user machine will use
target_script="/usr/local/sbin/legion-fnq-override.sh"
target_unit="/etc/systemd/system/legion-fnq-override.service"

log() {
    # Keep normal installer messages on stdout
    printf '%s\n' "$*"
}

die() {
    # Print fatal errors to stderr so failures are easy to spot
    printf '%s\n' "$*" >&2
    exit 1
}

require_command() {
    local cmd="$1"

    # Stop before doing partial work when a required tool is missing
    if ! command -v "$cmd" >/dev/null 2>&1; then
        die "Error: $cmd not found"
    fi
}

run_as_root() {
    # Reuse the current shell when already running as root
    if ((EUID == 0)); then
        "$@"
        return
    fi

    # Fall back to sudo for system paths and service control
    sudo "$@"
}

confirm() {
    local prompt="$1"
    local reply

    # Use a strict yes-only confirmation before touching system files
    read -r -p "$prompt [y/N]: " reply
    [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

choose_action() {
    local reply

    # Print the menu to stderr so command substitution only captures the result
    printf '\n' >&2
    printf '+----------------------------------------------+\n' >&2
    printf '| Lenovo Legion Fn+Q Override Installer        |\n' >&2
    printf '+----------------------------------------------+\n' >&2
    printf '| 1) Install or update the script and service  |\n' >&2
    printf '| 2) Uninstall and remove installed files      |\n' >&2
    printf '+----------------------------------------------+\n' >&2
    printf '\n' >&2
    read -r -p 'Select an option [1-2]: ' reply >&2

    # Accept both the menu numbers and explicit action names
    case "$reply" in
        1|install) printf '%s\n' "install" ;;
        2|uninstall) printf '%s\n' "uninstall" ;;
        *) die "Error: invalid selection" ;;
    esac
}

install_files() {
    require_command "systemctl"
    require_command "install"

    # Refuse to install from a partial checkout
    [[ -f "$source_script" ]] || die "Error: missing $source_script"
    [[ -f "$source_unit" ]] || die "Error: missing $source_unit"

    if ! confirm "Install or update the script and systemd unit?"; then
        log "Aborted"
        return
    fi

    # Copy the current repo version into the live system paths
    run_as_root install -D -m 0755 "$source_script" "$target_script"
    run_as_root install -D -m 0644 "$source_unit" "$target_unit"
    # Make systemd notice unit changes before service control
    run_as_root systemctl daemon-reload
    # Ensure the service starts at boot
    run_as_root systemctl enable legion-fnq-override.service
    # Replace any already running old process with the new script copy
    run_as_root systemctl restart legion-fnq-override.service

    log "Installed $target_script"
    log "Installed $target_unit"
    log "Service enabled and restarted"
}

uninstall_files() {
    require_command "systemctl"
    require_command "rm"

    if ! confirm "Stop and remove the installed script and systemd unit?"; then
        log "Aborted"
        return
    fi

    # Stop the service first so systemd releases the installed script
    run_as_root systemctl disable --now legion-fnq-override.service || true
    # Remove the installed files without touching the repo copy
    run_as_root rm -f "$target_script"
    run_as_root rm -f "$target_unit"
    # Reload so systemd drops the removed unit from memory
    run_as_root systemctl daemon-reload

    log "Removed $target_script"
    log "Removed $target_unit"
    log "Service disabled"
}

# The installer expects sudo when it is not started as root
require_command "sudo"

# Allow non-interactive usage for scripted installs
action="${1:-}"

if [[ -z "$action" ]]; then
    action=$(choose_action)
fi

# Dispatch the selected action
case "$action" in
    install)
        install_files
        ;;
    uninstall)
        uninstall_files
        ;;
    *)
        die "Usage: $0 [install|uninstall]"
        ;;
esac
