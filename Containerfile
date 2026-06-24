# syntax=docker/dockerfile:1
# Pin to a specific digest so BuildKit layer cache survives across builds.
# Update this digest periodically (monthly) to pick up base OS security patches:
#   curl -fsSL "https://quay.io/api/v1/repository/centos-bootc/centos-bootc/tag/?specificTag=stream9&onlyActiveTags=true" \
#     | python3 -c "import sys,json; print(json.load(sys.stdin)['tags'][0]['manifest_digest'])"
FROM quay.io/centos-bootc/centos-bootc:stream9@sha256:32c6d2d51c99a3d20678f786a1fb388f04afcdfd97b7987dfc108673896f1596

RUN dnf install -y \
    # Desktop
    gnome-shell \
    gdm \
    gnome-terminal \
    gnome-session \
    # Dev tools
    gcc \
    gcc-c++ \
    gcc-gfortran \
    make \
    cmake \
    git \
    python3 \
    python3-pip \
    python3-devel \
    # Node.js (prerequisite for per-user Claude Code: npm install -g @anthropic-ai/claude-code)
    nodejs \
    npm \
    # GRUB EFI tools (for rebuilding USB installer EFI binaries)
    grub2-efi-x64-modules \
    grub2-tools-extra \
    # SSH
    openssh-server \
    # LDAP/auth
    sssd \
    sssd-ldap \
    sssd-tools \
    oddjob \
    oddjob-mkhomedir \
    authselect \
    # NFS/autofs for home directories
    autofs \
    nfs-utils \
    && dnf clean all

RUN systemctl enable gdm \
    && systemctl enable sshd \
    && systemctl enable sssd \
    && systemctl enable oddjobd \
    && systemctl enable autofs

RUN authselect select sssd with-mkhomedir --force

# EPEL + CRB (CodeReady Builder) — CRB provides eigen3-devel and HTCondor deps
RUN dnf install -y \
    https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm \
    && dnf config-manager --set-enabled crb \
    && dnf clean all

# MPI implementations + environment-modules for switching between them
RUN dnf install -y \
    environment-modules \
    openmpi \
    openmpi-devel \
    mpich \
    mpich-devel \
    && dnf clean all

# HDF5: serial and parallel builds for both MPI implementations
RUN dnf install -y \
    hdf5 \
    hdf5-devel \
    hdf5-openmpi \
    hdf5-openmpi-devel \
    hdf5-mpich \
    hdf5-mpich-devel \
    && dnf clean all

# Numerical and physics libraries (GREEN, ALPS, ALPSCore, pySCF prerequisites)
#   - openblas: BLAS/LAPACK (GREEN requires vendor BLAS; OpenBLAS is a good default)
#   - eigen3: required by GREEN >= 3.4.0 and ALPSCore
#   - boost: required by ALPS and ALPSCore
#   - fftw: required by many QMC codes
#   - gmp/gmpxx/mpfr: required by GREEN analytical continuation (Caratheodory) module
#   - libxc: exchange-correlation functionals (pySCF optional but recommended)
RUN dnf install -y \
    openblas \
    openblas-devel \
    eigen3-devel \
    boost \
    boost-devel \
    fftw \
    fftw-devel \
    fftw-libs \
    gmp \
    gmp-devel \
    mpfr-devel \
    libxc \
    libxc-devel \
    && dnf clean all

# Plotting
RUN dnf install -y \
    grace \
    && dnf clean all

# Python scientific stack
# numba, spglib, ase (needed by green-mbtools) are not in RPM repos — install via pip per-user
RUN dnf install -y \
    python3-numpy \
    python3-scipy \
    python3-h5py \
    python3-mpi4py-openmpi \
    python3-mpi4py-mpich \
    && dnf clean all

# Globus Connect Personal — users authenticate per-account at first run
RUN curl -fsSL \
        "https://downloads.globus.org/globus-connect-personal/linux/stable/globusconnectpersonal-latest.tgz" \
        | tar -xz -C /opt \
    && ln -s /opt/globusconnectpersonal/globusconnectpersonal /usr/local/bin/globusconnectpersonal

