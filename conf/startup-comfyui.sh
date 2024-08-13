#!/bin/bash

# NOTE: This is to be run in docker container, not the host

function torchinfo() {
  python -c 'import torch; print("PyTorch version:", torch.__version__); print("Is CUDA available:", torch.cuda.is_available()); print("CUDA device count:", torch.cuda.device_count()); print("CUDA device name:", torch.cuda.get_device_name(0) if torch.cuda.is_available() else "No CUDA device found")'
  echo "===================="   
}

GFX_NAME=$(rocminfo | grep -m 1 -E gfx[^0]{1} | sed -e 's/ *Name: *//' | awk '{$1=$1; print}')

case "$GFX_NAME" in
    gfx1101 | gfx1100)
        export HSA_OVERRIDE_GFX_VERSION="11.0.0"
        ;;
    gfx1030)
        export HSA_OVERRIDE_GFX_VERSION="10.3.0"
        ;;
    *)
        echo "GFX version detection error" >&2
        exit 1
        ;;
esac

MARKER_FILE="/root/.venv_initialized"
if [ ! -f "$MARKER_FILE" ]; then
    echo "venv not initialized. Initializing now..."
    echo "===================="   

    cd
    python3 -m venv venv
    source venv/bin/activate

    # get comfyui
    # =======================
    git clone https://github.com/comfyanonymous/ComfyUI /comfyui
    cd /comfyui

    # upgrade to latest pip so we get less spam about update
    pip3 install --upgrade pip

    pip3 install -r requirements.txt

    # dependancies for ReActor that sometimes doesn't get installed
    pip3 install onnxruntime onnxruntime-gpu

    # install ROCm optimized bitsandbytes
    # TODO: Will test more and eventually switch to https://github.com/bitsandbytes-foundation/bitsandbytes/tree/multi-backend-refactor
#    git clone --recurse https://github.com/ROCm/bitsandbytes /bitsandbytes
#    cd /bitsandbytes
#    # fetch latest
#    git pull
#    pip3 install -r requirements-dev.txt
#    cmake -DCOMPUTE_BACKEND=hip -DBNB_ROCM_ARCH="$GFX_NAME" -S .
#    make -j$((`nproc`+1))
#    pip install .

    # use ROCm torch version
    pip3 uninstall torch torchaudio torchvision safetensors -y
    pip3 install --pre \
        torch torchaudio torchvision safetensors \
        --index-url https://download.pytorch.org/whl/nightly/rocm6.1 \
        --root-user-action=ignore

    # use shared model folder
    rm -r /comfyui/models/checkpoints
    ln -s ../../checkpoints /comfyui/models/checkpoints

    cd /comfyui/custom_nodes
    git clone https://github.com/ltdrdata/ComfyUI-Manager

    # https://github.com/comfyanonymous/ComfyUI?tab=readme-ov-file#how-to-show-high-quality-previews
    cd /comfyui/models/vae_approx/
    wget -c https://github.com/madebyollin/taesd/raw/main/taesd_decoder.pth
    wget -c https://github.com/madebyollin/taesd/raw/main/taesdxl_decoder.pth

    # cleanup pip cache
    rm -fr /root/.cache

    echo "venv environment initialization complete."
    echo "===================="

    touch $MARKER_FILE
else
    echo "venv environment already initialized. Skipping initialization steps."
    echo "===================="

    # Activate the environment
    cd
    source /root/venv/bin/activate
fi

torchinfo

# always pull to get latest version of ComfyUI
cd /comfyui
git pull

rocminfo | grep -m 1 -E gfx[^0]{1} | sed -e 's/ *Name: *//'

python main.py --listen 0.0.0.0 --port 80 --use-split-cross-attention --front-end-version Comfy-Org/ComfyUI_frontend@latest

# the command above should normally never exit
# keep the container up so we might get a chance to fix any issues
sleep 1d
