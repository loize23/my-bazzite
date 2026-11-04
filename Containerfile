# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx
COPY build_files /
COPY system_files /system_files

# Base Image: the same one your PC runs now
FROM ghcr.io/ublue-os/bazzite-nvidia-open:stable AS base

# Stage 1 (temporary): compile the gpu_unlock module and generate its firmware
FROM base AS gpu-unlock-builder
# "main" = newest version. Once a build works, replace it with a commit hash to pin it.
ARG GPU_UNLOCK_REF=main
RUN --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    KVER=$(rpm -q kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}' | tail -1) && \
    dnf5 install -y gcc make git "kernel-devel-${KVER}" kernel-headers python3 curl xz zstd && \
    git clone https://github.com/Zagitta/gpu-unlock /tmp/gpu-unlock && \
    cd /tmp/gpu-unlock && \
    git checkout "${GPU_UNLOCK_REF}" && \
    mkdir -p /output /tmp/gpu-unlock-cache/inputs /tmp/gpu-unlock-cache/assets && \
    make CACHE=/tmp/gpu-unlock-cache assets && \
    make DESTDIR=/output ASSETS=/tmp/gpu-unlock-cache/assets install-firmware install-dracut && \
    mv /output/usr/lib/dracut/dracut.conf.d/gpu-unlock.conf /output/usr/lib/dracut/dracut.conf.d/00-gpu-unlock.conf && \
    make -C kernel/gpu_unlock KDIR=/usr/lib/modules/${KVER}/build && \
    mkdir -p /output/usr/lib/modules/${KVER}/extra && \
    install -m 0644 kernel/gpu_unlock/gpu_unlock.ko /output/usr/lib/modules/${KVER}/extra/

# Stage 2: the final image
FROM base
COPY --from=gpu-unlock-builder /output/ /

### MODIFICATIONS
## make modifications desired in your image and install packages by modifying the build.sh script
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build.sh

# Rebuild the boot image (initramfs) so it includes gpu_unlock, loaded before nvidia
RUN KVER=$(rpm -q kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}' | tail -1) && \
    depmod -a "${KVER}" && \
    dracut --no-hostonly --kver "${KVER}" --reproducible --zstd -v --add ostree -f "/usr/lib/modules/${KVER}/initramfs.img" && \
    chmod 0600 "/usr/lib/modules/${KVER}/initramfs.img"

### LINTING
## Verify final image and contents are correct.
RUN bootc container lint
