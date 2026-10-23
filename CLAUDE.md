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
| `etc/sssd/sssd.conf` | LDAP auth via SSSD; bind password injected at build time via `--mount=type=secret` |
| `etc/condor/config.d/00-ift-execute.conf` | HTCondor execute-node policy; idle start, CRIU checkpointing |
| `etc/systemd/system/bootc-update.{service,timer}` | Automatic `bootc upgrade && reboot` every Sunday 04:00 UTC |
| `etc/systemd/system/data.{mount,automount}` | Automounts `/data` via NFSv4.2 from `luttinger-storage` (`10.98.2.4:/data`) |
| `etc/systemd/system/scratch.mount` | Mounts local NVMe scratch partition (label `data`) at `/scratch` |
| `etc/systemd/system/scratch-homedirs.service` | Creates `/scratch/<user>/` dirs for each allowed user on boot |
| `etc/systemd/system/cups-printers.service` | Registers shared network printers (e.g. Sharp MX-C358F) with CUPS on boot, driverlessly via IPP Everywhere |
| `etc/auto.master` | autofs mounts for `/dmj`, `/expo`, `/repo` and peer workstation scratch disks |
| `etc/auto.shared_scratch` | autofs map for `/shared_scratch/<host>` NFS mounts of workstation `/scratch` disks |
| `etc/exports.d/scratch.exports` | NFS export of local `/scratch` to the workstation subnet |
| `usr/lib/bootc/kargs.d/nvidia.toml` | Kernel args: `nvidia-drm.modeset=1`, `modprobe.blacklist=nouveau` |
| `etc/profile.d/cuda.sh` | Appends `/usr/local/cuda/bin` (nvcc, cuda-gdb) to the PATH |
| `etc/dracut.conf.d/` | Initramfs tuning: nouveau blacklisted in initrd; modules stripped for small image |
| `machines.md` | Machine inventory: names, MACs, IPs (10.42.1.40–50) |
| `.github/workflows/build.yml` | CI: build + push to GHCR on every push to `main` and weekly Sunday 00:17 UTC (well ahead of the 04:00 UTC `bootc-update.timer`; GitHub starts scheduled runs up to ~1.5h late) |

## Secrets (GitHub Actions)

Two secrets must be set in the repo's GitHub Actions settings:

- `LDAP_BIND_PASSWORD` — injected via `--mount=type=secret,id=ldap_password` into `sssd.conf`
- `CONDOR_POOL_TOKEN` — injected via `--mount=type=secret,id=condor_token` into `/etc/condor/tokens.d/pool-token`

The condor token file permissions are strict: directory `700 root:root`, file `600 root:root`. Any deviation causes silent auth failure.

## Adding packages or config

1. Edit `Containerfile` (packages) or the relevant file under `etc/`/`usr/`/`root/`
2. Push to `main` — GitHub Actions rebuilds and pushes `ghcr.io/cqmp/centos9-workstation:latest`
3. On each workstation: `sudo bootc upgrade && sudo reboot`

To add a user: add their Unix username to `simple_allow_users` in `etc/sssd/sssd.conf` **and** to the user list in `etc/systemd/system/scratch-homedirs.service`. Their `/data/<user>` dataset on `luttinger-storage` is created from the same `simple_allow_users` list by the `zfs_userdata` Ansible role in `../cluster_configuration`; rerun it after the image is pushed.

## NVIDIA / DKMS notes

The NVIDIA kernel module (open variant, `kmod-nvidia-open-dkms`; the proprietary `kmod-nvidia-latest-dkms` was discontinued at driver 615) is built in-image with DKMS (`dkms build/install`) during the container build. Secure Boot must be **disabled** on the hardware (the module is unsigned). The `omit-nvidia-initramfs.conf` dracut config ensures nvidia modules are excluded from the initramfs (loaded from the live root instead), which keeps the initramfs small enough for EFI allocation.

CUDA is installed as components (`cuda-compiler`, `cuda-libraries{,-devel}`, `cuda-command-line-tools`, `cuda-nvml-devel`, versioned like `-13-4` after the latest `cuda-toolkit`), not the `cuda-toolkit` meta-package: that adds ~2.5 GB of Nsight Systems/Compute GUIs. The image is ~14 GB compressed (~40 GB on disk). Machines installed with the old 50 GB root partition cannot stage upgrades with large layer changes (`Insufficient free space` / `min-free-space-percent '3%' would be exceeded`); `ks.cfg` now uses 200 GiB, and Kadanoff was converted in place (Oct 2026). Keep the image lean, and put small additions in late layers so they don't rebuild the big ones. `etc/profile.d/cuda.sh` puts `/usr/local/cuda/bin` on the PATH.

## HTCondor

Central manager: `condor.gull-group.org`. Each workstation runs `MASTER`, `STARTD`, and `SCHEDD`. A startd cron monitor publishes local graphical-session idle time from systemd-logind because HTCondor's `KeyboardIdle` fallback does not see GNOME input without `condor_kbdd`. Jobs start only when `LocalInteractiveIdle > 900s` and `LoadAvg < 0.5`; remote SSH sessions do not inhibit jobs. CRIU checkpointing is enabled with `cuda-checkpoint` for GPU jobs; vacate time is 1 hour.

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

The `FROM` line in `Containerfile` is pinned to a digest. Update monthly:

```bash
curl -fsSL "https://quay.io/api/v1/repository/centos-bootc/centos-bootc/tag/?specificTag=stream9&onlyActiveTags=true" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['tags'][0]['manifest_digest'])"
```

## Open items (as of June 2026)

- Dominika Zgid has no FUW LDAP account yet; add uid to `simple_allow_users` and `scratch-homedirs.service` once known
- No host is currently named Luttinger (the former Luttinger was renamed Tomonaga in DNS, Sep 2026)
