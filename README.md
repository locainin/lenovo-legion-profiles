# lenovo-legion-profiles

## What this does

Lenovo Legion laptops expose their thermal mode through `/sys/firmware/acpi/platform_profile`.
Fn+Q usually cycles the firmware profiles, but Lenovo changed the Linux-facing names for the red
and purple slots in newer kernels.

This script watches `platform_profile`, treats each firmware change as an Fn+Q press, and applies
its own 4-step cycle so the hidden purple slot stays reachable from the keyboard.

The script now auto-detects which kernel ABI is present:

- Legacy mapping:
  `low-power → balanced → balanced-performance → performance`
- Current mapping:
  `low-power → balanced → performance → max-power`

`custom` is left alone and is not part of the Fn+Q override cycle.

## Profile mapping

Current Lenovo Gamezone docs describe the modern profile names like this:

- `low-power` → blue LED
- `balanced` → white LED
- `performance` → red LED
- `max-power` → purple LED
- `custom` → purple LED

Older kernels exposed the same red and purple slots like this:

- `balanced-performance` → red LED
- `performance` → purple LED

The script maps both layouts to the same logical order:

`blue → white → red → purple → blue`

## Compatibility note

Lenovo's Gamezone driver used to expose the red and purple firmware slots with confusing Linux
names on some Legion models:

- BIOS `Performance` showed up as `balanced-performance`
- BIOS `Extreme` showed up as `performance`

That meant the LED colors and Linux profile names did not line up cleanly.

Newer kernels switched the Gamezone driver to expose the purple `Extreme` slot as `max-power`
instead of overloading `performance`. Current kernel documentation now describes the mapping as:

- `low-power` → blue LED
- `balanced` → white LED
- `performance` → red LED
- `max-power` → purple LED
- `custom` → purple LED

This project handles both layouts, so the same Fn+Q override logic works on older and newer
kernels.

## Requirements

### Hardware and kernel

- A Lenovo Legion laptop that exposes `platform_profile`
- A kernel with `CONFIG_ACPI_PLATFORM_PROFILE`
- A kernel that also exposes `platform_profile_choices`

Check support with:

```bash
ls /sys/firmware/acpi/platform_profile
cat /sys/firmware/acpi/platform_profile_choices
```

If either sysfs file is missing, this tool will not work on that machine.

### Software

- `inotifywait` from `inotify-tools`

Install it per distro:

- Arch / Manjaro / EndeavourOS

```bash
sudo pacman -S inotify-tools
```

- Debian / Ubuntu / Pop!_OS / Mint

```bash
sudo apt install inotify-tools
```

- Fedora

```bash
sudo dnf install inotify-tools
```

## Installation (Suggested)

The recommended path is the installer, because systemd runs the copy in `/usr/local/sbin`.
Editing the repo file alone does not update the installed service.

Run:

```bash
./install.sh
```

The installer prompts for `install` or `uninstall`, copies the current script into place, installs
the tracked systemd unit, reloads systemd, and starts or removes the service.

## Installation (Manual)

Install dependencies

Install `inotify-tools` as shown above for your distro.

Copy the script

Place the script somewhere root-owned and executable, for example:

```bash
sudo mkdir -p /usr/local/sbin
sudo cp legion-fnq-override.sh /usr/local/sbin/legion-fnq-override.sh
sudo chmod +x /usr/local/sbin/legion-fnq-override.sh
```

`/var/lib/legion-fnq-state` will be created automatically by the script if needed.

Install the systemd service

Create `/etc/systemd/system/legion-fnq-override.service`:

```ini
[Unit]
Description=Override Lenovo Legion Fn+Q to 4-step platform_profile cycle
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/legion-fnq-override.sh

[Install]
WantedBy=multi-user.target
```

Then reload and enable:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now legion-fnq-override.service
```

Check status with:

```bash
systemctl status legion-fnq-override.service
```

The service should stay `active (running)` with no write errors.

If the service is already installed and the repo script changed, reinstall it. A running systemd
service will keep using the old copy until `/usr/local/sbin/legion-fnq-override.sh` is replaced
and the unit is restarted.

## Recommended setup

Avoid running other tools that constantly write to `platform_profile`, because they will race the
override logic.

Common examples:

```bash
sudo systemctl disable --now auto-cpufreq.service
sudo systemctl disable --now tlp.service
sudo systemctl disable --now dynamic_power.service
```

## How to verify it

Watch the current profile:

```bash
watch -n0.2 cat /sys/firmware/acpi/platform_profile
```

Then press Fn+Q repeatedly.

Expected sequence on newer kernels:

```text
low-power
balanced
performance
max-power
low-power
```

Expected sequence on older kernels:

```text
low-power
balanced
balanced-performance
performance
low-power
```
