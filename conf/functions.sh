#!/bin/bash
set -e # exit on error
#set -x # enable debug mode

echo "Docker instance: ${DOCKER_INSTANCE}"

# Resolve absolute path to this conf directory at source time to avoid
# failures when current working directory changes later.
# shellcheck disable=SC2164
FUNCTIONS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

safe_git_pull() {
  # Check if we are in a git repository
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 0
  fi

  local branch
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
  if [[ "$branch" != "HEAD" && "$branch" != "" ]]; then
    echo "Updating $(basename "$(pwd)") via git pull..."
    git pull || echo "Warning: git pull failed in $(pwd)"
  else
    echo "Warning: Not on a branch (detached HEAD) in $(pwd). Skipping git pull update."
  fi
}

# cleanup pip cache, it can grow quite big if left unchecked
#rm -fr /root/.cache/pip

has_rocm() {
  GFX_NAME=$(rocminfo | grep -m 1 -E "gfx[^0]{1}" | sed -e 's/ *Name: *//' | awk '{$1=$1; print}' || echo "rocminfo missing")
  echo "GFX_NAME = $GFX_NAME"

  case "${GFX_NAME}" in
    gfx1101 | gfx1100)
      export HSA_OVERRIDE_GFX_VERSION="11.0.0"
      ;;
    gfx1200)
      export HSA_OVERRIDE_GFX_VERSION="12.0.0"
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
    "$PYTHON_VENV" <<EOF
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
  VENV_DIR="${ROOT_DIR}/venv-${DOCKER_INSTANCE}-${PYTHON_VERSION}"

  # Check if venv exists and is functional (handles system python upgrades and moved venv)
  if [ -f "${MARKER_FILE}" ]; then
    local broken=0
    if [ ! -x "${VENV_DIR}/bin/python3" ]; then
      broken=1
    elif ! "${VENV_DIR}/bin/python3" -c "import sys; print(sys.version)" >/dev/null 2>&1; then
      broken=1
    elif [ -f "${VENV_DIR}/bin/activate" ] && ! grep -q "VIRTUAL_ENV.*${VENV_DIR}" "${VENV_DIR}/bin/activate"; then
      echo "venv appears to have been moved. Re-initializing..."
      broken=1
    fi

    if [ "$broken" -eq 1 ]; then
      echo "venv is missing, not executable, or broken. Re-initializing..."
      rm -f "${MARKER_FILE}"
      rm -rf "${VENV_DIR}"
    fi
  fi

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

    VENV_DIR="${ROOT_DIR}/venv-${DOCKER_INSTANCE}-${PYTHON_VERSION}"

    if command -v pyenv >/dev/null 2>&1; then
      export PATH="${HOME}/.pyenv/bin:${PATH}"
      pyenv install "${PYTHON_VERSION_FULL}" --skip-existing || true
      pyenv global "${PYTHON_VERSION_FULL}" || true
      export PATH="${HOME}/.pyenv/versions/${PYTHON_VERSION_FULL}/bin:${PATH}"
      PYTHON_BIN="${HOME}/.pyenv/shims/python${PYTHON_VERSION}"
      if [ ! -x "$PYTHON_BIN" ]; then
        PYTHON_BIN="python${PYTHON_VERSION}"
      fi
    else
      echo "pyenv not found; falling back to system Python."
      PYTHON_BIN="python${PYTHON_VERSION}"
      if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
        PYTHON_BIN="python3"
      fi
    fi

    "$PYTHON_BIN" -m venv "$VENV_DIR"
    "$VENV_DIR/bin/python3" -m pip install --upgrade pip

    echo "venv environment initialization complete."
    echo "===================="

    touch "${MARKER_FILE}"
  else
    echo "venv environment already initialized. Skipping initialization steps."
    echo "===================="
  fi

  # shellcheck disable=SC1090
  # shellcheck source=/dev/null
  source "${VENV_DIR}/bin/activate"

  if [ -z "$VIRTUAL_ENV" ]; then
    echo "Error: Virtual environment activation failed." >&2
    exit 1
  fi

  # Ensure we use the venv's python and pip
  export PYTHON_VENV="${VENV_DIR}/bin/python3"

  # Relax aiter's triton version check to allow ROCm-specific pytorch-triton-rocm
  export AITER_USE_SYSTEM_TRITON=1

  # Ensure ROCM_HOME and HIP_PATH are set for tools like aiter
  if [ -z "$ROCM_HOME" ]; then
    if [ -n "$ROCM_PATH" ]; then
      export ROCM_HOME="$ROCM_PATH"
    elif [ -d "/opt/rocm" ]; then
      export ROCM_HOME="/opt/rocm"
    fi
  fi
  if [ -z "$HIP_PATH" ] && [ -n "$ROCM_HOME" ]; then
    export HIP_PATH="$ROCM_HOME"
  fi
}

