#!/bin/bash

# NOTE: This is to be run in docker container, not the host
source /conf/common-setup.sh

MARKER_FILE="/root/.webui_initialized"
if [ ! -f "$MARKER_FILE" ]; then
    echo "webui environment not initialized. Initializing now..."
    echo "===================="

    # Uncomment to use old Automatic1111
#    git clone https://github.com/AUTOMATIC1111/stable-diffusion-webui /sd-webui
    git clone https://github.com/lllyasviel/stable-diffusion-webui-forge /sd-webui

    cd /sd-webui
    git pull

    # use shared model folder
    rm -r /sd-webui/models/Stable-diffusion
    ln -s ../../checkpoints /sd-webui/models/Stable-diffusion

    touch "$MARKER_FILE"

    echo "webui environment initialization complete."
fi

cd /sd-webui
git pull

python3 launch.py --skip-python-version-check --enable-insecure-extension-access --listen --port 81 --api --precision full --no-half --no-half-vae

# the command above should normally never exit
# keep the container up so we might get a chance to fix any issues
sleep 1d
