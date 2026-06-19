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
| `Containerfile` | Full image definition — all packages, DKMS kernel module build, systemd enables |
| `ks.cfg` | Anaconda kickstart: partitions NVMe, pulls image from GHCR, triggers reboot |
| `etc/sssd/sssd.conf` | LDAP auth via SSSD; bind password injected at build time via `--mount=type=secret` |
| `etc/condor/config.d/00-ift-execute.conf` | HTCondor execute-node policy; idle start, CRIU checkpointing |
| `etc/systemd/system/bootc-update.{service,timer}` | Automatic `bootc upgrade && reboot` every Sunday 04:00 UTC |
| `etc/systemd/system/data.mount` | Mounts local NVMe `/data` scratch partition |
| `etc/systemd/system/data-homedirs.service` | Creates `/data/<user>/` dirs for each allowed user on boot |
| `etc/auto.master` | autofs mounts for `/dmj`, `/expo`, `/repo` (NFS home directories) |
| `usr/lib/bootc/kargs.d/nvidia.toml` | Kernel args: `nvidia-drm.modeset=1`, `modprobe.blacklist=nouveau` |
| `etc/dracut.conf.d/` | Initramfs tuning: nouveau blacklisted in initrd; modules stripped for small image |
| `machines.md` | Machine inventory: names, MACs, IPs (10.42.1.40–50) |
| `.github/workflows/build.yml` | CI: build + push to GHCR on every push to `main` and weekly Sunday 03:00 UTC |

## Secrets (GitHub Actions)

Two secrets must be set in the repo's GitHub Actions settings:

- `LDAP_BIND_PASSWORD` — injected via `--mount=type=secret,id=ldap_password` into `sssd.conf`
- `CONDOR_POOL_TOKEN` — injected via `--mount=type=secret,id=condor_token` into `/etc/condor/tokens.d/pool-token`

The condor token file permissions are strict: directory `700 root:root`, file `600 root:root`. Any deviation causes silent auth failure.

## Adding packages or config

1. Edit `Containerfile` (packages) or the relevant file under `etc/`/`usr/`/`root/`
2. Push to `main` — GitHub Actions rebuilds and pushes `ghcr.io/cqmp/centos9-workstation:latest`
3. On each workstation: `sudo bootc upgrade && sudo reboot`

To add a user: add their Unix username to `simple_allow_users` in `etc/sssd/sssd.conf` **and** to the user list in `etc/systemd/system/data-homedirs.service`.

## NVIDIA / DKMS notes

The NVIDIA kernel module is built in-image with DKMS (`dkms build/install`) during the container build. Secure Boot must be **disabled** on the hardware (the module is unsigned). The `omit-nvidia-initramfs.conf` dracut config ensures nvidia modules are excluded from the initramfs (loaded from the live root instead), which keeps the initramfs small enough for EFI allocation.

## HTCondor

Central manager: `condor.gull-group.org`. Each workstation runs only `MASTER` and `STARTD`. Jobs start only when `KeyboardIdle > 900s` and `LoadAvg < 0.5`. CRIU checkpointing is enabled with `cuda-checkpoint` for GPU jobs; vacate time is 1 hour.

## LDAP / Authentication

- **LDAP server:** `ldaps://ccdas1.fuw.edu.pl` (port 636, GEANT TLS cert, valid Sep 2026)
- **Base DN:** `ou=fizyk,ou=unixAuth,dc=das,dc=fuw,dc=edu,dc=pl`
- **Bind DN:** `cn=hprxGullZgidWS,ou=IFT,ou=unixFizyk,ou=proxyAgents,dc=das,dc=fuw,dc=edu,dc=pl`
- **Current allow list:** `egull, rfarid, ajazdzewska, amarie, abalbi`

If LDAP auth fails, check: (1) user exists in LDAP Unix domain, (2) user is in `simple_allow_users`, (3) user is using their Unix password (not institutional SSO).

## File systems on the workstations

- `/dmj`, `/expo`, `/repo` — NFS via autofs (home dirs, shared code, backed up)
- `/data` — local NVMe scratch, per-user dirs created by `data-homedirs.service`, **not backed up**

## Base image digest updates

The `FROM` line in `Containerfile` is pinned to a digest. Update monthly:

```bash
curl -fsSL "https://quay.io/api/v1/repository/centos-bootc/centos-bootc/tag/?specificTag=stream9&onlyActiveTags=true" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['tags'][0]['manifest_digest'])"
```

## Open items (as of June 2026)

- Dominika Zgid has no FUW LDAP account yet; add uid to `simple_allow_users` and `data-homedirs.service` once known
- MACs for Onsager, Tomonaga, Bethe, Nambu, Luttinger not yet recorded in `machines.md`
