# Asustor Flashstor Fan Control for TrueNAS SCALE

Temperature monitoring and fan control for Asustor Flashstor 6 and 12 Pro (Gen 1) devices running TrueNAS SCALE.

**Confirmed working on:**
- TrueNAS SCALE 25.10.x (Goldeye)
- TrueNAS SCALE 25.04.x (Fangtooth)
- TrueNAS SCALE 24.10.x (Electric Eel)

For older TrueNAS versions (Dragonfish/BlueFin), see the [old README files](README-old-Dragonfish.md) in this repo.

---

## What This Does

Asustor Flashstor devices have no native fan control under TrueNAS. This project provides:

1. **A kernel module check/install script** (`check_asustor_it87.kmod.sh`) — runs at boot, installs/loads the [asustor-platform-driver](https://github.com/mafredri/asustor-platform-driver) kernel module if needed
2. **A fan control script** (`temp_monitor.sh`) — monitors CPU, board, and NVMe temperatures and adjusts fan speed using linear curves with gradual speed changes

The fan control script dynamically detects all NVMe drives (up to 12) and monitors all their temperature sensors. It uses temperature averaging and hysteresis to prevent fan speed "hunting" (constant speed changes).

Standing on the shoulders of giants: adapted from [John Davis' original script](https://gist.github.com/johndavisnz/06a5e1aabaf878add0ad95669b3a0b3d) for Nimbustor devices.

---

## Important Notes

- **TrueNAS is an appliance.** Tinkering under the hood is not officially supported. Enabling developer mode will cause iXsystems to automatically delete any support requests.
- **You must SSH in as root.** The kmod compilation does not work via the WebUI shell, and does not work with `sudo su` from an admin account. You must SSH directly as root.
- **Scripts must live on a DataPool**, not in `/home/`. Starting with Electric Eel (24.10.x), `/home` is mounted with `noexec` — scripts there won't run.
- **GPIO tinkering can be dangerous.** Misconfiguring hardware I/O can lead to instability or data corruption.
- **Do this at your own risk.** Back up your data. Test extensively. Don't install on mission-critical systems.

---

## Quick Start

### Prerequisites

- Asustor Flashstor 6 or 12 Pro (Gen 1) running TrueNAS SCALE 24.10+
- SSH access to the TrueNAS box
- A ZFS dataset/directory on your data pool for the scripts

### Steps Overview

1. Enable root SSH access
2. Create a dataset on your pool for the scripts
3. Enable developer mode
4. Install the kernel module
5. Install the fan control scripts
6. Add the boot script to TrueNAS init
7. Reboot and verify

---

## Detailed Installation

### 1. Enable Root SSH Access

In the TrueNAS web interface:
- Go to **System → General Settings → show Advanced Settings**
- If you can see a console for Root, set a root password here. If not:
  - Go to **Credentials → Local Users** → enable **Show Built-in Users**
  - Find the `root` user, click **Edit**, and set a password
- Go to **System → Services → SSH** → **Edit**
  - Check **Log in as Root with Password**
  - Make sure SSH service is running

You can now SSH in as root:
```bash
ssh root@<your-truenas-ip>
```

> **Security note:** Disable root SSH login when you're done with the installation.

### 2. Create a Dataset for the Scripts

You need a directory on your data pool. You can either:
- Create a new dataset via the TrueNAS web UI (e.g. `MyPool/SystemTools`)
- Or just create a directory:

```bash
mkdir -p /mnt/<YourPool>/SystemTools
cd /mnt/<YourPool>/SystemTools
```

Replace `<YourPool>` with your actual pool name throughout these instructions.

### 3. Enable Developer Mode

```bash
install-dev-tools
```

This downloads and installs packages needed for compiling the kernel module. It takes a few minutes. Once done, iXsystems will no longer accept support requests from this system.

### 4. Install the Kernel Module

```bash
cd /mnt/<YourPool>/SystemTools

git clone https://github.com/mafredri/asustor-platform-driver
cd asustor-platform-driver
git checkout it87
make
make install
depmod -a
modprobe -a asustor_it87
```

Verify it worked:
```bash
sensors
```

You should now see an `it8625-isa-0a30` section in the output, including a `fan1` RPM reading:

```
it8625-isa-0a30
Adapter: ISA adapter
...
fan1:        1433 RPM  (min =   11 RPM)
...
```

You can also verify the module is loaded:
```bash
lsmod | grep asustor
```

> **Troubleshooting:** If `make` fails with \"dkms module already exists\" errors, see the [After a TrueNAS Upgrade](#after-a-truenas-upgrade) section for cleanup steps.

### 5. Install the Fan Control Scripts

```bash
cd /mnt/<YourPool>/SystemTools
```

Download the scripts from this repository. You can either clone this repo or download and create them manually:

**Option A: Clone this repo**
```bash
git clone https://github.com/bernmc/flashstor-trueNAS-fancontrol
cp flashstor-trueNAS-fancontrol/check_asustor_it87.kmod.sh .
cp flashstor-trueNAS-fancontrol/temp_monitor.sh .
```

**Option B: Create manually with nano**
```bash
nano check_asustor_it87.kmod.sh
# paste contents of check_asustor_it87.kmod.sh from this repo
# Ctrl-O, Enter to save, Ctrl-X to exit

nano temp_monitor.sh
# paste contents of temp_monitor.sh from this repo
# Ctrl-O, Enter to save, Ctrl-X to exit
```

Make both scripts executable:
```bash
chmod +x check_asustor_it87.kmod.sh temp_monitor.sh
```

**Edit the check script to set your path:**

The check script has a configuration variable at the top that must be updated to match your setup. Open it with nano:
```bash
nano check_asustor_it87.kmod.sh
```

Find the line near the top that reads:
```bash
FAN_CONTROL_SCRIPT_PATH="/mnt/<YourPool>/SystemTools/temp_monitor.sh"
```

Change `<YourPool>/SystemTools` to match your actual pool name and directory. For example, if your pool is called `MainPool` and you created a `SystemTools` dataset:
```bash
FAN_CONTROL_SCRIPT_PATH="/mnt/MainPool/SystemTools/temp_monitor.sh"
```

Save with `Ctrl-O`, `Enter`, then exit with `Ctrl-X`.

> **Tip:** You can verify the path is correct by running:
> ```bash
> ls -la /mnt/<YourPool>/SystemTools/temp_monitor.sh
> ```

### 6. Add the Boot Script to TrueNAS Init

In the TrueNAS web interface:
- Go to **System → Advanced Settings**
- Find **Init/Shutdown Scripts** and click **Add**
- Accept the popup warning
- Fill in:
  - **Description:** `Asustor fan control`
  - **Type:** Script
  - **Script path:** `/mnt/<YourPool>/SystemTools/check_asustor_it87.kmod.sh` (use your actual path)
  - **When:** Post Init
  - **Enabled:** checked
  - **Timeout:** 20
- Click **Save**

> **Important:** The script path here must match the actual location of your `check_asustor_it87.kmod.sh` file on your data pool. This is the same directory you used in Steps 4 and 5.

### 7. Reboot and Verify

Reboot your Flashstor. When it comes back online, you should hear the fan speed change.

Verify it's working:
```bash
sensors
ps aux | grep temp_monitor
```

You should see the `temp_monitor.sh` process running and fan speed readings from the `it8625` sensor.

### 8. Disable Root SSH

Once everything is working, disable root SSH login:
- Go to **System → Services → SSH** → **Edit**
- Uncheck **Log in as Root with Password**

---

## After a TrueNAS Upgrade

When TrueNAS is upgraded, the kernel may change and the kernel module will need to be recompiled. **In most cases, this happens automatically** — the `check_asustor_it87.kmod.sh` boot script runs after every reboot via the TrueNAS init system, checks if the module is present, and recompiles it if not.

There is no separate upgrade script — `check_asustor_it87.kmod.sh` handles everything.

### If the fan control stops working after an upgrade

If the automatic recompile fails (e.g. after a major version upgrade), follow these manual steps:

1. **Enable root SSH** (see Step 1 above) and SSH in as root
2. **Re-enable developer tools** — major upgrades may reset this:
   ```bash
   install-dev-tools
   ```
3. **Navigate to your scripts directory and run the check script:**
   ```bash
   cd /mnt/<YourPool>/SystemTools
   ./check_asustor_it87.kmod.sh
   ```
4. **Verify** the fan control is running:
   ```bash
   sensors | grep fan
   ps aux | grep temp_monitor
   ```
5. **Disable root SSH** when done

> **Note:** If the build fails with "dkms module already exists" errors, clean up the old modules first:
> ```bash
> dkms status
> dkms remove asustor-gpio-it87/v0.1
> dkms remove asustor-it87/v0.1
> dkms remove asustor/v0.1
> ```
> Then run `./check_asustor_it87.kmod.sh` again.

---

## Tuning the Fan Control

Edit `temp_monitor.sh` to adjust these variables at the top of the script:

| Variable | Default | Description |
|---|---|---|
| `debug` | `0` | Debug output level (0=off, 1=minimal, 2=verbose, 3=extreme) |
| `mailalerts` | `0` | Send email on fan speed changes (useful for testing, noisy in production) |
| `frequency` | `15` | How often to check temps (seconds) |
| `hdd_threshold` | `50` | NVMe temp (°C) above which fan starts ramping |
| `sys_threshold` | `75` | CPU/board temp (°C) above which fan starts ramping |
| `min_pwm` | `150` | Minimum fan PWM value (~2700 RPM) |
| `max_pwm_change` | `8` | Max PWM change per cycle (gradual speed adjustment) |
| `hdd_delta_threshold` | `5` | NVMe temp drop (°C) needed before fan slows down |
| `sys_delta_threshold` | `10` | CPU temp drop (°C) needed before fan slows down |
| `temp_history_size` | `3` | Number of readings to average for temperature smoothing |

### Fan Curves

The script uses **linear fan curves**:
- **NVMe:** From `hdd_threshold` to 75°C maps linearly from `min_pwm` to 255 (max speed)
- **System:** From `sys_threshold` to 95°C maps linearly from `min_pwm` to 255 (max speed)

The higher of the two calculated PWM values is used.

### Anti-Hunting Features

To prevent the fan from constantly changing speed:
- **Gradual adjustment:** Fan speed changes by at most `max_pwm_change` PWM units per cycle
- **Temperature averaging:** Each reading is averaged with the previous `temp_history_size` readings
- **Hysteresis on decreases:** Fan speed only decreases when the temperature has dropped by at least the delta threshold. Increases are applied immediately.

### PWM Reference Values

Approximate fan speeds for different PWM values:

| PWM | RPM |
|-----|------|
| 60 | ~1580 |
| 70 | ~1757 |
| 80 | ~1970 |
| 90 | ~2070 |
| 150 | ~2700 |
| 255 | max |

---

## Credits & Acknowledgments

- [John Davis](https://gist.github.com/johndavisnz/bae122274fc6f0e006fdf0bc92fe6237) — original Nimbustor fan control script and Debian install guide
- [mafredri](https://github.com/mafredri/asustor-platform-driver) — Asustor platform driver / IT8625E kernel module
- **JeGr and sb10** — early testing and modifications for the platform driver
- **Wallauer** — discovered the Electric Eel workaround (DataPool directory + root SSH)
- **tterava** — confirmed the workaround and tested on multiple TrueNAS versions including Goldeye

---

## Caveats

- **PMD (People May Die).** Not really, but you get the idea. This is unsupported tinkering with hardware I/O on an appliance OS. Do this at your own risk.
- The kernel module must be recompiled after kernel updates. The boot script handles this automatically, but a TrueNAS upgrade may require `install-dev-tools` to be re-run.
- I am an enthusiastic amateur, not a programmer. I probably won't be able to answer complex questions.
- This has been tested on Gen 1 Flashstor devices only. Gen 2 devices may need modifications.

---

## License

GPL-3.0 — see [LICENSE](LICENSE) for details.
