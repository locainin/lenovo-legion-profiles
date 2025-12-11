#!/usr/bin/env bash

pf=/sys/firmware/acpi/platform_profile
statefile=/var/lib/legion-fnq-state

# basic sanity checks
if ! command -v inotifywait >/dev/null 2>&1; then
    echo "Error: inotifywait not found. Install inotify-tools."
    exit 1
fi

if [ ! -e "$pf" ]; then
    echo "Error: $pf does not exist. This system does not expose platform_profile."
    exit 1
fi

mkdir -p /var/lib

# map current sysfs value to our 0..3 state
map_profile_to_state() {
    case "$1" in
        low-power)            echo 0 ;;
        balanced)             echo 1 ;;
        balanced-performance) echo 2 ;;
        performance)          echo 3 ;;
        *)                    echo 1 ;;  # default to balanced
    esac
}

# map our 0..3 state to sysfs string
map_state_to_profile() {
    case "$1" in
        0) echo "low-power" ;;
        1) echo "balanced" ;;
        2) echo "balanced-performance" ;;
        3) echo "performance" ;;
        *) echo "balanced" ;;
    esac
}

# init state from file or from current profile
if [ -f "$statefile" ]; then
    state=$(cat "$statefile")
else
    cur=$(cat "$pf")
    state=$(map_profile_to_state "$cur")
    echo "$state" > "$statefile"
fi

last_write_ms=0
last_event_ms=0

# event-driven loop: react when the kernel says pf changed
inotifywait -m -q -e modify "$pf" | while read -r _; do
    now_ms=$(date +%s%3N)

    # ignore changes that happen right after our own write
    delta_write=$(( now_ms - last_write_ms ))
    if [ "$delta_write" -lt 80 ]; then
        continue
    fi

    # basic debounce for spam: ignore events too close together
    delta_event=$(( now_ms - last_event_ms ))
    if [ "$delta_event" -lt 120 ]; then
        continue
    fi

    cur=$(cat "$pf")

    # treat this as "Fn+Q pressed": advance our own 4-step state
    state=$(( (state + 1) % 4 ))
    target=$(map_state_to_profile "$state")

    echo "$target" > "$pf"
    last_write_ms=$(date +%s%3N)
    last_event_ms="$last_write_ms"
    echo "$state" > "$statefile"
done
