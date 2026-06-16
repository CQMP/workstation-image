# IFT Workstation Installation Guide

How to install the OS image on a Dell Pro Max Tower T2 workstation.

## Prerequisites

- iPXE USB stick (see "One-time setup" below)
- Machine connected to FUW network via ethernet (DHCP)
- Latest CI build green: check https://github.com/CQMP/workstation-image/actions

---

## One-time setup (run once on Matsubara)

These steps produce the iPXE USB sticks and the boot files on the FUW web server.
Everything lives at `http://www.fuw.edu.pl/~egull/network_boot/` and is already in place —
only redo this if the files need to be regenerated or new sticks are needed.

### 1. Download the CentOS boot ISO and extract PXE files

```bash
curl -L -o /data/egull/centos9-boot.iso \
    https://mirror.stream.centos.org/9-stream/BaseOS/x86_64/iso/CentOS-Stream-9-latest-x86_64-boot.iso

sudo mount -o loop,ro,uid=$(id -u) /data/egull/centos9-boot.iso /mnt/iso
cp /mnt/iso/images/pxeboot/vmlinuz  /dmj/ift1/egull/WWW/network_boot/
cp /mnt/iso/images/pxeboot/initrd.img /dmj/ift1/egull/WWW/network_boot/
sudo umount /mnt/iso
```

### 2. Write the iPXE boot script

```
/dmj/ift1/egull/WWW/network_boot/boot.ipxe:

#!ipxe
kernel http://www.fuw.edu.pl/~egull/network_boot/vmlinuz initrd=initrd.img inst.stage2=https://mirror.stream.centos.org/9-stream/BaseOS/x86_64/os/ inst.ks=https://raw.githubusercontent.com/CQMP/workstation-image/main/ks.cfg quiet
initrd http://www.fuw.edu.pl/~egull/network_boot/initrd.img
boot
```

To change boot parameters for all machines, edit this file — no need to remake the sticks.

### 3. Build the iPXE EFI binary

Install build deps (transient — gone after reboot):

```bash
sudo dnf install -y --transient mtools xz-devel
```

Build iPXE with a chainload script baked in:

```bash
git clone --depth=1 https://github.com/ipxe/ipxe.git /data/egull/ipxe

cat > /data/egull/ipxe/chain.ipxe << 'EOF'
#!ipxe
dhcp
chain http://www.fuw.edu.pl/~egull/network_boot/boot.ipxe
EOF

make -C /data/egull/ipxe/src bin-x86_64-efi/ipxe.efi EMBED=/data/egull/ipxe/chain.ipxe
```

### 4. Write the iPXE EFI to USB sticks

Format each stick as GPT/FAT32 and drop the EFI binary in the standard UEFI path.
Adjust `sda sdb ...` to match the connected sticks (`lsblk` to identify them):

```bash
IPXE=/data/egull/ipxe/src/bin-x86_64-efi/ipxe.efi

for dev in sda sdb sdc sdd sde; do
    sudo parted -s /dev/$dev mklabel gpt
    sudo parted -s /dev/$dev mkpart ESP FAT32 1MiB 100%
    sudo parted -s /dev/$dev set 1 esp on
    sudo mkfs.fat -F32 -n IPXE /dev/${dev}1
    sudo mkdir -p /mnt/usb_$dev
    sudo mount /dev/${dev}1 /mnt/usb_$dev
    sudo mkdir -p /mnt/usb_$dev/EFI/BOOT
    sudo cp $IPXE /mnt/usb_$dev/EFI/BOOT/BOOTX64.EFI
    sudo umount /mnt/usb_$dev
done
```

---

## Per-machine procedure

### 1. BIOS setup (one-time per machine)

1. Power on, press **F2** to enter BIOS
2. Navigate to **Secure Boot** → set to **Disabled**
   (The NVIDIA kernel module is not signed; Secure Boot will prevent it from loading.)
3. Save and exit

### 2. Boot from USB

1. Insert the iPXE USB stick, power on, press **F12** for the one-time boot menu
2. Select the USB device
3. iPXE starts, obtains a DHCP lease, fetches `boot.ipxe` from the FUW web server,
   and boots the CentOS Anaconda installer automatically — no interaction required

### 3. Unattended install

The install runs without interaction. It will:
- Partition the NVMe drive (512 MB EFI + 1 GB /boot + 50 GB / + rest as /data)
- Pull the OS image from `ghcr.io/cqmp/centos9-workstation:latest` (~10–20 min depending on network)
- Reboot automatically

Do not interrupt. The machine is ready when it boots into the GNOME login screen.

> **Note:** If Anaconda aborts immediately with a disk error, the drive name may differ from
> `nvme0n1`. SSH in (or open a shell with **Ctrl+Alt+F2**) and run `lsblk` to find the
> correct device. Update `ks.cfg` in the repo if needed.

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

Once machine 1 passes all checks, repeat steps 1–5 for each of the remaining machines.
The boot files on the web server are already in place — only the BIOS Secure Boot step
and the USB boot are needed per machine.

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
