# IFT Workstation Installation Guide

How to install the OS image on a Dell Pro Max Tower T2 workstation.

## Prerequisites

- Machine connected to FUW network via ethernet (DHCP)
- Latest CI build green: check https://github.com/CQMP/workstation-image/actions

---

## One-time HTTP boot setup (run on Matsubara)

The Dell Pro Max Tower T2 BIOS has a GRUB heap bug that causes USB boot to fail with
`out of memory` regardless of ISO size. We boot instead via UEFI HTTP Boot, which loads
a tiny iPXE binary directly from the FUW web server, bypassing GRUB entirely.

Run these steps once on Matsubara. The resulting files on the web server are reused for
every subsequent machine.

```bash
mkdir -p /var/tmp/ipxe-build
cd /var/tmp/ipxe-build

# Download the CentOS Stream 9 boot ISO
curl -L -o centos-boot.iso \
    https://mirror.stream.centos.org/9-stream/BaseOS/x86_64/iso/CentOS-Stream-9-latest-x86_64-boot.iso

# Extract the PXE kernel and initramfs
sudo mkdir -p /mnt/centos-iso
sudo mount -o loop,ro centos-boot.iso /mnt/centos-iso
cp /mnt/centos-iso/images/pxeboot/vmlinuz .
cp /mnt/centos-iso/images/pxeboot/initrd.img .
sudo umount /mnt/centos-iso

# Write the iPXE boot script
cat > boot.ipxe << 'EOF'
#!ipxe
kernel http://www.fuw.edu.pl/~egull/boot/vmlinuz inst.repo=https://mirror.stream.centos.org/9-stream/BaseOS/x86_64/os/ inst.ks=https://raw.githubusercontent.com/CQMP/workstation-image/main/ks.cfg console=tty0
initrd http://www.fuw.edu.pl/~egull/boot/initrd.img
boot
EOF

# Build iPXE with the embedded boot script (takes ~5 minutes)
podman run --rm \
    -v $(pwd)/boot.ipxe:/boot.ipxe:z \
    -v $(pwd):/output:z \
    docker.io/debian:bookworm bash -c "
        apt-get update -qq && \
        apt-get install -y -qq git make gcc binutils perl mtools liblzma-dev && \
        git clone --depth 1 https://github.com/ipxe/ipxe.git /ipxe && \
        make -C /ipxe/src bin-x86_64-efi/ipxe.efi EMBED=/boot.ipxe && \
        cp /ipxe/src/bin-x86_64-efi/ipxe.efi /output/ipxe.efi
    "

# Upload to FUW web server
ssh egull@www.fuw.edu.pl 'mkdir -p public_html/boot'
scp vmlinuz initrd.img ipxe.efi egull@www.fuw.edu.pl:public_html/boot/
```

The three files are now at `http://www.fuw.edu.pl/~egull/boot/`. Done — move on to the
per-machine procedure below.

---

## Per-machine procedure

### 1. BIOS setup (one-time per machine)

1. Power on, press **F2** to enter BIOS
2. Navigate to **Secure Boot** → set to **Disabled**
   (The NVIDIA kernel module is not signed; Secure Boot will prevent it from loading.)
3. Still in BIOS, add an HTTP Boot entry:
   - Go to **Settings → General → Boot Sequence → Add Boot Option**
   - Name it `iPXE HTTP`
   - Set the file path / URL to:
     ```
     http://www.fuw.edu.pl/~egull/boot/ipxe.efi
     ```
   - Move it to the top of the boot order
4. Save and exit

### 2. Boot via HTTP

1. The machine fetches `ipxe.efi` over the network, which in turn fetches the CentOS
   kernel and initramfs and boots Anaconda automatically with the kickstart.
2. No interaction required — Anaconda reads the kickstart and proceeds unattended.

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

Once machine 1 passes all checks, repeat the per-machine steps 1–5 for each remaining machine.
The HTTP boot files on the web server are already in place — only the BIOS setup is needed per machine.

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
