#!/bin/bash
set -e # exit on error
#set -x # enable debug mode

echo "Docker instance: ${DOCKER_INSTANCE}"

# cleanup pip cache, it can grow quite big if left unchecked
#rm -fr /root/.cache/pip

has_rocm() {
  GFX_NAME=$(rocminfo | grep -m 1 -E "gfx[^0]{1}" | sed -e 's/ *Name: *//' | awk '{$1=$1; print}' || echo "rocminfo missing")
  echo "GFX_NAME = $GFX_NAME"
    
  case "${GFX_NAME}" in
    gfx1101 | gfx1100)
      export HSA_OVERRIDE_GFX_VERSION="11.0.0"
      ;;
    gfx1030)
      export HSA_OVERRIDE_GFX_VERSION="10.3.0"
      ;;
    *)
      if [[ "${ROCM_VERSION}" != cpuonly ]]; then
        echo "GFX version detection error" >&2
        exit 1
      fi
      ;;
  esac
}

has_cuda() {

  if [[ "${ROCM_VERSION}" != cpuonly ]]; then
    python <<EOF
import torch
import sys

try:
    print("PyTorch version:", torch.__version__)
    cuda_available = torch.cuda.is_available()
    print("Is CUDA available:", cuda_available)
    if cuda_available:
        print("CUDA device count:", torch.cuda.device_count())
        print("CUDA device name:", torch.cuda.get_device_name(0))
    else:
        print("No CUDA device found")
        sys.exit(1)
except Exception as e:
    print("Error:", e)
    sys.exit(1)  # Exit with 1 for other errors
EOF

    # shellcheck disable=SC2181
    if [ $? -ne 0 ]; then
      echo "CUDA not available!" >&2
      exit 1
    fi
  fi
}

activate_venv() {
  MARKER_FILE="${ROOT_DIR}/.venv_${DOCKER_INSTANCE}_${PYTHON_VERSION}_initialized"

  if [ ! -f "${MARKER_FILE}" ]; then
    echo "venv not initialized. Initializing now..."
    echo "===================="   

    # only install pyenv on docker container
    if [[ "${DOCKER_INSTANCE}" != local-* ]]; then
      if [[ ! -d "${ROOT_DIR}/.pyenv" ]]; then
        curl https://pyenv.run | bash
        eval "$(pyenv init --path)"
        eval "$(pyenv init -)"
      fi

      apt update
      apt dist-upgrade -y
      apt install libssl-dev liblzma-dev -y
      apt autoremove -y
    fi

    case "${PYTHON_VERSION}" in
      3.10)
        # https://peps.python.org/pep-0619/
        PYTHON_VERSION_FULL="${PYTHON_VERSION}.16"
        ;;
      3.12)
        # https://peps.python.org/pep-0693/
        PYTHON_VERSION_FULL="${PYTHON_VERSION}.8"
        ;;
      *)
        echo "Unsupported python version ${PYTHON_VERSION}" >&2
        exit 1
    esac

    export PATH="${HOME}/.pyenv/bin:${PATH}"

    pyenv install "${PYTHON_VERSION_FULL}" --skip-existing
    pyenv global "${PYTHON_VERSION_FULL}"

    export PATH="${HOME}/.pyenv/versions/${PYTHON_VERSION_FULL}/bin:${PATH}"
      
    "${HOME}/.pyenv/shims/python${PYTHON_VERSION}" -m venv "${ROOT_DIR}/venv-${DOCKER_INSTANCE}-${PYTHON_VERSION}"

  
    echo "venv environment initialization complete."
    echo "===================="
  
    touch "${MARKER_FILE}"
  else
    echo "venv environment already initialized. Skipping initialization steps."
    echo "===================="
  fi

  # shellcheck disable=SC1090
  source "${ROOT_DIR}/venv-${DOCKER_INSTANCE}-${PYTHON_VERSION}/bin/activate"
  
  pip3 install --upgrade pip --root-user-action=ignore
}

install_rocm_torch() {
  echo "Install ROCm version of torch"
  echo "===================="
  pip3 uninstall torch torchaudio torchvision safetensors pytorch_triton triton -y
  pip3 install triton --root-user-action=ignore

  case "${ROCM_VERSION}" in
    nightly)
      pip3 install --pre \
          torch torchvision safetensors triton pytorch_triton \
          --index-url https://download.pytorch.org/whl/nightly/rocm6.4 \
          --root-user-action=ignore
      ;;
    release)
      pip3 install torch==2.4.0 torchaudio torchvision==0.19.0 pytorch_triton -f https://repo.radeon.com/rocm/manylinux/rocm-rel-6.3.1
      pip3 install --pre \
          safetensors \
          --index-url https://download.pytorch.org/whl/nightly/rocm6.3 \
          --root-user-action=ignore
      ;;
    cpuonly)
      pip3 install torch torchvision torchaudio --extra-index-url https://download.pytorch.org/whl/cpu --root-user-action=ignore
      pip3 install --pre \
          safetensors \
          --index-url https://download.pytorch.org/whl/nightly/rocm6.3 \
          --root-user-action=ignore
      ;;
    *)
      echo "unsupported ROCm version ${ROCM_VERSION}" >&2
      exit 1
      ;;
  esac
  
  pip3 install numpy==1.26.4
}

