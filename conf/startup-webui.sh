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

    # libs needed for ReActor
    mamba install -y numba numpy scikit-image scipy matplotlib \
	onnxruntime fastapi pydantic=1.10.13 albumentations insightface 'urllib3<2' \
	-c conda-forge

    pip install -U pip
    pip install "onnxruntime-gpu>=1.16.1" --root-user-action=ignore

    touch "$MARKER_FILE"

    echo "Conda environment initialization complete."
else
    echo "Conda environment already initialized. Skipping initialization steps."

    # Activate the environment
    conda init
    source /root/.bashrc
    conda activate py_3.9
fi



torchinfo

# get sd-webui
# =======================
git clone https://github.com/AUTOMATIC1111/stable-diffusion-webui /sd-webui
cd /sd-webui

git remote add forge https://github.com/lllyasviel/stable-diffusion-webui-forge
git branch lllyasviel/main
git checkout lllyasviel/main
git fetch forge
git branch -u forge/main
git pull

python3 launch.py \
	--no-half \
	--precision=full \
	--port 80 \
	--listen \
	--enable-insecure-extension-access \
	--data-dir=/stable-diffusion

# command above should normally not exit
# uncomment to trap the container for easier debug
# sleep 100d
