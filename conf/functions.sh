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
    torch torchvision torchaudio onnxruntime onnxruntime-gpu onnxruntime-rocm triton pytorch-triton pytorch-triton-rocm \
    rocm rocm-sdk rocm-sdk-core rocm-sdk-devel rocm-sdk-libraries \
    rocm-sdk-libraries-gfx110X-dgpu rocm-sdk-libraries-gfx120X-all \
    _rocm_sdk_core _rocm_sdk_devel _rocm_sdk_libraries_gfx110X_dgpu _rocm_sdk_libraries_gfx120X_all 2>/dev/null || true

  case "${ROCM_VERSION}" in
    nightly)
      # TheRock unified multi-arch nightly index; GPU is selected via a [device-*] extra.
      # The old per-family indexes (rocm.nightlies.amd.com/v2/gfx...) are frozen since ~2026-06.
      # https://github.com/ROCm/TheRock/blob/main/RELEASES.md#installing-multi-arch-pytorch-python-packages
      THE_ROCK_URL="https://nightly.repo.amd.com/rocm/whl-next/"
      # Optional ROCm-nightly pin. The GGUF partial-load path on gfx1200 (RX 9060 XT)
      # can wedge forever in rocr::core::BusyWaitSignal::WaitRelaxed (100% CPU, GPU
      # idle) during "Attempting to release mmap" -> GGMLTensor.to. Reproduced on
      # a20260831 AND a20260902 under severe host-RAM + VRAM pressure, so this is
      # NOT a specific-nightly regression - it's the mmap-release loop under memory
      # pressure. Pinning is a blunt fallback only; the real fixes are memory
      # headroom + dropping --cache-none. Set e.g. TORCH_NIGHTLY_DATE=20260831 to pin.
      # NOTE: the whl-next index only keeps ~10 days, so old dates 404.
      TORCH_NIGHTLY_DATE="${TORCH_NIGHTLY_DATE-}"
      case "${GFX_NAME}" in
        gfx1100 | gfx1101)
          DEVICE_EXTRA="device-gfx110x"
          ;;
        gfx1200)
          DEVICE_EXTRA="device-gfx1200"
          ;;
        gfx1201)
          DEVICE_EXTRA="device-gfx1201"
          ;;
      *)
        echo "GFX version detection error: ${GFX_NAME}" >&2
        exit 1
        ;;
      esac

      if [ -n "${TORCH_NIGHTLY_DATE}" ]; then
        RVER="10.1.0a${TORCH_NIGHTLY_DATE}"
        TORCH_SPECS=(
          "torch[${DEVICE_EXTRA}]==2.15.0a0+rocm${RVER}"
          "torchvision[${DEVICE_EXTRA}]==0.30.0a0+rocm${RVER}"
          "torchaudio==2.11.0.3+rocm${RVER}"
        )
      else
        TORCH_SPECS=("torch[${DEVICE_EXTRA}]" "torchvision[${DEVICE_EXTRA}]" torchaudio)
      fi

      "$PYTHON_VENV" -m pip install --pre --upgrade --break-system-packages \
          "${TORCH_SPECS[@]}" numpy \
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

