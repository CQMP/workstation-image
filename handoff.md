Handoff: CentOS Stream 9 bootc Workstation Image Setup

## Context
Setting up 10 diskless Dell workstations (Dell Pro Max Tower T2, RTX 2000 Ada GPU) for a
multi-user academic environment at IFT (Institute of Theoretical Physics), Faculty of Physics,
University of Warsaw (FUW). Using bootc (image-based OS provisioning) with GitHub Container
Registry.

## Key Decisions
- OS: CentOS Stream 9 base (quay.io/centos-bootc/centos-bootc:stream9) — the only publicly
  available bootc base image for the RHEL 9 family; Rocky Linux 9 has no official bootc
  base image
- Provisioning: bootc (pull-based, no on-prem provisioning daemon)
- Registry: ghcr.io/cqmp/centos9-workstation:latest (public)
- GitHub org: cqmp, admin user: egull
- Repo: github.com/CQMP/workstation-image (public)
- Desktop: GNOME with GDM and SSH enabled
- Auth: SSSD + LDAP (see details below)
- Dev tools: Python, C++, Fortran (gcc-gfortran), CUDA 12.x
- GPU drivers: NVIDIA proprietary via CUDA RPM repo + DKMS
- Updates: Automatic weekly pull+reboot, Sunday 4am UTC (one hour after CI rebuild at 3am UTC)
- Admin SSH: egull on all nodes; per-node second user TBD

## Repo Structure
```
Containerfile                              # Main image definition
etc/sssd/sssd.conf                         # SSSD config (bind password injected at build time)
etc/ssh/authorized_keys.d/egull            # egull's SSH public key
etc/condor/config.d/00-ift-execute.conf    # HTCondor execute node config
etc/systemd/system/bootc-update.service   # Stages update + reboots
etc/systemd/system/bootc-update.timer     # Fires Sun 04:00 UTC
.github/workflows/build.yml               # CI: builds and pushes to GHCR on push + weekly
```

## LDAP / Authentication

### Server
- **Host:** `das.fuw.edu.pl` → `ccdas1.fuw.edu.pl` → `10.2.5.11`
- **Protocol:** LDAPS on port 636 (TLS cert issued by GEANT, valid to Sep 2026)
- **Base DN:** `ou=fizyk,ou=unixAuth,dc=das,dc=fuw,dc=edu,dc=pl`
- **User entries:** `posixAccount` with full Unix attributes (uid/gid numbers, home dir under
  `/dmj/ift1/`, shell). Confirmed working — `getent passwd` on fizyk1 resolves via this tree.

### Bind Account
- Proxy accounts live at:
  `cn=<name>,ou=CC,ou=unixFizyk,ou=proxyAgents,dc=das,dc=fuw,dc=edu,dc=pl`
- Existing example: `cn=hprxFizyk1` (used by fizyk1, found in fizyk1:/etc/ldap.conf)
- **Requested:** `cn=hprxGullZgidWS` — email sent to Krzysztof Szymaszczyk
  (krzysztof.szymaszczyk@fuw.edu.pl) and Robert Budzyński (robert.budzynski@fuw.edu.pl) at OKWF

### Secrets Handling
- The bind password is injected at build time via `RUN --mount=type=secret,id=ldap_password`
- GitHub Actions secret name: `LDAP_BIND_PASSWORD` (set in repo settings)
- Currently using fizyk1's credentials as a temporary stand-in; replace once hprxGullZgidWS
  is provisioned

### sssd.conf status
- `ldap_uri` and `ldap_search_base` are correct and confirmed working
- `ldap_default_bind_dn` still has `cn=CHANGE_ME` placeholder — update once new account arrives
- `ldap_tls_reqcert = demand` (cert validates against GEANT CA, in CentOS Stream 9 trust store)

### Other LDAP notes
- FUW also has an OpenLDAP at cocos.fuw.edu.pl (193.0.80.11), base dc=fuw,dc=edu,dc=pl —
  this is an organizational directory (inetOrgPerson only, no POSIX attributes); not used here
