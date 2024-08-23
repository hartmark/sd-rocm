#!/bin/bash

# NOTE: This is to be run in docker container, not the host

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

echo "Docker instance: $DOCKER_INSTANCE"

MARKER_FILE="/root/.venv_$HOST_initialized"
if [ ! -f "$MARKER_FILE" ]; then
    echo "venv not initialized. Initializing now..."
    echo "===================="   

    cd
    /opt/conda/bin/python3 -m venv "venv-$DOCKER_INSTANCE"
    source "venv-$DOCKER_INSTANCE/bin/activate"

    pip3 install --upgrade pip

    echo "Install ROCm version of torch"
    echo "===================="
    pip3 uninstall torch torchaudio torchvision safetensors -y
    pip3 install --pre \
        torch torchaudio torchvision safetensors \
        --index-url https://download.pytorch.org/whl/nightly/rocm6.2 \
        --root-user-action=ignore

#    echo "install ROCm optimized bitsandbytes"
#    echo "===================="
#    git clone --recurse https://github.com/bitsandbytes-foundation/bitsandbytes.git /bitsandbytes
#    cd /bitsandbytes
#    git checkout multi-backend-refactor
#    git pull

#    # repo above are missing commits made in main branch, this repo have main merged into it.
#    # see: https://github.com/comfyanonymous/ComfyUI_bitsandbytes_NF4/issues/12#issuecomment-2288089151
#    git remote add merge-fix https://github.com/initialxy/bitsandbytes.git
#    git fetch merge-fix
#    git checkout merge-fix/multi-backend-refactor

#    pip3 install -r requirements-dev.txt
#    cmake -DCOMPUTE_BACKEND=hip -DBNB_ROCM_ARCH="$GFX_NAME" -S .
#    make clean
#    make -j$((`nproc`+1))
#    pip install .

    # cleanup pip cache
#    rm -fr /root/.cache

    echo "venv environment initialization complete."
    echo "===================="

    touch $MARKER_FILE
else
    echo "venv environment already initialized. Skipping initialization steps."
    echo "===================="

    # Activate the environment
    cd
    source "venv-$DOCKER_INSTANCE/bin/activate"
fi
