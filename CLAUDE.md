# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A bootc (image-based OS) definition for a pool of GPU workstations at the Institute of Theoretical Physics (IFT), Faculty of Physics, University of Warsaw. The machines are Dell Pro Max Tower T2 systems with NVIDIA RTX 2000 Ada GPUs, running CentOS Stream 9. The OS is built as an OCI container image and deployed atomically via `bootc`.

- **Image registry:** `ghcr.io/cqmp/centos9-workstation:latest`
- **GitHub repo:** `github.com/CQMP/workstation-image` (org: `cqmp`, admin: `egull`)
- **Base image:** `quay.io/centos-bootc/centos-bootc:stream9` (pinned to a digest in `Containerfile`)

## Architecture

Everything lives in a single `Containerfile`. Config files are in `etc/`, `usr/`, and `root/` and are `COPY`-ed into the image at the end of the build (after all expensive package/build layers) to avoid invalidating the layer cache unnecessarily.

Key config locations and what they do:

| Path | Purpose |
|------|---------|
| `Containerfile` | Full image definition — all packages, DKMS kernel module build, Boost 1.92 source build (`/usr/local`; Boost.MPI per MPI in `/usr/lib64/{openmpi,mpich}/lib`), systemd enables |
| `ks.cfg` | Anaconda kickstart: partitions NVMe, pulls image from GHCR, triggers reboot |
| `etc/sssd/sssd.conf` | LDAP auth via SSSD; no password (host-local, see Secrets) |
| `etc/condor/config.d/00-ift-execute.conf` | HTCondor execute-node policy; idle start, CRIU checkpointing |
| `etc/systemd/system/bootc-update.{service,timer}`, `usr/local/libexec/ift-update` | Weekly update every Sunday 04:00 UTC with automatic rollback (see Updates and rollback) |
| `etc/systemd/system/ift-boot-check.service`, `usr/local/libexec/ift-boot-check`, `usr/lib/ift/grub-user.cfg` | After an update: boot check, GRUB boot counting, rollback |
| `etc/systemd/system/data.{mount,automount}` | Automounts `/data` via NFSv4.2 from `luttinger-storage` (`10.98.2.4:/data`) |
| `etc/systemd/system/scratch.mount` | Mounts local NVMe scratch partition (label `data`) at `/scratch` |
| `etc/systemd/system/scratch-homedirs.service` | Creates `/scratch/<user>/` dirs for each allowed user on boot |
| `etc/systemd/system/cups-printers.service` | Registers shared network printers (e.g. Sharp MX-C358F) with CUPS on boot, driverlessly via IPP Everywhere |
| `etc/systemd/system/gh-runner-vm.service`, `usr/local/libexec/gh-runner-vm` | Throwaway GitHub Actions runner VMs while the workstation is idle (see below); settings in `etc/gh-runner/runner.conf` |
| `etc/auto.master` | autofs mounts for `/dmj`, `/expo`, `/repo` and peer workstation scratch disks |
| `etc/idmapd.conf` | NFSv4 ID mapping domain `fuw.edu.pl` (the department NAS sends owners as `user@fuw.edu.pl`; without it the homes show `nobody`) |
| `etc/auto.shared_scratch` | autofs map for `/shared_scratch/<host>` NFS mounts of workstation `/scratch` disks |
| `etc/exports.d/scratch.exports` | NFS export of local `/scratch` to the workstation subnet |
| `usr/lib/bootc/kargs.d/nvidia.toml` | Kernel args: `nvidia-drm.modeset=1`, `modprobe.blacklist=nouveau` |
| `etc/flatpak/remotes.d/flathub.flatpakrepo` | Flathub remote for the system Flatpak installation; users install apps with `--user` (into the NFS home) after adding it once: `flatpak remote-add --user --if-not-exists flathub /etc/flatpak/remotes.d/flathub.flatpakrepo` |
| `etc/profile.d/cuda.sh` | Appends `/usr/local/cuda/bin` (nvcc, cuda-gdb) to the PATH |
| `etc/dracut.conf.d/` | Initramfs tuning: nouveau blacklisted in initrd; modules stripped for small image |
| `machines.md` | Machine inventory: names, MACs, IPs (10.42.1.40–50) |
| `.github/workflows/build.yml` | CI: build + push to GHCR on every push to `main` and weekly Sunday 00:17 UTC (well ahead of the 04:00 UTC `bootc-update.timer`; GitHub starts scheduled runs up to ~1.5h late). Passes `UPDATE_STAMP` (date of the most recent Sunday) so the weekly `dnf upgrade` layer reruns once a week |