# GCC toolsets 13–15 (three latest) — each includes C, C++, and Fortran (gfortran)
# Activate with: source /opt/rh/gcc-toolset-N/enable  or  scl enable gcc-toolset-N bash
RUN dnf install -y \
    gcc-toolset-13 gcc-toolset-13-gcc-gfortran \
    gcc-toolset-14 gcc-toolset-14-gcc-gfortran \
    gcc-toolset-15 gcc-toolset-15-gcc-gfortran \
    && dnf clean all

# Clang/LLVM — CentOS Stream 9 ships one version updated in-place (currently 22.x)
# No parallel versioned installs and no LLVM Fortran (flang) in AppStream
RUN dnf install -y \
    clang \
    clang-devel \
    && dnf clean all

# HTCondor execute node
RUN dnf install -y \
    https://htcss-downloads.chtc.wisc.edu/repo/25.x/htcondor-release-current.el9.noarch.rpm \
    && dnf install -y condor \
    && systemctl enable condor \
    && dnf clean all

# SELinux permissive — condor requires dac_override to manage jobs as different users;
# enforcing mode blocks this and floods the console. Research workstations use auth, not MAC.
RUN sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config

# CRIU — build latest from source; EPEL 9 ships 3.x but driver >= 570 requires 4.0+
RUN dnf install -y \
        libnl3-devel \
        libcap-devel \
        libaio-devel \
        protobuf-devel \
        protobuf-c-devel \
        protobuf-c-compiler \
        python3-protobuf \
        nftables-devel \
        gnutls-devel \
        libbsd-devel \
        libdrm-devel \
        libnet-devel \
        libuuid-devel \
    && CRIU_TAG=$(git ls-remote --tags https://github.com/checkpoint-restore/criu.git 'v[0-9]*.[0-9]*' \
           | grep -v '\^{}' | awk '{print $2}' | sed 's|refs/tags/||' | sort -V | tail -1) \
    && curl -fsSL \
        "https://github.com/checkpoint-restore/criu/archive/refs/tags/${CRIU_TAG}.tar.gz" \
        | tar -xz -C /tmp \
    && make -C /tmp/criu-${CRIU_TAG#v} -j$(nproc) \
    && make -C /tmp/criu-${CRIU_TAG#v} install-criu \
    && rm -rf /tmp/criu-${CRIU_TAG#v} \
    && dnf clean all

# Printing — CUPS + OpenPrinting PPD database (includes Sharp MX-C358F)
# Users configure the printer via Settings → Printers on first login
RUN dnf install -y \
    cups \
    cups-client \
    cups-filters \
    foomatic \
    foomatic-db \
    foomatic-db-ppds \
    system-config-printer \
    && systemctl enable cups \
    && dnf clean all

# NVIDIA CUDA repo — module_hotfixes bypasses AppStream modular filtering
RUN dnf config-manager --add-repo \
    https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-rhel9.repo \
    && echo 'module_hotfixes=1' >> /etc/yum.repos.d/cuda-rhel9.repo \
    && dnf module disable nvidia-driver -y \
    && dnf clean all

# Latest NVIDIA driver + CUDA toolkit — all from official NVIDIA repo, no version mixing
RUN dnf install -y \
    nvidia-driver \
    nvidia-driver-libs \
    nvidia-driver-cuda \
    cuda-toolkit \
    dkms \
    && dnf clean all

# Blacklist nouveau before dracut so the rule is embedded in the initramfs.
# Without this, nouveau loads from the initramfs before the real rootfs mounts,
# defeating the modprobe.d blacklist on the live system.
COPY etc/modprobe.d/blacklist-nouveau.conf /etc/modprobe.d/blacklist-nouveau.conf
COPY etc/dracut.conf.d/blacklist-nouveau.conf /etc/dracut.conf.d/blacklist-nouveau.conf
COPY etc/dracut.conf.d/omit-nvidia-initramfs.conf /etc/dracut.conf.d/omit-nvidia-initramfs.conf
COPY etc/dracut.conf.d/ift-workstation-initramfs.conf /etc/dracut.conf.d/ift-workstation-initramfs.conf

# Build NVIDIA kernel module in-image using DKMS
RUN KVER=$(rpm -q kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -1) \
    && NVIDIA_VER=$(rpm -q kmod-nvidia-latest-dkms --queryformat '%{VERSION}\n') \
    && dnf install -y kernel-devel-${KVER} \
    && dkms build nvidia/${NVIDIA_VER} -k ${KVER} \
    && dkms install nvidia/${NVIDIA_VER} -k ${KVER} \
    && find /usr/lib/modules/${KVER} -name "nvidia.ko*" | grep -q . \
    && mkdir -p /tmp/fw-save \
    && find /usr/lib/firmware -maxdepth 1 -mindepth 1 -type d -exec mv {} /tmp/fw-save/ \; \
    && mkdir -p /usr/lib/firmware/i915 \
    && xz -dc /tmp/fw-save/i915/mtl_dmc.bin.xz > /usr/lib/firmware/i915/mtl_dmc.bin \
    && xz -dc /tmp/fw-save/i915/mtl_guc_70.bin.xz > /usr/lib/firmware/i915/mtl_guc_70.bin \
    && dracut --force \
        --omit-drivers 'nouveau nvidia nvidia_drm nvidia_uvm nvidia_modeset' \
        --install '/usr/lib/firmware/i915/mtl_dmc.bin /usr/lib/firmware/i915/mtl_guc_70.bin' \
        /boot/initramfs-${KVER}.img ${KVER} \
    && install -m 0644 /boot/initramfs-${KVER}.img /usr/lib/modules/${KVER}/initramfs.img \
    && lsinitrd /boot/initramfs-${KVER}.img | grep -q 'usr/lib/firmware/i915/mtl_dmc.bin' \
    && lsinitrd /boot/initramfs-${KVER}.img | grep -q 'usr/lib/firmware/i915/mtl_guc_70.bin' \
    && ls -lh /boot/initramfs-${KVER}.img \
    && ls -lh /usr/lib/modules/${KVER}/initramfs.img \
    && rm /usr/lib/firmware/i915/mtl_dmc.bin /usr/lib/firmware/i915/mtl_guc_70.bin \
    && rmdir /usr/lib/firmware/i915 \
    && find /tmp/fw-save -maxdepth 1 -mindepth 1 -exec mv {} /usr/lib/firmware/ \; \
    && rpm -e --nodeps kernel-devel-${KVER} kernel-devel-matched-${KVER} \
    && dnf clean all

# cuda-checkpoint — pre-built binary committed in repo at bin/x86_64_Linux/
RUN curl -fsSL \
        "https://raw.githubusercontent.com/NVIDIA/cuda-checkpoint/main/bin/x86_64_Linux/cuda-checkpoint" \
        -o /usr/local/bin/cuda-checkpoint \
    && chmod 755 /usr/local/bin/cuda-checkpoint

# Diagnostic/optional tools — separate block so additions don't invalidate expensive layers above
RUN dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo \
    && dnf install -y \
    openldap-clients \
    pciutils \
    hwloc \
    grubby \
    gh \
    && dnf clean all

# Firefox browser
RUN dnf install -y firefox && dnf clean all

# Google Chrome — via official Google RPM repo
RUN printf '[google-chrome]\nname=google-chrome\nbaseurl=https://dl.google.com/linux/chrome/rpm/stable/x86_64\nenabled=1\ngpgcheck=1\ngpgkey=https://dl.google.com/linux/linux_signing_key.pub\n' \
        > /etc/yum.repos.d/google-chrome.repo \
    && dnf install -y google-chrome-stable \
    && dnf clean all

# Slack — packagecloud fedora/21 channel; the auto-detect script generates an el/9 URL
# that doesn't exist, so we set the repo file directly.
# gpgcheck=0: Slack's RPM signing key URL has moved and is unreliable; the download
# is over HTTPS from a known source so this is acceptable in a CI build.
RUN printf '[slack]\nname=Slack\nbaseurl=https://packagecloud.io/slacktechnologies/slack/fedora/21/x86_64\nenabled=1\ngpgcheck=0\nrepo_gpgcheck=0\n' \
        > /etc/yum.repos.d/slack.repo \
    && dnf install -y slack \
    && dnf clean all

# Sublime Text — its current RPM is RSA/SHA-256 signed, but the signing key's
# self-signature uses SHA-1. EL9 therefore needs the narrow SHA1 subpolicy only
# while importing that exact key; restore DEFAULT before installing the RPM.
RUN dnf install -y gnupg2 crypto-policies-scripts \
    && install -d -m 700 /tmp/sublime-gnupg \
    && curl -fsSLo /tmp/sublimehq-pub.gpg \
        https://download.sublimetext.com/sublimehq-pub.gpg \
    && GNUPGHOME=/tmp/sublime-gnupg gpg --batch --quiet --no-autostart \
        --import /tmp/sublimehq-pub.gpg \
    && GNUPGHOME=/tmp/sublime-gnupg gpg --batch --quiet --no-autostart \
        --armor --export 1B64279675A4299DCFC70858CA464A9A222D23D0 \
        > /etc/pki/rpm-gpg/RPM-GPG-KEY-sublimehq \
    && test "$(GNUPGHOME=/tmp/sublime-gnupg gpg --batch --no-autostart \
        --show-keys --with-colons \
        /etc/pki/rpm-gpg/RPM-GPG-KEY-sublimehq \
        | awk -F: '$1 == "fpr" { print $10; exit }')" \
        = 1B64279675A4299DCFC70858CA464A9A222D23D0 \
    && test "$(update-crypto-policies --show)" = DEFAULT \
    && update-crypto-policies --set DEFAULT:SHA1 \
    && rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-sublimehq \
    && update-crypto-policies --set DEFAULT \
    && printf '[sublime-text]\nname=Sublime Text - x86_64 - stable\nbaseurl=https://download.sublimetext.com/rpm/stable/x86_64\nenabled=1\ngpgcheck=1\ngpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-sublimehq\n' \
        > /etc/yum.repos.d/sublime-text.repo \
    && dnf install -y sublime-text \
    && dnf clean all \
    && rm -rf /tmp/sublime-gnupg /tmp/sublimehq-pub.gpg

# Element (Matrix client) — tarball from packages.element.io (Element dropped RPM packaging)
RUN curl -fsSL \
        "https://packages.element.io/desktop/install/linux/glibc-x86-64/element-desktop.tar.gz" \
        | tar -xz -C /opt \
    && mv /opt/element-desktop-* /opt/element-desktop \
    && chmod 4755 /opt/element-desktop/chrome-sandbox \
    && curl -fsSLo /opt/element-desktop/element.png \
        "https://raw.githubusercontent.com/element-hq/element-desktop/develop/build/icon.png" \
    && ln -s /opt/element-desktop/element-desktop /usr/local/bin/element-desktop \
    && printf '[Desktop Entry]\nVersion=1.0\nType=Application\nName=Element\nIcon=/opt/element-desktop/element.png\nExec=/opt/element-desktop/element-desktop %%u\nCategories=Network;InstantMessaging;\nTerminal=false\nStartupWMClass=Element\n' \
        > /usr/share/applications/element-desktop.desktop

# GNOME utilities — file manager, viewers, system tools, text editor, keyring UI
RUN dnf install -y \
    nautilus \
    gnome-tweaks \
    evince \
    eog \
    file-roller \
    gnome-calculator \
    gnome-disk-utility \
    gnome-system-monitor \
    baobab \
    gedit \
    seahorse \
    && dnf clean all

# TigerVNC server — remote desktop; each user manages their own session via systemd --user
RUN dnf install -y \
    tigervnc-server \
    && dnf clean all

# Image processing and PostScript tools
RUN dnf install -y \
    ghostscript \
    ImageMagick \
    && dnf clean all

# CLion — latest stable release, system-wide install in /opt/clion (bundles its own JBR)
RUN CLION_VER=$(curl -fsSL \
        "https://data.services.jetbrains.com/products/releases?code=CL&latest=true&type=release" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['CL'][0]['version'])") \
    && curl -fsSL "https://download.jetbrains.com/cpp/CLion-${CLION_VER}.tar.gz" \
        | tar -xz -C /opt \
    && mv /opt/clion-${CLION_VER} /opt/clion \
    && ln -s /opt/clion/bin/clion /usr/local/bin/clion \
    && printf '[Desktop Entry]\nVersion=1.0\nType=Application\nName=CLion\nIcon=/opt/clion/bin/clion.svg\nExec=/opt/clion/bin/clion %%f\nCategories=Development;IDE;\nTerminal=false\nStartupWMClass=jetbrains-clion\n' \
        > /usr/share/applications/clion.desktop

# Eclipse CDT — C/C++ IDE with CDT, CMake, EGit, and bundled JRE; update tag periodically
# Releases: https://download.eclipse.org/technology/epp/downloads/release/
RUN curl -fsSL \
        "https://download.eclipse.org/technology/epp/downloads/release/2026-06/R/eclipse-cpp-2026-06-R-linux-gtk-x86_64.tar.gz" \
        | tar -xz -C /opt \
    && ln -s /opt/eclipse/eclipse /usr/local/bin/eclipse \
    && printf '[Desktop Entry]\nVersion=1.0\nType=Application\nName=Eclipse CDT\nIcon=/opt/eclipse/icon.xpm\nExec=/opt/eclipse/eclipse\nCategories=Development;IDE;\nTerminal=false\nStartupWMClass=Eclipse\n' \
        > /usr/share/applications/eclipse-cdt.desktop

# LaTeX — all packages via dnf (AppStream + EPEL); no TUG installer needed.
# texlive-scheme-full is not packaged for CentOS 9, but individual packages cover
# all typical physics paper needs: revtex4 (APS), IEEEtran, siunitx, pgf/tikz,
# bibtex, natbib, beamer, amsmath/fonts, hyperref, and standard font families.
RUN dnf install -y \
    texlive \
    texlive-collection-basic \
    texlive-collection-latex \
    texlive-collection-latexrecommended \
    texlive-collection-fontsrecommended \
    texlive-collection-xetex \
    texlive-revtex4 \
    texlive-IEEEtran \
    texlive-siunitx \
    texlive-pgf \
    texlive-pgfplots \
    texlive-bibtex \
    texlive-natbib \
    texlive-amsmath \
    texlive-amsfonts \
    texlive-amscls \
    texlive-beamer \
    texlive-mathtools \
    texlive-booktabs \
    texlive-hyperref \
    texlive-geometry \
    texlive-caption \
    texlive-subfig \
    texlive-wrapfig \
    texlive-listings \
    texlive-enumitem \
    texlive-fancyhdr \
    texlive-microtype \
    texlive-mhchem \
    texlive-xcolor \
    texlive-multirow \
    texlive-float \
    texlive-tcolorbox \
    texlive-lineno \
    texlive-placeins \
    texlive-appendix \
    texlive-xetex \
    texlive-luatex \
    texlive-dvipng \
    texlive-dvips \
    texlive-epstopdf \
    texlive-cm-super \
    texlive-lm \
    texlive-lm-math \
    texlive-newtx \
    texlive-txfonts \
    && dnf clean all
RUN mkdir -p /var/lib/texmf/web2c \
    && fmtutil-sys --byfmt pdflatex \
    && ln -sf pdftex/pdflatex.fmt /var/lib/texmf/web2c/pdflatex.fmt \
    && mktexlsr /var/lib/texmf

# Intel i915 firmware ships as .xz in the linux-firmware RPM. CentOS 9's 5.14 kernel
# may not have CONFIG_FW_LOADER_COMPRESS_XZ enabled, so create uncompressed copies.
# Do not use `xz -d`: RPM firmware files have multiple hard links, which xz skips.
RUN find /usr/lib/firmware/i915 -type f -name "*.xz" -exec \
        sh -c 'for source do xz -dc "$source" > "${source%.xz}"; done' sh {} + \
    && test -s /usr/lib/firmware/i915/mtl_dmc.bin \
    && test -s /usr/lib/firmware/i915/mtl_guc_70.bin

# Small config adjustments — at the end to avoid cache churn on expensive layers above
# Keep both the bootc /etc defaults and the immutable unit fallback pointed at GDM.
RUN ln -sf /usr/lib/systemd/system/graphical.target /etc/systemd/system/default.target \
    && ln -sf /usr/lib/systemd/system/gdm.service /etc/systemd/system/display-manager.service \
    && ln -sf graphical.target /usr/lib/systemd/system/default.target \
    && ln -sf gdm.service /usr/lib/systemd/system/display-manager.service

# ── Config files ────────────────────────────────────────────────────────────
# All COPY instructions are grouped here, after all expensive build layers,
# so that editing a config file does not invalidate the package/build cache.

COPY etc/condor/config.d/00-ift-execute.conf /etc/condor/config.d/00-ift-execute.conf
RUN --mount=type=secret,id=condor_token \
    mkdir -p /etc/condor/tokens.d \
    && cp /run/secrets/condor_token /etc/condor/tokens.d/pool-token \
    && chown root:root /etc/condor/tokens.d /etc/condor/tokens.d/pool-token \
    && chmod 700 /etc/condor/tokens.d \
    && chmod 600 /etc/condor/tokens.d/pool-token

# Kernel arguments (bootc reads these from /usr/lib/bootc/kargs.d/ at deployment time)
COPY usr/lib/bootc/kargs.d/audit.toml /usr/lib/bootc/kargs.d/audit.toml
COPY usr/lib/bootc/kargs.d/nvidia.toml /usr/lib/bootc/kargs.d/nvidia.toml

# HiDPI: 2x scaling for user sessions and GDM login screen
COPY etc/vconsole.conf /etc/vconsole.conf
COPY etc/X11/xorg.conf.d/00-keyboard.conf /etc/X11/xorg.conf.d/00-keyboard.conf
COPY etc/dconf/profile/user /etc/dconf/profile/user
COPY etc/dconf/db/local.d/01-hidpi /etc/dconf/db/local.d/01-hidpi
COPY etc/dconf/db/gdm.d/01-hidpi /etc/dconf/db/gdm.d/01-hidpi
RUN dconf update

COPY etc/sudoers.d/egull /etc/sudoers.d/egull
RUN chmod 440 /etc/sudoers.d/egull


COPY etc/sssd/sssd.conf /etc/sssd/sssd.conf
RUN --mount=type=secret,id=ldap_password \
    sed -i "s/ldap_default_authtok = CHANGE_ME/ldap_default_authtok = $(cat /run/secrets/ldap_password)/" /etc/sssd/sssd.conf \
    && chmod 600 /etc/sssd/sssd.conf

COPY etc/auto.master /etc/auto.master
RUN mkdir -p /dmj /expo /repo
RUN sed -i 's/^automount:.*/automount: files sss/' /etc/nsswitch.conf \
    || echo 'automount: files sss' >> /etc/nsswitch.conf

COPY etc/systemd/system/data.mount /etc/systemd/system/data.mount
COPY etc/systemd/system/data-homedirs.service /etc/systemd/system/data-homedirs.service
COPY etc/systemd/system/bootc-update.service /etc/systemd/system/bootc-update.service
COPY etc/systemd/system/bootc-update.timer /etc/systemd/system/bootc-update.timer
RUN systemctl enable data.mount \
    && systemctl enable data-homedirs.service \
    && systemctl enable bootc-update.timer \
    && systemctl mask bootc-fetch-apply-updates.timer bootc-fetch-apply-updates.service kdump.service

COPY etc/NetworkManager/conf.d/hostname.conf /etc/NetworkManager/conf.d/hostname.conf

RUN mkdir -p /etc/ssh/authorized_keys.d /etc/ssh/sshd_config.d /root/.ssh /data
COPY etc/ssh/sshd_config.d/50-ift.conf /etc/ssh/sshd_config.d/50-ift.conf
COPY etc/ssh/authorized_keys.d/egull /etc/ssh/authorized_keys.d/egull
COPY root/.ssh/authorized_keys /root/.ssh/authorized_keys
RUN chmod 644 /etc/ssh/sshd_config.d/50-ift.conf /etc/ssh/authorized_keys.d/egull \
    && chmod 700 /root/.ssh \
    && chmod 600 /root/.ssh/authorized_keys