- fizyk1 uses nss-ldap (Debian), not SSSD; our config translates that to SSSD format

## CI/CD
- Workflow: .github/workflows/build.yml
- Triggers: push to main, weekly Sunday 3am UTC
- Auth to GHCR: GITHUB_TOKEN (no extra secret needed)
- Build secrets: `LDAP_BIND_PASSWORD`, `CONDOR_POOL_TOKEN` (GitHub Actions secrets)
- Image: ghcr.io/cqmp/centos9-workstation:latest

## HTCondor

The pool central manager is `condor.gull-group.org`. Each workstation runs as an execute
node (`MASTER, STARTD`). Authentication to the collector uses an IDTOKEN baked into the image
at build time from the `CONDOR_POOL_TOKEN` GitHub Actions secret.

### Token file requirements

HTCondor's `read_secure_file` enforces strict ownership on token files:
- `/etc/condor/tokens.d/`        — `root:root`, mode `700`
- `/etc/condor/tokens.d/pool-token` — `root:root`, mode `600`

The `condor_master` process runs as root and reads the token directly. Any other ownership
or looser permissions (e.g. `condor:condor 600` or `root:condor 640`) will be rejected with
an error in MasterLog and the daemon will silently fall back to other auth methods, all of
which fail remotely.

### Verifying condor token delivery

After a machine boots a fresh image, check:

```bash
sudo ls -la /etc/condor/tokens.d/
# expect: drwx------ root:root  (directory)
#         -rw------- root:root  pool-token

condor_status $(hostname)
# expect: machine appears as a slot
```

If the STARTD logs show any of these, the token is wrong or missing:
```
read_secure_file(...): file must be owned by uid 0
read_secure_file(...): file must not be readable by others
SECMAN: required authentication with collector condor.gull-group.org failed
Collector update failed; will try to get a token request for trust domain ...
```

### Immediate fix for a machine with bad token permissions

```bash
sudo chown root:root /etc/condor/tokens.d /etc/condor/tokens.d/pool-token
sudo chmod 700 /etc/condor/tokens.d
sudo chmod 600 /etc/condor/tokens.d/pool-token
sudo systemctl restart condor
```

### Immediate fix for a machine running a stale image (token missing entirely)

```bash
sudo bootc upgrade && sudo reboot
```

If the token is still missing after upgrading, check whether `CONDOR_POOL_TOKEN` is set in
GitHub Actions secrets and whether the last CI build succeeded.

### Generating a new token (on the central manager)

```bash
# On condor.gull-group.org:
condor_token_create -identity condor@<hostname> > /tmp/<hostname>-token
scp /tmp/<hostname>-token egull@<hostname>:/tmp/
# On the workstation:
sudo cp /tmp/<hostname>-token /etc/condor/tokens.d/pool-token
sudo chown root:root /etc/condor/tokens.d/pool-token
sudo chmod 600 /etc/condor/tokens.d/pool-token
sudo systemctl restart condor
```

## Updating machines

The image rebuilds every Sunday at 3am UTC (and on every push to main). Machines
auto-update and reboot Sunday at 4am UTC via `bootc-update.timer`.

To update a machine immediately:

```bash
sudo bootc upgrade && sudo reboot
```

To check what image a machine is currently running:

```bash
bootc status
```

## Open Items
1. **LDAP bind account:** Waiting for hprxGullZgidWS from OKWF admins; update
   `ldap_default_bind_dn` in sssd.conf and rotate `LDAP_BIND_PASSWORD` secret
2. **Per-node second user:** Mechanism TBD — users not yet known
3. **Home directories:** fizyk1 mounts homes from `/dmj/ift1/` (NFS/autofs); workstations
   will need the same autofs/NFS config — not yet in the image
4. **Per-node configuration:** bootc is a single image for all nodes; any per-node differences
   (hostname, second user) need a separate mechanism (e.g., cloud-init, ignition, or a
   post-boot script)