install_flash_attention() {
  echo "Setting up Flash Attention with ROCm support..."

  pip uninstall -y flash-attn

  if [ -d "${ROOT_DIR}/flash-attention" ]; then
    echo "Removing previous flash-attention directory..."
    rm -rf "${ROOT_DIR}/flash-attention"
  fi
  
  echo "Cloning flash-attention repository..."
  git clone git@github.com:Dao-AILab/flash-attention.git "${ROOT_DIR}/flash-attention" 

  cd "${ROOT_DIR}/flash-attention"
  
  # Set environment variables for ROCm build
  export FLASH_ATTENTION_SKIP_CUDA_BUILD=1
  export FLASH_ATTENTION_FORCE_BUILD=1
  export FLASH_ATTENTION_DISABLE_FUSED_DENSE=1  # Skip the fused dense implementation
  export FLASH_ATTENTION_DISABLE_FUSED_SOFTMAX=1  # Skip fused softmax
  export FLASH_ATTENTION_DISABLE_TRITON=0  # Enable triton
  export FLASH_ATTENTION_TRITON_AMD_ENABLE="TRUE"
  
  # Install the package with pip instead of setup.py directly
  echo "Installing flash-attention..."
  pip install -e . --root-user-action=ignore
  
  echo "Flash Attention installation completed."
}

setup_comfyui() {
  MARKER_FILE="${ROOT_DIR}/.${DOCKER_INSTANCE}_${PYTHON_VERSION}_initialized"

  if [ ! -f "$MARKER_FILE" ]; then
    echo "comfyui not initialized. Initializing now..."
    echo "===================="

    if [ ! -d "${ROOT_DIR}/comfyui" ]; then
      git clone https://github.com/comfyanonymous/ComfyUI "${ROOT_DIR}/comfyui"
    fi

    cd "${ROOT_DIR}/comfyui"
    git pull

    pip3 install -r requirements.txt

    install_rocm_torch
    install_flash_attention
    
    # use shared model folder
    if [ -d "${ROOT_DIR}/comfyui/models/checkpoints" ]; then
      rm -r "${ROOT_DIR}/comfyui/models/checkpoints"
    fi
    ln -sf ../../../checkpoints "${ROOT_DIR}/comfyui/models/checkpoints"

    if [ ! -d "${ROOT_DIR}/comfyui/custom_nodes/ComfyUI-Manager" ]; then
      git clone https://github.com/ltdrdata/ComfyUI-Manager "${ROOT_DIR}/comfyui/custom_nodes/ComfyUI-Manager"
    fi

    # https://github.com/comfyanonymous/ComfyUI?tab=readme-ov-file#how-to-show-high-quality-previews
    cd "${ROOT_DIR}/comfyui/models/vae_approx"
    wget -c https://github.com/madebyollin/taesd/raw/main/taesd_decoder.pth
    wget -c https://github.com/madebyollin/taesd/raw/main/taesdxl_decoder.pth

    echo "comfyui environment initialization complete."
    echo "===================="
    touch "$MARKER_FILE"
  fi
}

setup_webui() {
  MARKER_FILE="${ROOT_DIR}/.${DOCKER_INSTANCE}_${PYTHON_VERSION}_initialized"

  if [ ! -f "$MARKER_FILE" ]; then
    echo "webui environment not initialized. Initializing now..."
    echo "===================="

    if [ ! -d "${ROOT_DIR}/sd-webui" ]; then
    # Uncomment to use old Automatic1111
#    git clone https://github.com/AUTOMATIC1111/stable-diffusion-webui "${ROOT_DIR}/sd-webui"
    git clone https://github.com/lllyasviel/stable-diffusion-webui-forge "${ROOT_DIR}/sd-webui"
    fi

    cd "${ROOT_DIR}/sd-webui"
    git pull

    pip install -r requirements_versions.txt
    install_rocm_torch

    # use shared model folder
        if [ -d "${ROOT_DIR}/sd-webui/models/Stable-diffusion" ]; then
      rm -r "${ROOT_DIR}/sd-webui/models/Stable-diffusion"
    fi
    ln -sf ../../../checkpoints "${ROOT_DIR}/sd-webui/models/Stable-diffusion"

    # libtif.so.5 is needed to run but libtif.so.6 is installed
    sudo ln -fs /usr/lib/x86_64-linux-gnu/libtiff.so /usr/lib/x86_64-linux-gnu/libtiff.so.5

    echo "webui environment initialization complete."
    echo "===================="
    touch "$MARKER_FILE"
  fi
}

launch_comfyui() {
  cd "${ROOT_DIR}/comfyui"
  git pull

  # https://github.com/pytorch/pytorch/issues/138067
  export DISABLE_ADDMM_CUDA_LT=1

  COMMAND=(python main.py --listen 0.0.0.0 --port "${COMFYUI_PORT}" \
      --front-end-version Comfy-Org/ComfyUI_frontend@latest)

  export FLASH_ATTENTION_TRITON_AMD_ENABLE="TRUE" 
  COMMAND+=("--use-flash-attention")

  # reserve vram
  # COMMAND+=("--reserve-vram 3")

  if [[ "${ROCM_VERSION}" == cpuonly ]]; then   
    COMMAND+=("--cpu")
  fi
  
  # Run the VAE on the CPU.
#  COMMAND+=("--cpu-vae")
  
  "${COMMAND[@]}"
}

launch_webui() {
  cd "${ROOT_DIR}/sd-webui"
  git pull

  if [[ "${ROCM_VERSION}" == cpuonly ]]; then
    export COMMANDLINE_ARGS="--skip-torch-cuda-test --always-cpu"
  fi

  python launch.py --listen --port "${WEBUI_PORT}" --api \
    --skip-version-check --skip-python-version-check --enable-insecure-extension-access \
    --precision full --no-half --no-half-vae
}
