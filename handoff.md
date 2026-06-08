Handoff: Rocky 9 bootc Workstation Image Setup

## Context
Setting up 10 diskless Dell workstations (Dell Pro Max Tower T2, RTX 2000 Ada GPU) for a
multi-user academic environment at IFT (Institute of Theoretical Physics), Faculty of Physics,
University of Warsaw (FUW). Using bootc (image-based OS provisioning) with GitHub Container
Registry.

## Key Decisions
- OS: CentOS Stream 9 base (quay.io/centos-bootc/centos-bootc:stream9) — Rocky Linux 9
  does not publish an official bootc base image; CentOS Stream 9 is the standard bootc
  base for RHEL 9 derivatives and is package-compatible
- Provisioning: bootc (pull-based, no on-prem provisioning daemon)
- Registry: ghcr.io/cqmp/rocky9-workstation:latest (public)
- GitHub org: cqmp, admin user: egull
- Repo: github.com/CQMP/workstation-image (public)
- Desktop: GNOME with GDM and SSH enabled
- Auth: SSSD + LDAP (see details below)
- Dev tools: Python, C++, Fortran (gcc-gfortran), CUDA 12.x
- GPU drivers: NVIDIA proprietary via CUDA RPM repo + DKMS
- Updates: Automatic weekly pull, Sunday 3am (GitHub Actions schedule)
- Admin SSH: egull on all nodes; per-node second user TBD

## Repo Structure
```
Containerfile                        # Main image definition
etc/sssd/sssd.conf                   # SSSD config (bind password injected at build time)
etc/ssh/authorized_keys.d/egull      # egull's SSH public key
.github/workflows/build.yml          # CI: builds and pushes to GHCR on push + weekly
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
- `ldap_tls_reqcert = demand` (cert validates against GEANT CA, in Rocky 9 trust store)

### Other LDAP notes
- FUW also has an OpenLDAP at cocos.fuw.edu.pl (193.0.80.11), base dc=fuw,dc=edu,dc=pl —
  this is an organizational directory (inetOrgPerson only, no POSIX attributes); not used here
- fizyk1 uses nss-ldap (Debian), not SSSD; our config translates that to SSSD format

## CI/CD
- Workflow: .github/workflows/build.yml
- Triggers: push to main, weekly Sunday 3am UTC
- Auth to GHCR: GITHUB_TOKEN (no extra secret needed)
- Build secret: LDAP_BIND_PASSWORD (GitHub Actions secret)
- Image: ghcr.io/cqmp/rocky9-workstation:latest

## Open Items
1. **LDAP bind account:** Waiting for hprxGullZgidWS from OKWF admins; update
   `ldap_default_bind_dn` in sssd.conf and rotate `LDAP_BIND_PASSWORD` secret
2. **Per-node second user:** Mechanism TBD — users not yet known
3. **NVIDIA/DKMS in bootc:** DKMS kernel module handling in ostree/bootc images has known
   constraints; validate against current Rocky 9 + bootc docs before first real build
4. **Home directories:** fizyk1 mounts homes from `/dmj/ift1/` (NFS/autofs); workstations
   will need the same autofs/NFS config — not yet in the image
5. **Per-node configuration:** bootc is a single image for all nodes; any per-node differences
   (hostname, second user) need a separate mechanism (e.g., cloud-init, ignition, or a
   post-boot script)
