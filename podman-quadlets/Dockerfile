FROM docker.io/rocm/pytorch:latest

# Install system dependencies needed by the startup scripts
# functions.sh requires these for pyenv and other builds; the X/GL libs are for
# opencv (cv2) and the GLSL node, pulled in by custom nodes (reactor, facefusion,
# nodes_glsl) - without them those imports fail with libX11.so.6 / libxcb.so.1.
RUN apt-get update && apt-get install -y --no-install-recommends \
    libssl-dev \
    liblzma-dev \
    wget \
    curl \
    git \
    sudo \
    rocminfo \
    libgl1 \
    libglib2.0-0 \
    libx11-6 \
    libxcb1 \
    libxext6 \
    libxrender1 \
    libgomp1 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# The original setup relies on mounting /conf and data directories.
# We keep this behavior to remain compatible with the existing scripts.