install_rocm_torch() {
  echo "Install ROCm version of torch"
  echo "===================="
  "$PYTHON_VENV" -m pip uninstall -y \
    torch torchvision torchaudio onnxruntime onnxruntime-gpu onnxruntime-rocm triton pytorch-triton pytorch-triton-rocm

  case "${ROCM_VERSION}" in
    nightly)
      # TODO: add support for all here
      # https://github.com/ROCm/TheRock/blob/main/RELEASES.md#index-page-listing
      case "${GFX_NAME}" in
        gfx1101 | gfx1100)
          THE_ROCK_URL="https://rocm.nightlies.amd.com/v2/gfx110X-dgpu"
          ;;
        gfx1200)
          THE_ROCK_URL="https://rocm.nightlies.amd.com/v2/gfx120X-all"
          ;;
      *)
        echo "GFX version detection error" >&2
        exit 1
        ;;
      esac

      "$PYTHON_VENV" -m pip install --pre --break-system-packages \
          torch torchvision torchaudio numpy \
          --index-url  "$THE_ROCK_URL"\
          --root-user-action=ignore

      # onnxruntime not available in nightly
      case "${PYTHON_VERSION}" in
        3.10)
          "$PYTHON_VENV" -m pip install --break-system-packages \
            https://repo.radeon.com/rocm/manylinux/rocm-rel-7.0/onnxruntime_rocm-1.22.1-cp310-cp310-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl
          ;;
        3.12)
          "$PYTHON_VENV" -m pip install --break-system-packages \
            https://repo.radeon.com/rocm/manylinux/rocm-rel-7.0/onnxruntime_rocm-1.22.1-cp312-cp312-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl
          ;;
        *)
          echo "Unsupported python version ${PYTHON_VERSION}" >&2
          exit 1
      esac
  ;;
    release)
      "$PYTHON_VENV" -m pip install --break-system-packages \
          torch torchvision torchaudio onnxruntime_rocm \
          --index-url https://repo.radeon.com/rocm/manylinux/rocm-rel-7.0\
          --root-user-action=ignore
              ;;
    cpuonly)
      "$PYTHON_VENV" -m pip install --break-system-packages \
          torch torchvision torchaudio \
          --extra-index-url https://download.pytorch.org/whl/cpu \
          --root-user-action=ignore
      ;;
    *)
      echo "unsupported ROCm version ${ROCM_VERSION}" >&2
      exit 1
      ;;
  esac
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
    safe_git_pull

    "$PYTHON_VENV" -m pip install --break-system-packages -r requirements.txt

    install_rocm_torch

    # ReActor needs onnxruntime, but we use onnxruntime-rocm for ROCm
    if [[ "${ROCM_VERSION}" == cpuonly ]]; then
      "$PYTHON_VENV" -m pip install --break-system-packages onnxruntime --root-user-action=ignore
    fi

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
    safe_git_pull

    "$PYTHON_VENV" -m pip install --break-system-packages -r requirements_versions.txt
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
  # Use pre-resolved absolute path to conf directory (FUNCTIONS_DIR)
  local SCRIPT_DIR
  SCRIPT_DIR="${FUNCTIONS_DIR}"

  cd "${ROOT_DIR}/comfyui"
  safe_git_pull
  "$PYTHON_VENV" -m pip install --break-system-packages -r requirements.txt --root-user-action=ignore

  # https://github.com/pytorch/pytorch/issues/138067
  export DISABLE_ADDMM_CUDA_LT=1

  # Base arguments for ComfyUI main
  ARGS=(main.py --listen 0.0.0.0 --port "${COMFYUI_PORT}" \
      --front-end-version Comfy-Org/ComfyUI_frontend@latest)

  # May help with certain model loading issues
  ARGS+=("--disable-smart-memory")

  export GPU_MAX_HEAP_SIZE=100
  export GPU_SINGLE_ALLOC_PERCENT=100
  export HSA_ENABLE_INTERRUPT=0
  export HSA_ENABLE_SDMA=0  # Can improve performance on some AMD GPUs

  if [[ "${ROCM_VERSION}" == cpuonly ]]; then
    ARGS+=("--cpu")
  fi

  # Run the VAE on the CPU.
#  ARGS+=("--cpu-vae")

  # Optional profiling support
  if [[ "${PROFILING}" == "1" || "${PROFILING}" == "true" || "${PROFILING}" == "TRUE" ]]; then
    # Prepare profile directory under ROOT_DIR/profiles/<timestamp>
    local TS
    TS="$(date +%Y%m%d-%H%M%S)"
    export PROFILE_DIR="${ROOT_DIR}/profiles/${TS}"
    mkdir -p "${PROFILE_DIR}"
    # Default sampling interval (seconds) if not provided
    export PROFILING_SAMPLING_INTERVAL="${PROFILING_SAMPLING_INTERVAL:-2}"
    # Enable torch profiler by default; allow override
    export PROFILING_TORCH_PROFILER="${PROFILING_TORCH_PROFILER:-1}"

    echo "Profiling enabled. Logs will be written to: ${PROFILE_DIR}"
    echo "Sampling interval: ${PROFILING_SAMPLING_INTERVAL}s"

    "$PYTHON_VENV" "${SCRIPT_DIR}/profiler_runner.py" "${ARGS[@]}"
  else
    "$PYTHON_VENV" "${ARGS[@]}"
  fi
}

launch_webui() {
  cd "${ROOT_DIR}/sd-webui"
  safe_git_pull
  "$PYTHON_VENV" -m pip install --break-system-packages -r requirements_versions.txt --root-user-action=ignore

  if [[ "${ROCM_VERSION}" == cpuonly ]]; then
    export COMMANDLINE_ARGS="--skip-torch-cuda-test --always-cpu"
  fi

  "$PYTHON_VENV" launch.py --listen --port "${WEBUI_PORT}" --api \
    --skip-version-check --skip-python-version-check --enable-insecure-extension-access \
    --precision full --no-half --no-half-vae
}
