#!/usr/bin/env bash

set -u -o pipefail

# Allow test runs or custom installs to point at a different sysfs path
pf="${PF_PATH:-/sys/firmware/acpi/platform_profile}"
# The kernel exposes the supported profile names in the sibling choices file
choicesfile="${PF_CHOICES_PATH:-${pf}_choices}"
# Store the last managed profile name so restarts can resume the cycle cleanly
statefile="${STATEFILE:-/var/lib/legion-fnq-state}"
# Ignore the modify event that comes from the script's own write
self_write_ignore_ms="${SELF_WRITE_IGNORE_MS:-80}"
# Fold close-together firmware events into one key press
event_debounce_ms="${EVENT_DEBOUNCE_MS:-120}"

# Cache the kernel-exposed profile names so lookups stay simple
declare -a available_profiles=()
# Build the logical Fn+Q cycle from the names the current kernel supports
declare -a cycle_profiles=()

# Start from balanced until live state is loaded below
state=1
# Track the last userspace write so the loop does not react to itself
last_write_ms=0
# Track the last accepted event so firmware bursts can be collapsed
last_event_ms=0

log() {
    # Send service messages to stderr so journald records them as logs
    printf '%s\n' "$*" >&2
}

require_command() {
    local cmd="$1"

    # Fail early when a runtime dependency is missing
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log "Error: $cmd not found"
        exit 1
    fi
}

require_path() {
    local path="$1"
    local label="$2"

    # The service cannot do anything useful without the sysfs files
    if [[ ! -e "$path" ]]; then
        log "Error: $label does not exist at $path"
        exit 1
    fi
}

load_available_profiles() {
    local choices_raw

    # The kernel exports supported names as a space-separated list
    choices_raw=$(<"$choicesfile")
    # Split the list once so later checks can stay array-based
    read -r -a available_profiles <<< "$choices_raw"

    if ((${#available_profiles[@]} == 0)); then
        log "Error: no platform profiles were reported by $choicesfile"
        exit 1
    fi
}

have_profile() {
    local wanted="$1"
    local profile

    # Match exact profile names so old and new kernels stay distinct
    for profile in "${available_profiles[@]}"; do
        if [[ "$profile" == "$wanted" ]]; then
            return 0
        fi
    done

    return 1
}

append_cycle_profile() {
    local candidate="$1"
    local existing

    # Skip names the running kernel does not support
    if ! have_profile "$candidate"; then
        return
    fi

    # Skip duplicates when old and new naming overlap
    for existing in "${cycle_profiles[@]}"; do
        if [[ "$existing" == "$candidate" ]]; then
            return
        fi
    done

    cycle_profiles+=("$candidate")
}

build_cycle_profiles() {
    cycle_profiles=()

    # Quiet and balanced are stable across the old and new kernel mappings
    append_cycle_profile "low-power"
    append_cycle_profile "balanced"

    # New kernels use performance for red and max-power for purple
    if have_profile "max-power"; then
        append_cycle_profile "performance"
        append_cycle_profile "max-power"
    else
        # Old kernels used balanced-performance for red and performance for purple
        append_cycle_profile "balanced-performance"
        append_cycle_profile "performance"
    fi

    # Refuse to run if the machine exposes an unexpected layout
    if ((${#cycle_profiles[@]} < 3)); then
        log "Error: unsupported profile set: ${available_profiles[*]}"
        exit 1
    fi
}

state_to_profile() {
    local wanted_state="$1"

    # Convert the saved numeric position back into a kernel profile name
    if [[ "$wanted_state" =~ ^[0-9]+$ ]] && ((wanted_state >= 0 && wanted_state < ${#cycle_profiles[@]})); then
        printf '%s\n' "${cycle_profiles[$wanted_state]}"
        return
    fi

    # Balanced is the safest fallback when state is out of range
    printf '%s\n' "balanced"
}

profile_to_state() {
    local wanted_profile="$1"
    local index

    # Find the current profile inside the active logical cycle
    for index in "${!cycle_profiles[@]}"; do
        if [[ "${cycle_profiles[$index]}" == "$wanted_profile" ]]; then
            printf '%s\n' "$index"
            return
        fi
    done

    printf '%s\n' "-1"
}

persist_state() {
    local profile_name

    # Save profile names instead of old numeric slots so ABI changes are safer
    profile_name=$(state_to_profile "$state")
    printf '%s\n' "$profile_name" > "$statefile"
}

load_initial_state() {
    local current_profile
    local current_state
    local saved_profile
    local saved_state

    # Read the live profile first so restarts stay aligned with the machine
    current_profile=$(<"$pf")
    current_state=$(profile_to_state "$current_profile")

    # Prefer the live sysfs value when it matches the managed cycle
    if ((current_state >= 0)); then
        state="$current_state"
        persist_state
        return
    fi

    if [[ -f "$statefile" ]]; then
        saved_profile=$(<"$statefile")
        saved_state=$(profile_to_state "$saved_profile")

        # This keeps custom mode from resetting the cycle position on restart
        if ((saved_state >= 0)); then
            state="$saved_state"
            return
        fi
    fi

    # Fall back to balanced when neither sysfs nor the state file can be mapped
    state=$(profile_to_state "balanced")
    persist_state
}

write_profile() {
    local target="$1"

    # Log write failures instead of silently drifting out of sync
    if ! printf '%s\n' "$target" > "$pf"; then
        log "Error: failed to write profile '$target' to $pf"
        return 1
    fi

    # Mark the write time so the next inotify event can be ignored
    last_write_ms=$(date +%s%3N)
    last_event_ms="$last_write_ms"
    # Keep the persisted state aligned with the last successful write
    persist_state
    return 0
}

# Verify runtime dependencies before the long-lived loop starts
require_command "inotifywait"
require_path "$pf" "platform_profile"
require_path "$choicesfile" "platform_profile_choices"

# Create the state directory if the install did not make it yet
install -d -m 0755 "$(dirname "$statefile")"

# Build the active profile cycle from the running kernel view
load_available_profiles
build_cycle_profiles
load_initial_state

log "Watching $pf with cycle: ${cycle_profiles[*]}"

# React to firmware profile changes as Fn+Q presses
while IFS= read -r _; do
    local_now_ms=$(date +%s%3N)

    # Ignore the modify event caused by the last userspace write
    delta_write=$((local_now_ms - last_write_ms))
    if ((delta_write < self_write_ignore_ms)); then
        continue
    fi

    # Fold repeated firmware events into a single Fn+Q press
    delta_event=$((local_now_ms - last_event_ms))
    if ((delta_event < event_debounce_ms)); then
        continue
    fi

    # Advance one step in the managed 4-slot cycle
    state=$(((state + 1) % ${#cycle_profiles[@]}))
    target=$(state_to_profile "$state")

    if ! write_profile "$target"; then
        # Keep the previous state when the kernel rejects the write
        state=$(((state - 1 + ${#cycle_profiles[@]}) % ${#cycle_profiles[@]}))
        continue
    fi
done < <(inotifywait -m -q -e modify "$pf")
