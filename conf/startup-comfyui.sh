#!/bin/bash

# NOTE: This is to be run in docker container, not the host

function torchinfo() {
  echo "===================="   
  python -c 'import torch; print("PyTorch version:", torch.__version__); print("Is CUDA available:", torch.cuda.is_available()); print("CUDA device count:", torch.cuda.device_count()); print("CUDA device name:", torch.cuda.get_device_name(0) if torch.cuda.is_available() else "No CUDA device found")'
  echo "===================="   
}

MARKER_FILE="/root/.conda_initialized"
if [ ! -f "$MARKER_FILE" ]; then
    echo "Conda environment not initialized. Initializing now..."

    conda init
    source /root/.bashrc

    conda create -n python3.12.2 python=3.12.2

    conda activate python3.12.2
    conda update -n base -c defaults conda -y

    conda install -n base -c conda-forge mamba -y

    # install lates ROCm for performance boost
    pip install -U pip --root-user-action=ignore
    pip install einops transformers torchsde kornia spandrel onnxruntime onnxruntime-gpu \
	numba==0.60.0 numpy==1.26.4 ultralytics simpleeval aiohttp \
	--root-user-action=ignore

#    pip install --pre \
#	torch==2.5.0.dev20240804+rocm6.1 \
#	torchaudio==2.4.0.dev20240804+rocm6.1 \
#	torchvision==0.20.0.dev20240804+rocm6.1 \
#	safetensors \
#	--index-url https://download.pytorch.org/whl/nightly/rocm6.1 \
#	--root-user-action=ignore

    pip install --pre \
	torch torchaudio torchvision safetensors \
	--index-url https://download.pytorch.org/whl/nightly/rocm6.1 \
	--root-user-action=ignore

    touch "$MARKER_FILE"

    echo "Conda environment initialization complete."

    # get comfyui
    # =======================
    git clone https://github.com/comfyanonymous/ComfyUI /comfyui
    cd /comfyui
    git pull

    # use same models as webUI
    rm -r /comfyui/models/checkpoints
    ln -s /stable-diffusion/models/Stable-diffusion /comfyui/models/checkpoints

    cd /comfyui/custom_nodes
    git clone https://github.com/ltdrdata/ComfyUI-Manager

    cd /comfyui/models/vae_approx/
    wget https://github.com/madebyollin/taesd/raw/main/taesd_decoder.pth

else
    echo "Conda environment already initialized. Skipping initialization steps."

    # Activate the environment
    conda init
    source /root/.bashrc
    conda activate python3.12.2
fi

torchinfo

cd /comfyui
git pull

# fix for random lockups and crashes due to VRAM usage
# https://www.reddit.com/r/comfyui/comments/192hqig/comment/kh3nkj2/?utm_source=share&utm_medium=web3x&utm_name=web3xcss&utm_term=1&utm_content=share_button
#PYTORCH_HIP_ALLOC_CONF=expandable_segments:True,garbage_collection_threshold:0.6,max_split_size_mb:1024 
PYTORCH_HIP_ALLOC_CONF=expandable_segments:True HSA_OVERRIDE_GFX_VERSION=11.0.0 python main.py --listen 0.0.0.0 --port 80 --use-split-cross-attention --front-end-version Comfy-Org/ComfyUI_frontend@latest --lowvram

# the command above should normally never exit
# keep the container up so we might get a chance to fix any issues
sleep 1d
