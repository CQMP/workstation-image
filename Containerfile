# syntax=docker/dockerfile:1
FROM quay.io/centos-bootc/centos-bootc:stream9

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

# NVIDIA CUDA repo — module_hotfixes bypasses AppStream modular filtering
RUN dnf install -y \
    https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm \
    && dnf clean all

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
    && dnf remove -y kernel-devel-${KVER} \
    && dnf clean all

COPY etc/sssd/sssd.conf /etc/sssd/sssd.conf
RUN --mount=type=secret,id=ldap_password \
    sed -i "s/ldap_default_authtok = CHANGE_ME/ldap_default_authtok = $(cat /run/secrets/ldap_password)/" /etc/sssd/sssd.conf \
    && chmod 600 /etc/sssd/sssd.conf

COPY etc/auto.master /etc/auto.master
RUN sed -i 's/^automount:.*/automount: sss/' /etc/nsswitch.conf \
    || echo 'automount: sss' >> /etc/nsswitch.conf

COPY etc/systemd/system/data.mount /etc/systemd/system/data.mount
RUN systemctl enable data.mount

COPY etc/NetworkManager/conf.d/hostname.conf /etc/NetworkManager/conf.d/hostname.conf

RUN mkdir -p /etc/ssh/authorized_keys.d /data
COPY etc/ssh/authorized_keys.d/egull /etc/ssh/authorized_keys.d/egull
RUN chmod 644 /etc/ssh/authorized_keys.d/egull