## Updates and rollback

Kernel and packages update weekly. The Sunday CI build (00:17 UTC) moves the `FROM` line to the newest `centos-bootc:stream9` digest, which rebuilds everything including the DKMS nvidia module (so driver/CUDA update too), and commits the digest only if the build succeeds; a failed build leaves `:latest` alone. Between base changes, a late `dnf upgrade` layer reruns whenever its `UPDATE_STAMP` build arg changes (once a week) and carries only updated packages; it excludes the kernel and NVIDIA's repository (`--disablerepo=cuda-rhel9-x86_64`), whose updates come with the base rebuild. A base change is a full image download (~14 GB; 8 minutes on Hubbard). The bump can be run by hand: Actions, "Build and push workstation image", Run workflow, `bump_base`.

On the machines (Sunday 04:00 UTC, `bootc-update.service` runs `ift-update`):

1. `bootc upgrade` stages the new image, sets `ift_boot_counter=3` in `/boot/grub2/grubenv` and reboots. An image that already failed on this machine (`/var/lib/ift-update/failed`) is skipped.
2. GRUB (`/boot/grub2/user.cfg`, installed from `usr/lib/ift/grub-user.cfg` by `ift-boot-check`; the bootupd-managed `grub.cfg` sources it) counts the attempts down; at 0 it boots the second entry, the previous deployment. Kernel panics (`panic=10`), initramfs failures (`rd.emergency=reboot`) and hangs (hardware watchdog, `50-ift-watchdog.conf`) turn into reboots, i.e. failed attempts.
3. `ift-boot-check.service` checks the new image for up to 10 minutes: `nvidia-smi`, `gdm`, a ping to the default gateway, `sssd` and `condor` (if their secrets exist). Pass: the counter is unset. Fail: `bootc rollback` and reboot. If GRUB had fallen back, it undeploys the failed image so the working one stays the default.
4. The outcome is in `journalctl -u ift-boot-check` ("Update OK" or "UPDATE FAILED"). Failed images are listed in `/var/lib/ift-update/failed`; delete the file to allow a retry. To test the rollback: `sudo touch /var/lib/ift-update/simulate-failure` before an update.

Tested on Hubbard, Nov 6 2026: a normal update (check passes, counter unset), a simulated check failure (`bootc rollback`, reboot into the previous image, image recorded as failed), a GRUB fallback (counter 0: GRUB booted the previous deployment, the failed one was undeployed), and the skip of a failed image. `bootc` compares with the image it last fetched, not the booted one: to reinstall a rejected image, `bootc switch` to its `@sha256:` digest.

Not covered: a boot that ends in systemd's emergency mode after the initramfs (e.g. a broken fstab entry) waits at the console.

## Secrets

**No secrets in the image** (the GHCR package is public), as in `../cluster-image`. They are host-local files, placed by hand from the password manager; files in `/etc` that the image does not ship survive `bootc upgrade`. Until a file exists, its service stays off (`ConditionPathExists` drop-ins):

- LDAP bind password: `/etc/sssd/conf.d/50-ldap-bind.conf`, `root:root 0600`, contents `[domain/fizyk]` / `ldap_default_authtok = <password>` (gates `sssd`)
- HTCondor pool token: `/etc/condor/tokens.d/ift-pool-token`, directory `700 root:root`, file `600 root:root` (gates `condor`). Any deviation in permissions causes silent auth failure. The name differs from the old image-shipped `pool-token`, which upgrades delete.

