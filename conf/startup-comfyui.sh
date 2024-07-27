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
    conda activate py_3.9
    conda update -n base -c defaults conda -y

    conda install -n base -c conda-forge mamba -y

    # install lates ROCm for performance boost
    pip install -U pip
    pip install einops transformers torchsde kornia spandrel onnxruntime onnxruntime-gpu \
	numba==0.60.0 numpy==1.26.4 ultralytics \
	--root-user-action=ignore
    pip install --pre \
	torch==2.5.0.dev20240724+rocm6.1 \
	torchaudio==2.4.0.dev20240725+rocm6.1 \
	torchvision==0.20.0.dev20240725+rocm6.1 \
	safetensors \
	--index-url https://download.pytorch.org/whl/nightly/rocm6.1 \
	--root-user-action=ignore

    touch "$MARKER_FILE"

    echo "Conda environment initialization complete."

    # get comfyui
    # =======================
    git clone https://github.com/comfyanonymous/ComfyUI /comfyui
    cd /comfyui

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
    conda activate py_3.9
fi

torchinfo

cd /comfyui
HSA_OVERRIDE_GFX_VERSION=11.0.0 python main.py --listen 0.0.0.0 --port 80
