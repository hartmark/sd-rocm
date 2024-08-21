#!/bin/bash

# NOTE: This is to be run in docker container, not the host
source /conf/common-setup.sh

MARKER_FILE="/root/.comfyui_initialized"
if [ ! -f "$MARKER_FILE" ]; then
    echo "comfyui not initialized. Initializing now..."
    echo "===================="
    git clone https://github.com/comfyanonymous/ComfyUI /comfyui
    cd /comfyui
    pip3 install -r requirements.txt

    # packages for ReActor that sometimes doesn't get installed
    pip3 install onnxruntime onnxruntime-gpu

    # use shared model folder
    rm -r /comfyui/models/checkpoints
    ln -s ../../checkpoints /comfyui/models/checkpoints

    cd /comfyui/custom_nodes
    git clone https://github.com/ltdrdata/ComfyUI-Manager

    # https://github.com/comfyanonymous/ComfyUI?tab=readme-ov-file#how-to-show-high-quality-previews
    cd /comfyui/models/vae_approx/
    wget -c https://github.com/madebyollin/taesd/raw/main/taesd_decoder.pth
    wget -c https://github.com/madebyollin/taesd/raw/main/taesdxl_decoder.pth

    echo "comfyui environment initialization complete."
    echo "===================="

    touch $MARKER_FILE
fi

cd /comfyui
#git pull

python main.py --listen 0.0.0.0 --port 80 --use-split-cross-attention --front-end-version Comfy-Org/ComfyUI_frontend@latest --lowvram --reserve-vram 3.5

# the command above should normally never exit
# keep the container up so we might get a chance to fix any issues
sleep 1d
