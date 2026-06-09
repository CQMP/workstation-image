# IFT Workstation Installation Guide

How to install the OS image on a Dell Pro Max Tower T2 workstation.

## Prerequisites

- USB stick with CentOS Stream 9 boot ISO (already written)
- Machine connected to FUW network via ethernet (DHCP)
- Latest CI build green: check https://github.com/CQMP/workstation-image/actions

---

## Per-machine procedure

### 1. BIOS setup (one-time per machine)

1. Power on, press **F2** to enter BIOS
2. Navigate to **Secure Boot** → set to **Disabled**
   (The NVIDIA kernel module is not signed; Secure Boot will prevent it from loading.)
3. Save and exit

### 2. Boot from USB

1. Insert the USB stick, power on, press **F12** for the one-time boot menu
2. Select the USB device
3. At the Anaconda GRUB menu, highlight **"Install CentOS Stream 9"** and press **`e`**
4. Find the line beginning with `linuxefi` and add to the end of it:
   ```
   inst.ks=https://raw.githubusercontent.com/CQMP/workstation-image/main/ks.cfg
   ```
5. Press **Ctrl+X** to boot

### 3. Unattended install

The install runs without interaction. It will:
- Partition the NVMe drive (512 MB EFI + 1 GB /boot + 50 GB / + rest as /data)
- Pull the OS image from `ghcr.io/cqmp/centos9-workstation:latest` (~10–20 min depending on network)
- Reboot automatically

Do not interrupt. The machine is ready when it boots into the GNOME login screen.

> **Note:** If Anaconda aborts immediately with a disk error, the drive name may differ from
> `nvme0n1`. Boot the USB *without* `inst.ks=`, open a shell with **Ctrl+Alt+F2**, and run
> `lsblk` to find the correct device. Update `ks.cfg` in the repo if needed.

### 4. First-boot verification

SSH into the machine (find its IP from your router or DHCP leases):

```bash
ssh egull@<machine-ip>
```

Run these checks:

```bash
# LDAP user resolution
getent passwd egull

# NFS home directory (should show your files)
ls /dmj/ift1/egull

# NVIDIA driver
nvidia-smi

# GPU visible to CUDA
/usr/local/cuda/bin/deviceQuery 2>/dev/null | grep "Result ="
```

All four should succeed. If `nvidia-smi` fails, check that Secure Boot is disabled.

### 5. Record the MAC address

```bash
ip link show | grep -A1 "^2:"
```

Note the MAC address of the ethernet interface and give it to Krzysztof Szymaszczyk
(krzysztof.szymaszczyk@fuw.edu.pl) for a DHCP hostname reservation. Agreed naming
convention: TBD.

### 6. Repeat for remaining machines

Once machine 1 passes all checks, repeat steps 1–5 for each of the remaining 9 machines.

---

## Updating the image later

The image rebuilds automatically every Sunday at 3am UTC and on every push to `main`.
Machines pull updates via bootc. To trigger an immediate update on a running machine:

```bash
sudo bootc upgrade
sudo reboot
```

---

## Pending before the setup is complete

- **LDAP bind account:** `sssd.conf` currently uses `cn=hprxFizyk1` (temporary).
  Once `cn=hprxGullZgidWS` is provisioned by OKWF, update `etc/sssd/sssd.conf` and
  rotate the `LDAP_BIND_PASSWORD` GitHub Actions secret.

- **Dominika Zgid:** No FUW LDAP account yet. Request from Krzysztof Szymaszczyk.
  Once her uid is known, add it to `simple_allow_users` in `etc/sssd/sssd.conf`.

- **Printer:** Sharp MX-C358F driver not yet installed. Deferred.
