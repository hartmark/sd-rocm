#!/bin/bash
# NOTE: This script is to be run in docker container, not the host

source /conf/functions.sh
has_rocm
activate_venv

MARKER_FILE="/root/.${DOCKER_INSTANCE}_initialized"
if [ ! -f "$MARKER_FILE" ]; then
  echo "comfyui not initialized. Initializing now..."
  echo "===================="
  git clone https://github.com/comfyanonymous/ComfyUI /comfyui
  cd /comfyui
  pip3 install -r requirements.txt

  install_rocm_torch

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
  touch "$MARKER_FILE"
fi

has_cuda

cd /comfyui
git pull

# https://github.com/pytorch/pytorch/issues/138067
export DISABLE_ADDMM_CUDA_LT=1

python main.py --listen 0.0.0.0 --port 80 \
	--front-end-version Comfy-Org/ComfyUI_frontend@latest \
  --use-split-cross-attention

# the command above should normally never exit
# keep the container up so we might get a chance to fix any issues
sleep 1d
