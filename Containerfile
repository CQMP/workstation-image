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
#   - gmp: required by GREEN analytical continuation module
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

# Build NVIDIA kernel module in-image using DKMS
RUN KVER=$(rpm -q kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -1) \
    && NVIDIA_VER=$(rpm -q kmod-nvidia-latest-dkms --queryformat '%{VERSION}\n') \
    && dnf install -y kernel-devel-${KVER} \
    && dkms build nvidia/${NVIDIA_VER} -k ${KVER} \
    && dkms install nvidia/${NVIDIA_VER} -k ${KVER} \
    && find /usr/lib/modules/${KVER} -name "nvidia.ko*" | grep -q . \
    && dracut --force --omit-drivers nouveau /boot/initramfs-${KVER}.img ${KVER} \
    && rpm -e --nodeps kernel-devel-${KVER} kernel-devel-matched-${KVER} \
    && dnf clean all

# cuda-checkpoint — pre-built binary committed in repo at bin/x86_64_Linux/
RUN curl -fsSL \
        "https://raw.githubusercontent.com/NVIDIA/cuda-checkpoint/main/bin/x86_64_Linux/cuda-checkpoint" \
        -o /usr/local/bin/cuda-checkpoint \
    && chmod 755 /usr/local/bin/cuda-checkpoint

# Diagnostic/optional tools — separate block so additions don't invalidate expensive layers above
RUN dnf install -y \
    openldap-clients \
    && dnf clean all

# Small config adjustments — at the end to avoid cache churn on expensive layers above
RUN systemctl set-default graphical.target

# ── Config files ────────────────────────────────────────────────────────────
# All COPY instructions are grouped here, after all expensive build layers,
# so that editing a config file does not invalidate the package/build cache.

COPY etc/condor/config.d/00-ift-execute.conf /etc/condor/config.d/00-ift-execute.conf

COPY etc/sudoers.d/egull /etc/sudoers.d/egull
RUN chmod 440 /etc/sudoers.d/egull

# Blacklist nouveau so the proprietary NVIDIA driver can claim the GPU at boot.
# install nouveau /bin/false + dracut omit_drivers ensure it never loads, even during initramfs.
COPY etc/modprobe.d/blacklist-nouveau.conf /etc/modprobe.d/blacklist-nouveau.conf
COPY etc/dracut.conf.d/blacklist-nouveau.conf /etc/dracut.conf.d/blacklist-nouveau.conf

COPY etc/sssd/sssd.conf /etc/sssd/sssd.conf
RUN --mount=type=secret,id=ldap_password \
    sed -i "s/ldap_default_authtok = CHANGE_ME/ldap_default_authtok = $(cat /run/secrets/ldap_password)/" /etc/sssd/sssd.conf \
    && chmod 600 /etc/sssd/sssd.conf

COPY etc/auto.master /etc/auto.master
RUN mkdir -p /dmj /expo /repo
RUN sed -i 's/^automount:.*/automount: files sss/' /etc/nsswitch.conf \
    || echo 'automount: files sss' >> /etc/nsswitch.conf

COPY etc/systemd/system/data.mount /etc/systemd/system/data.mount
RUN systemctl enable data.mount

COPY etc/NetworkManager/conf.d/hostname.conf /etc/NetworkManager/conf.d/hostname.conf

RUN mkdir -p /etc/ssh/authorized_keys.d /etc/ssh/sshd_config.d /root/.ssh /data
COPY etc/ssh/sshd_config.d/50-ift.conf /etc/ssh/sshd_config.d/50-ift.conf
COPY etc/ssh/authorized_keys.d/egull /etc/ssh/authorized_keys.d/egull
COPY root/.ssh/authorized_keys /root/.ssh/authorized_keys
RUN chmod 644 /etc/ssh/sshd_config.d/50-ift.conf /etc/ssh/authorized_keys.d/egull \
    && chmod 700 /root/.ssh \
    && chmod 600 /root/.ssh/authorized_keys
