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
    # LDAP/auth (stubbed for now)
    sssd \
    sssd-ldap \
    sssd-tools \
    oddjob \
    oddjob-mkhomedir \
    authselect \
    && dnf clean all

RUN systemctl enable gdm \
    && systemctl enable sshd \
    && systemctl enable sssd \
    && systemctl enable oddjobd

# Add NVIDIA repo
RUN dnf install -y \
    https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm \
    && dnf clean all

RUN dnf config-manager --add-repo \
    https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-rhel9.repo \
    && dnf clean all

RUN dnf install -y \
    cuda-toolkit-12 \
    nvidia-driver \
    nvidia-driver-libs \
    nvidia-driver-cuda \
    kmod-nvidia-latest-dkms \
    && dnf clean all

COPY etc/sssd/sssd.conf /etc/sssd/sssd.conf
RUN --mount=type=secret,id=ldap_password \
    sed -i "s/ldap_default_authtok = CHANGE_ME/ldap_default_authtok = $(cat /run/secrets/ldap_password)/" /etc/sssd/sssd.conf \
    && chmod 600 /etc/sssd/sssd.conf

RUN mkdir -p /etc/ssh/authorized_keys.d
COPY etc/ssh/authorized_keys.d/egull /etc/ssh/authorized_keys.d/egull
RUN chmod 644 /etc/ssh/authorized_keys.d/egull


