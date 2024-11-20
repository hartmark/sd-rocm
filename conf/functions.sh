#!/bin/bash
echo "Docker instance: ${DOCKER_INSTANCE}"
PYTHON_VERSION="3.10"
ROCM_VERSION="release"
MARKER_FILE="/root/.venv_${DOCKER_INSTANCE}_${PYTHON_VERSION}_initialized"

# cleanup pip cache, it can grow quite big if left unchecked
#rm -fr /root/.cache/pip

has_rocm() {
  GFX_NAME=$(rocminfo | grep -m 1 -E "gfx[^0]{1}" | sed -e 's/ *Name: *//' | awk '{$1=$1; print}')
  echo "GFX_NAME = $GFX_NAME"
    
  case "${GFX_NAME}" in
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
}

has_cuda() {
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
}

activate_venv() {
  if [ ! -f "${MARKER_FILE}" ]; then
    echo "venv not initialized. Initializing now..."
    echo "===================="   
  
    case "$PYTHON_VERSION" in
      3.10)
        rm -r /root/.pyenv
        curl https://pyenv.run | bash
      
        export PATH="${HOME}/.pyenv/bin:${PATH}"
        eval "$(pyenv init --path)"
        eval "$(pyenv init -)"
        
        apt install libssl-dev -y
        apt autoremove
        
        pyenv install 3.10.15
        pyenv global 3.10.15

        export PATH="/root/.pyenv/versions/3.10.15/bin:${PATH}"
      
        /root/.pyenv/shims/python3.10 -m venv "/root/venv-${DOCKER_INSTANCE}-${PYTHON_VERSION}"
        ;;
      3.12)
        /opt/conda/bin/python3 -m venv "/root/venv-${DOCKER_INSTANCE}-${PYTHON_VERSION}"
        ;;
      *)
        echo "Unsupported python version ${PYTHON_VERSION}" >&2
        exit 1
    esac
  
    echo "venv environment initialization complete."
    echo "===================="
  
    touch "${MARKER_FILE}"
  else
    echo "venv environment already initialized. Skipping initialization steps."
    echo "===================="
  fi

  # shellcheck disable=SC1090
  source "/root/venv-${DOCKER_INSTANCE}-${PYTHON_VERSION}/bin/activate"
  
  pip3 install --upgrade pip --root-user-action=ignore
}

install_rocm_torch() {
  echo "Install ROCm version of torch"
  echo "===================="
  pip3 uninstall torch torchaudio torchvision safetensors pytorch_triton -y

  case "${ROCM_VERSION}" in
    nightly)
      pip3 install --pre \
          torch torchaudio torchvision safetensors \
          --index-url https://download.pytorch.org/whl/nightly/rocm6.2 \
          --root-user-action=ignore
      ;;
    release)
      pip3 install torch==2.3.0 torchvision==0.18.0 pytorch_triton -f https://repo.radeon.com/rocm/manylinux/rocm-rel-6.2
      pip3 install --pre \
          safetensors \
          --index-url https://download.pytorch.org/whl/nightly/rocm6.2 \
          --root-user-action=ignore
      ;;
    *)
      echo "unsupported ROCm version ${ROCM_VERSION}" >&2
      exit 1
      ;;
  esac
  
  pip3 install numpy==1.26.4
  
  # TODO: investigate if this still works  
  # install_optimized_bitsandbytes()
}


install_optimized_bitsandbytes() {
  echo "install ROCm optimized bitsandbytes"
  echo "===================="
  git clone --recurse https://github.com/bitsandbytes-foundation/bitsandbytes.git /bitsandbytes
  cd /bitsandbytes
  git checkout multi-backend-refactor
  git pull
  
  # repo above are missing commits made in main branch, this repo have main merged into it.
  # see: https://github.com/comfyanonymous/ComfyUI_bitsandbytes_NF4/issues/12#issuecomment-2288089151
  git remote add merge-fix https://github.com/initialxy/bitsandbytes.git
  git fetch merge-fix
  git checkout merge-fix/multi-backend-refactor
  
  pip3 install -r requirements-dev.txt
  cmake -DCOMPUTE_BACKEND=hip -DBNB_ROCM_ARCH="$GFX_NAME" -S .
  make clean
  make -j$((`nproc`+1))
  pip install .
}