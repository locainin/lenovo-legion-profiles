# lenovo-legion-profiles


## What this does

Most Lenovo Legion laptops on Linux expose these profiles:

- `low-power`              → blue LED
- `balanced`               → white LED
- `balanced-performance`   → red LED (firmware “Performance”)
- `performance`            → pink LED (hidden / “Extreme” slot)
- `custom`                 → reserved

Fn+Q in firmware only cycles **three** of them:

`low-power → balanced → balanced-performance → low-power → …`

This script:

- Watches `/sys/firmware/acpi/platform_profile` for changes caused by Fn+Q.
- Treats each change as a “Fn+Q pressed” event.
- Immediately overrides the profile using its own **4-step state order that includes performance**:

`low-power → balanced → balanced-performance → performance → low-power → …`

So Fn+Q effectively becomes:

> blue → white → red → pink → blue …


## Requirements

### Hardware / kernel

- A Lenovo Legion laptop with firmware that exposes `platform_profile`. (should already be default in most main kernals)
- A Linux kernel with `CONFIG_ACPI_PLATFORM_PROFILE` enabled (true on mainline Arch, Fedora, Ubuntu, etc.)
- You can check support with:

```
ls /sys/firmware/acpi/platform_profile
cat /sys/firmware/acpi/platform_profile_choices
```

any custom “dynamic power” unit that writes to /sys/firmware/acpi/platform_profile

If this file does **not** exist, your system does not expose `platform_profile` and this tool will not work there.

### Software

- `inotifywait` from `inotify-tools`.

Install per distro:

- **Arch / Manjaro / EndeavourOS**

  ```
  sudo pacman -S inotify-tools
  ```
- **Debian / Ubuntu / Pop!_OS / Mint**
  ```
  sudo apt install inotify-tools
  ```
- **Fedora**
  ```
  sudo dnf install inotify-tools
  ```

## Installation

1. **Install dependencies**

   Install `inotify-tools` as shown above for your distro.

2. **Copy the script**

   Place the script somewhere root-owned and executable, for example:

   ```
   sudo mkdir -p /usr/local/sbin
   sudo cp legion-fnq-override.sh /usr/local/sbin/legion-fnq-override.sh
   sudo chmod +x /usr/local/sbin/legion-fnq-override.sh
   ```

   `/var/lib/legion-fnq-state` will be created automatically by the script if needed.
3. **Install the systemd service**

   Create `/etc/systemd/system/legion-fnq-override.service`:

   ```
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

   ```
   sudo systemctl daemon-reload
   sudo systemctl enable --now legion-fnq-override.service
   ```

   Check status:

   ```
   systemctl status legion-fnq-override.service
   ```

   It should show `active (running)` with no errors.

---

  ## Recommended power setup (to avoid conflicts)

To let this script fully control Fn+Q behavior, it is strongly recommended to disable other daemons that write to `platform_profile` or constantly adjust platform policy.

Common ones:

```
sudo systemctl disable --now auto-cpufreq.service   # if present
sudo systemctl disable --now tlp.service            # if present
sudo systemctl disable --now dynamic_power.service  # if present
```
- Note: dynamic-power-daemon can remain enabled if `acpi_platform_profile` is set to `disabled` in each profile in the system config `dynamic_power.yaml`. This prevents writes to `platform_profile` while still allowing CPU/EPP/ASPM tuning.
  ## How to verify it’s working

- **Watch the current profile:**
```
watch -n0.2 cat /sys/firmware/acpi/platform_profile
```
- **Press Fn+Q repeatedly.**
You should see the sequence:

```
low-power
balanced
balanced-performance
performance
low-power
```
