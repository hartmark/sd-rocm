# Slim runtime image for ComfyUI / sd-webui on ROCm.
#
# torch, ROCm, MIOpen and friends come from TheRock pip wheels that functions.sh installs into the
# venv under /root (bind-mounted data/home-*), and functions.sh puts their lib dirs on LD_LIBRARY_PATH.
# So the image does not need docker.io/rocm/pytorch (~54 GB); it only carries:
#   * a standalone CPython (python-build-standalone via uv) at /usr/bin/python${PYTHON_VERSION},
#     because Ubuntu 26.04 ships only Python 3.14 and the venv / onnxruntime_rocm wheels are cp312
#   * the plain system libraries the venv's native modules load (GL/X11 for opencv, jemalloc, ...)
#   * the hsa-gentle-wait LD_PRELOAD shim, prebuilt (no compiler in the final image)
#   * librocm_smi64.so.7 from AMD's rocm-smi-lib package, needed by onnxruntime_rocm's ROCm EP
#     (ROCm 10.x nightlies only ship libamd_smi; without it face swap silently runs on CPU)
#
# Build from the repository root:  podman build -f podman-quadlets/Dockerfile -t localhost/sd-rocm:slim .
# There is no compiler in the image, so pip packages that only ship sdists cannot be built at runtime.

ARG UBUNTU_VERSION=26.04
ARG PYTHON_VERSION=3.12

FROM docker.io/library/ubuntu:${UBUNTU_VERSION} AS build
ARG PYTHON_VERSION
ARG ROCM_SMI_DEB=https://repo.radeon.com/rocm/apt/7.0/pool/main/r/rocm-smi-lib/rocm-smi-lib_7.8.0.70000-38~24.04_amd64.deb
ARG ROCM_SMI_SHA256=d7672980213746407955bf90c4fcc3f8de7f0aad17b5373d22329826f49738e0
ENV DEBIAN_FRONTEND=noninteractive
COPY --from=ghcr.io/astral-sh/uv:0.13.7 /uv /usr/local/bin/uv
RUN apt-get update && apt-get install -y --no-install-recommends \
      gcc libc6-dev ca-certificates curl binutils \
    && rm -rf /var/lib/apt/lists/*

COPY conf/hsa-gentle-wait.c /tmp/
RUN gcc -O2 -fPIC -shared -o /tmp/hsa-gentle-wait.so /tmp/hsa-gentle-wait.c -ldl

RUN UV_PYTHON_INSTALL_DIR=/opt/uvpy uv python install "${PYTHON_VERSION}" \
    && mv "$(dirname "$(dirname "$(UV_PYTHON_INSTALL_DIR=/opt/uvpy uv python find "${PYTHON_VERSION}")")")" \
          "/opt/python${PYTHON_VERSION}" \
    && "/opt/python${PYTHON_VERSION}/bin/python${PYTHON_VERSION}" -V

RUN curl -fsSL -o /tmp/smi.deb "${ROCM_SMI_DEB}" \
    && echo "${ROCM_SMI_SHA256}  /tmp/smi.deb" | sha256sum -c - \
    && mkdir /tmp/smi && cd /tmp/smi && ar x /tmp/smi.deb && tar -xzf data.tar.gz \
    && mkdir -p /opt/rocm-compat/lib \
    && cp -a opt/rocm-*/lib/librocm_smi64.so.7* /opt/rocm-compat/lib/ \
    && cp opt/rocm-*/share/doc/*/LICENSE.txt /opt/rocm-compat/LICENSE.rocm-smi-lib.txt

FROM docker.io/library/ubuntu:${UBUNTU_VERSION}
ARG PYTHON_VERSION
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl wget sudo ca-certificates libjemalloc2 \
      libgl1 libglib2.0-0t64 libxcb1 libx11-6 libxext6 libxrender1 \
      libnuma1 libelf1t64 libdrm2 libdrm-amdgpu1 libatomic1 libgomp1 libstdc++6 libzstd1 zlib1g \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY --from=build /opt/python${PYTHON_VERSION} /opt/python${PYTHON_VERSION}
# python3 too: the quadlets' HealthCmd runs "python3 /conf/healthcheck.py".
RUN ln -s "/opt/python${PYTHON_VERSION}/bin/python${PYTHON_VERSION}" "/usr/bin/python${PYTHON_VERSION}" \
    && ln -s "python${PYTHON_VERSION}" /usr/bin/python3
COPY --from=build /tmp/hsa-gentle-wait.so /usr/local/lib/hsa-gentle-wait.so
COPY --from=build /opt/rocm-compat /opt/rocm-compat

# has_rocm runs rocminfo before the venv is activated: use the venv's TheRock rocminfo when it exists
# (functions.sh falls back to the KFD topology on a fresh install).
RUN printf '%s\n' '#!/bin/sh' \
      'v="${ROOT_DIR:-/root}/venv-${DOCKER_INSTANCE:-comfyui}-${PYTHON_VERSION:-3.12}/bin/rocminfo"' \
      '[ -x "$v" ] || { echo "rocminfo: venv not initialized yet" >&2; exit 1; }' \
      'exec "$v" "$@"' > /usr/local/bin/rocminfo \
    && chmod 755 /usr/local/bin/rocminfo

WORKDIR /app