ensure_rocm_onnx() {
  if [[ "${ROCM_VERSION}" == cpuonly ]]; then
    return
  fi

  # Check if we need to fix or install onnxruntime-rocm
  # We are more aggressive here: if onnxruntime-gpu is present, we must remove it.
  if "$PYTHON_VENV" -m pip show onnxruntime-gpu >/dev/null 2>&1 || \
     ! "$PYTHON_VENV" -m pip show onnxruntime-rocm >/dev/null 2>&1; then
    
    echo "Fixing/Installing ONNX Runtime for ROCm..."
    # Uninstall all to avoid conflicts
    "$PYTHON_VENV" -m pip uninstall -y onnxruntime onnxruntime-gpu onnxruntime-rocm || true
      
      case "${PYTHON_VERSION}" in
        3.10)
          "$PYTHON_VENV" -m pip install --break-system-packages \
            https://repo.radeon.com/rocm/manylinux/rocm-rel-7.0/onnxruntime_rocm-1.22.1-cp310-cp310-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl
          ;;
        3.12)
          "$PYTHON_VENV" -m pip install --break-system-packages \
            https://repo.radeon.com/rocm/manylinux/rocm-rel-7.0/onnxruntime_rocm-1.22.1-cp312-cp312-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl
          ;;
      esac
  fi

  # Patch custom nodes that are known to break ROCm ONNX setup
  local FF_INSTALL="/root/comfyui/custom_nodes/facefusion_comfyui/install.py"
  if [ -f "$FF_INSTALL" ]; then
    echo "Bypassing Facefusion ONNX installer..."
    # Create marker file and patch the script to return early
    touch "/root/comfyui/custom_nodes/facefusion_comfyui/.install_complete"
    sed -i 's/def install() -> None:/def install() -> None:\n\treturn/g' "$FF_INSTALL"
  fi

  local REACTOR_INSTALL="/root/comfyui/custom_nodes/comfyui-reactor-node/install.py"
  if [ -f "$REACTOR_INSTALL" ]; then
    echo "Patching ReActor ONNX installer..."
    # Force it to use onnxruntime-rocm
    sed -i 's/ort = "onnxruntime-gpu"/ort = "onnxruntime-rocm"/g' "$REACTOR_INSTALL"
  fi

  # Discover and add all ROCm SDK library paths to LD_LIBRARY_PATH
  echo "Setting up ROCm library paths..."
  local SITE_PACKAGES
  SITE_PACKAGES=$("$PYTHON_VENV" -c "import site; print(':'.join(site.getsitepackages()))")
  local ROCM_LIB_DIRS
  ROCM_LIB_DIRS=$(echo "$SITE_PACKAGES" | tr ':' '\n' | xargs -I {} find {} -maxdepth 3 -type d -path "*/_rocm_sdk_*/lib" 2>/dev/null | tr '\n' ':')
  export LD_LIBRARY_PATH="${ROCM_LIB_DIRS}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

  # Set ROCM_PATH to the core SDK directory if found
  local CORE_ROCM
  CORE_ROCM=$(echo "$SITE_PACKAGES" | tr ':' '\n' | xargs -I {} find {} -maxdepth 1 -name "_rocm_sdk_core" 2>/dev/null | head -n 1)
  if [ -n "$CORE_ROCM" ]; then
    export ROCM_PATH="$CORE_ROCM"
    export ROCM_HOME="$CORE_ROCM"
    export HIP_PATH="$CORE_ROCM"
  fi

  # Fix missing librocm_smi64.so.7 by symlinking to available version
  echo "$SITE_PACKAGES" | tr ':' '\n' | xargs -I {} find {} -name "librocm_smi64.so.1" 2>/dev/null | while read -r lib; do
    local dir
    dir=$(dirname "$lib")
    if [ ! -f "$dir/librocm_smi64.so.7" ]; then
      echo "Creating symlink for librocm_smi64.so.7 in $dir"
      ln -s "librocm_smi64.so.1" "$dir/librocm_smi64.so.7"
    fi
  done

  # Fix missing librocsolver.so.0 by symlinking to librocsolver.so.1
  echo "$SITE_PACKAGES" | tr ':' '\n' | xargs -I {} find {} -name "librocsolver.so.1" 2>/dev/null | while read -r lib; do
    local dir
    dir=$(dirname "$lib")
    if [ ! -f "$dir/librocsolver.so.0" ]; then
      echo "Creating symlink for librocsolver.so.0 in $dir"
      ln -s "librocsolver.so.1" "$dir/librocsolver.so.0"
    fi
  done

  # Patch all custom nodes to include ROCMExecutionProvider in ONNX sessions
  echo "Patching custom nodes for ROCMExecutionProvider..."
  find "${ROOT_DIR}/comfyui/custom_nodes" -name "*.py" -type f -print0 | xargs -0 grep -lZ "CUDAExecutionProvider" | while read -d $'\0' -r file; do
    echo "Patching $file"
    sed -i "s/CUDAExecutionProvider/ROCMExecutionProvider/g" "$file"
    # Deduplicate and clean up the list
    sed -Ei "s/['\"]ROCMExecutionProvider['\"],[[:space:]]*['\"]ROCMExecutionProvider['\"]/'ROCMExecutionProvider'/g" "$file"
  done
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
  ensure_rocm_onnx

  # https://github.com/pytorch/pytorch/issues/138067
  export DISABLE_ADDMM_CUDA_LT=1

  # ROCm HSA runtime optimization to avoid polling loop CPU usage
  export HSA_ENABLE_INTERRUPT=1

  # Keep rocprofiler/roctracer from interposing every HIP call (torch's kineto
  # auto-registers it). Pure overhead for inference and it sits in the hot
  # hipMemcpyWithStream path.
  export ROCPROFILER_REGISTER_ENABLED=0

  # LD_PRELOAD shim: replace rocr BusyWaitSignal::WaitRelaxed's 100%-CPU spin with
  # a nanosleep poll, so a H2D copy that stalls for tens of seconds under memory
  # pressure (ROCm/TheRock#7832) doesn't peg a core / wedge the box / block SIGKILL.
  # Set GENTLE_WAIT=0 to skip. HSA_GENTLE_WAIT=0 disables it at runtime without rebuild.
  if [[ "${GENTLE_WAIT:-1}" != "0" ]] && command -v gcc >/dev/null 2>&1 \
     && [ -f "${FUNCTIONS_DIR}/hsa-gentle-wait.c" ]; then
    SHIM="${FUNCTIONS_DIR}/hsa-gentle-wait.so"
    if [ ! -f "$SHIM" ] || [ "${FUNCTIONS_DIR}/hsa-gentle-wait.c" -nt "$SHIM" ]; then
      gcc -O2 -fPIC -shared -o "$SHIM" "${FUNCTIONS_DIR}/hsa-gentle-wait.c" -ldl \
        && echo "built $SHIM" || echo "WARNING: hsa-gentle-wait build failed" >&2
    fi
    [ -f "$SHIM" ] && export LD_PRELOAD="${SHIM}${LD_PRELOAD:+:$LD_PRELOAD}"
  fi

  # Optimization for memory fragmentation and allocation
  if [ -f "/usr/lib/x86_64-linux-gnu/libjemalloc.so.2" ]; then
    export LD_PRELOAD="/usr/lib/x86_64-linux-gnu/libjemalloc.so.2${LD_PRELOAD:+:$LD_PRELOAD}"
    # Aggressive decay and background threads for cleanup
    export MALLOC_CONF="background_thread:true,metadata_thp:disabled,dirty_decay_ms:5000,muzzy_decay_ms:5000"
  fi
  # Standard glibc memory tuning
  export MALLOC_TRIM_THRESHOLD_=131072
  export MALLOC_MMAP_THRESHOLD_=131072

  # Base arguments for ComfyUI main
  ARGS=(main.py --listen 0.0.0.0 --port "${COMFYUI_PORT}" \
      --front-end-version Comfy-Org/ComfyUI_frontend@latest)

  # ComfyUI memory management overrides
  if [[ "${DISABLE_SMART_MEMORY}" == "1" || "${DISABLE_SMART_MEMORY}" == "true" ]]; then
    ARGS+=("--disable-smart-memory")
  fi

  if [[ "${DISABLE_PINNED_MEMORY}" == "1" || "${DISABLE_PINNED_MEMORY}" == "true" ]]; then
    ARGS+=("--disable-pinned-memory")
  fi

  if [[ "${HIGH_VRAM}" == "1" || "${HIGH_VRAM}" == "true" ]]; then
    ARGS+=("--highvram")
  fi

  if [[ "${LOW_VRAM}" == "1" || "${LOW_VRAM}" == "true" ]]; then
    ARGS+=("--lowvram")
  fi

  if [[ "${FAST_DISK}" == "1" || "${FAST_DISK}" == "true" ]]; then
    ARGS+=("--fast-disk")
  fi

  if [[ "${CACHE_NONE}" == "1" || "${CACHE_NONE}" == "true" ]]; then
    ARGS+=("--cache-none")
  fi

  if [[ "${MMAP_TORCH}" == "1" || "${MMAP_TORCH}" == "true" ]]; then
    ARGS+=("--mmap-torch-files")
  fi

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
  ensure_rocm_onnx

  if [[ "${ROCM_VERSION}" == cpuonly ]]; then
    export COMMANDLINE_ARGS="--skip-torch-cuda-test --always-cpu"
  fi

  # ROCm HSA runtime optimization to avoid polling loop CPU usage
  export HSA_ENABLE_INTERRUPT=1

  # Optimization for memory fragmentation and allocation
  if [ -f "/usr/lib/x86_64-linux-gnu/libjemalloc.so.2" ]; then
    export LD_PRELOAD="/usr/lib/x86_64-linux-gnu/libjemalloc.so.2${LD_PRELOAD:+:$LD_PRELOAD}"
    # Aggressive decay and background threads for cleanup
    export MALLOC_CONF="background_thread:true,metadata_thp:disabled,dirty_decay_ms:5000,muzzy_decay_ms:5000"
  fi
  # Standard glibc memory tuning
  export MALLOC_TRIM_THRESHOLD_=131072
  export MALLOC_MMAP_THRESHOLD_=131072

  "$PYTHON_VENV" launch.py --listen --port "${WEBUI_PORT}" --api \
    --skip-version-check --skip-python-version-check --enable-insecure-extension-access \
    --precision full --no-half --no-half-vae
}