Placing them on a host (from an admin's NFS home, which root cannot read under `root_squash`, hence the pipes):

```bash
cat ~/.move/condor_token | sudo install -m 0600 -o root -g root /dev/stdin /etc/condor/tokens.d/ift-pool-token
{ printf '[domain/fizyk]\nldap_default_authtok = '; tr -d '\n' < ~/.move/ldap_token; echo; } \
  | sudo install -m 0600 -o root -g root /dev/stdin /etc/sssd/conf.d/50-ldap-bind.conf
sudo sssctl config-check
```

Before Nov 2026 both were baked into the public image from GitHub Actions secrets; the LDAP proxy password (shared with the Luttinger cluster) and the image's old pool token must be rotated.

## Adding packages or config

1. Edit `Containerfile` (packages) or the relevant file under `etc/`/`usr/`/`root/`
2. Push to `main` — GitHub Actions rebuilds and pushes `ghcr.io/cqmp/centos9-workstation:latest`
3. On each workstation: `sudo bootc upgrade && sudo reboot`

To add a user: add their Unix username to `simple_allow_users` in `etc/sssd/sssd.conf` **and** to the user list in `etc/systemd/system/scratch-homedirs.service`. Their `/data/<user>` dataset on `luttinger-storage` is created from the same `simple_allow_users` list by the `zfs_userdata` Ansible role in `../cluster_configuration`; rerun it after the image is pushed.

## NVIDIA / DKMS notes

The NVIDIA kernel module (open variant, `kmod-nvidia-open-dkms`; the proprietary `kmod-nvidia-latest-dkms` was discontinued at driver 615) is built in-image with DKMS (`dkms build/install`) during the container build. Secure Boot must be **disabled** on the hardware (the module is unsigned). The `omit-nvidia-initramfs.conf` dracut config ensures nvidia modules are excluded from the initramfs (loaded from the live root instead), which keeps the initramfs small enough for EFI allocation.

CUDA is installed as components (`cuda-compiler`, `cuda-libraries{,-devel}`, `cuda-command-line-tools`, `cuda-nvml-devel`, versioned like `-13-4` after the latest `cuda-toolkit`), not the `cuda-toolkit` meta-package: that adds ~2.5 GB of Nsight Systems/Compute GUIs. The image is ~14 GB compressed (~40 GB on disk). Machines installed with the old 50 GB root partition cannot stage upgrades with large layer changes (`Insufficient free space` / `min-free-space-percent '3%' would be exceeded`); `ks.cfg` now uses 200 GiB, and all machines installed earlier were converted in place (Bethe last, Nov 2026: `p3` keeps its start and GUID and ends at sector 422578175, the empty `p4` is recreated with label `data`, `xfs_growfs /var` because `/sysroot` is mounted read-only). Keep the image lean, and put small additions in late layers so they don't rebuild the big ones. `etc/profile.d/cuda.sh` puts `/usr/local/cuda/bin` on the PATH.

## HTCondor

Central manager: `condor.gull-group.org`. Each workstation runs `MASTER`, `STARTD`, and `SCHEDD`. A startd cron monitor publishes local graphical-session idle time from systemd-logind because HTCondor's `KeyboardIdle` fallback does not see GNOME input without `condor_kbdd`. Jobs start only when `LocalInteractiveIdle > 900s` and `LoadAvg < 0.5`; remote SSH sessions do not inhibit jobs. CRIU checkpointing is enabled with `cuda-checkpoint` for GPU jobs; vacate time is 1 hour. `cuda-checkpoint` cannot checkpoint processes that use managed memory (`cudaMallocManaged`: "operation not supported", drivers 615 and 620 alike).

## GitHub Actions runners

`gh-runner-vm.service` offers each workstation to GitHub (orgs `ALPSim`, `CQMP` and `Green-Phys`, labels `self-hosted, ift-vm`) as a one-job runner inside a KVM VM, only while it is idle by the HTCondor rule (`LocalInteractiveIdle > 900`). Each VM is a copy-on-write disk on a base image in `/var/lib/gh-runner` (Ubuntu 24.04 cloud image with the actions runner and Docker, built on the host by booting the cloud image once and rebuilt weekly). It gets a single-use JIT registration in each org from a GitHub App (one runner process per org in the VM); the first job takes the VM and the other registrations are withdrawn. After the job the VM is stopped and its disk deleted.

- **HTCondor:** while a job runs the script touches `/run/gh-runner/busy`. The `gh_runner` startd cron publishes it as `GitHubRunnerBusy`, so `START` is false and `PREEMPT` evicts (checkpoints) the HTCondor jobs; afterwards the machine takes jobs again. The machine stays in the pool (state Owner) instead of `condor_off`, so a crash cannot leave it switched off: the flag lives in the service's RuntimeDirectory.
- **Local user returns:** an idle VM is stopped and deregistered; a running job finishes at `CPUWeight=20`, killed after `MAX_JOB_SECONDS`.
- **Network:** NAT via tap `ghr0` (192.168.231.0/30, nftables table `inet gh_runner`). The guest cannot reach the host, private ranges (NFS, LDAP, workstations) or `EXTRA_BLOCK_NETS`; DNS is public. No shared folders, no GPU.
- **Credentials:** one GitHub App (owned by ALPSim, made public so it can be installed in the other orgs) with the org permission "Self-hosted runners: read & write". `APP_ID` and `ORGS` (org:runner group) go in `etc/gh-runner/runner.conf`; the private key goes to `/etc/gh-runner/app.pem` (root 0600) on each host, never in the image (the image is public). The service is inert until the key exists.
- **Debugging:** `journalctl -u gh-runner-vm`; a failed image build leaves `/var/lib/gh-runner/build/console.log`.

## Network card (Intel I219, e1000e)

The onboard I219 stalls under sustained transmit load with TCP segmentation offload on: the kernel logs `e1000e ...: Detected Hardware Unit Hang` every 2 s and the machine has no network until a reboot (Nov 2026: Bethe, Matsubara, Hubbard, Tomonaga and Nozieres, within 10-25 minutes of CI builds in the runner VMs). `usr/lib/systemd/network/98-e1000e-no-tso.link` turns TSO/GSO off when udev names the device; it repeats the naming policy of `99-default.link` because the first matching `.link` file wins. (A udev `RUN+="ethtool -K $name ..."` rule does not work: it runs while the device is still `eth0`.) Check with `ethtool -k <if> | grep segmentation`. With TSO/GSO off, Bethe and Hubbard ran the full ALPS CI without a hang.

## LDAP / Authentication

- **LDAP server:** `ldaps://ccdas1.fuw.edu.pl` (port 636, GEANT TLS cert, valid Sep 2026)
- **Base DN:** `ou=fizyk,ou=unixAuth,dc=das,dc=fuw,dc=edu,dc=pl`
- **Bind DN:** `cn=hprxGullZgidWS,ou=IFT,ou=unixFizyk,ou=proxyAgents,dc=das,dc=fuw,dc=edu,dc=pl`
- **Current allow list:** `egull, rfarid, ajazdzewska, amarie, abalbi, jdobrzyniecki, aaleryani, cwei, jgrabarczyk`

If LDAP auth fails, check: (1) user exists in LDAP Unix domain, (2) user is in `simple_allow_users`, (3) user is using their Unix password (not institutional SSO).

## File systems on the workstations

- `/dmj`, `/expo`, `/repo` — NFS via autofs (home dirs, shared code, backed up)
- `/data` — NFSv4.2 from `luttinger-storage` (`10.98.2.4:/data`, ZFS raidz2, one dataset per user with a 10 TB quota), systemd automount, `hard` mount. Exports, quotas and the workstation client list (read from `machines.md`) are managed in `../cluster_configuration`
- `/scratch` — local NVMe scratch, per-user dirs created by `scratch-homedirs.service`, **not backed up** (was mounted at `/data` before Oct 2026; same partition, label `data`)
- `/shared_scratch/<host>` — on-demand NFS access to another workstation's `/scratch`; availability depends on that workstation being powered on and reachable

## Printing

- CUPS + `cups-printers.service` provision printer queues driverlessly at boot (no vendor PPD needed) via CUPS's IPP Everywhere (`lpadmin -m everywhere`) support.
- **Sharp MX-C358F** (`10.43.6.203`) — confirmed to advertise `ipp-everywhere` in its IPP attributes; queue name `Sharp-MX-C358F`.
- To add another network printer, add an `lpadmin ... -m everywhere` idempotency check + call to `etc/systemd/system/cups-printers.service`, following the existing Sharp queue as a template. Confirm the target printer advertises `ipp-everywhere` first (`ipptool -tv ipp://<ip>/ipp/print get-printer-attributes.test` or check `ipp-features-supported`); if it doesn't, fall back to a foomatic/vendor PPD via `lpadmin -m <ppd>`.

## Base image digest updates

The `FROM` line in `Containerfile` is pinned to a digest, moved weekly by CI (see Updates and rollback). By hand:

```bash
curl -fsSL "https://quay.io/api/v1/repository/centos-bootc/centos-bootc/tag/?specificTag=stream9&onlyActiveTags=true" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['tags'][0]['manifest_digest'])"
```

Test record: base digest `b4d1a0da5ceb` (2026-11-05; kernel 5.14.0-761, NVIDIA 620.70.06, CUDA 13.5) on Hubbard, Nov 6 2026: boots, `nvidia-smi`, a CUDA program, `cuda-checkpoint` checkpoint/restore, GDM greeter, LDAP, HTCondor token auth, `/scratch`, `/data`, `/dmj`, TSO off and the runner in all three orgs OK. The base brought `clevis-dracut` (`50-bootc-clevis.conf`, omitted in `ift-workstation-initramfs.conf`) and dkms 3.4, whose `post_transaction` dracut run fails in the container (switched off in the DKMS layer).

## Open items (as of June 2026)

- Dominika Zgid has no FUW LDAP account yet; add uid to `simple_allow_users` and `scratch-homedirs.service` once known
- No host is currently named Luttinger (the former Luttinger was renamed Tomonaga in DNS, Sep 2026)
