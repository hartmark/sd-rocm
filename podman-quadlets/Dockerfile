FROM docker.io/rocm/pytorch:latest

# Install system dependencies needed by the startup scripts
# functions.sh requires these for pyenv and other builds
RUN apt-get update && apt-get install -y \
    libssl-dev \
    liblzma-dev \
    wget \
    curl \
    git \
    sudo \
    rocminfo \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# The original setup relies on mounting /conf and data directories.
# We keep this behavior to remain compatible with the existing scripts.
