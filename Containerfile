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

# Add EPEL, RPMFusion (for akmod-nvidia), and NVIDIA CUDA repo (for cuda-toolkit)
RUN dnf install -y \
    https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm \
    && dnf clean all

RUN dnf install -y \
    https://mirrors.rpmfusion.org/free/el/rpmfusion-free-release-9.noarch.rpm \
    https://mirrors.rpmfusion.org/nonfree/el/rpmfusion-nonfree-release-9.noarch.rpm \
    && dnf clean all

RUN dnf config-manager --add-repo \
    https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-rhel9.repo \
    && dnf clean all

# Disable the CentOS AppStream nvidia module so RPMFusion packages are not filtered out
RUN dnf module disable nvidia-driver -y && dnf clean all

# NVIDIA userspace driver + CUDA toolkit
RUN dnf install -y \
    akmod-nvidia \
    xorg-x11-drv-nvidia \
    xorg-x11-drv-nvidia-cuda \
    cuda-toolkit-12 \
    && dnf clean all

# Build NVIDIA kernel modules for the image's kernel
RUN KVER=$(rpm -q kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -1) \
    && dnf install -y akmods kernel-devel-${KVER} \
    && akmods --force --kernels ${KVER} \
    && modinfo /usr/lib/modules/${KVER}/extra/nvidia/nvidia.ko \
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

RUN mkdir -p /etc/ssh/authorized_keys.d /data
COPY etc/ssh/authorized_keys.d/egull /etc/ssh/authorized_keys.d/egull
RUN chmod 644 /etc/ssh/authorized_keys.d/egull


