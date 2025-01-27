#!/bin/sh
###
# Running on arch you need to install:
# rocminfo - unless you're using cpuonly
# pyenv
###

export PYTHON_VERSION="3.12"
export ROCM_VERSION="release"
export DOCKER_INSTANCE="local-comfyui"
export ROOT_DIR="${PWD}/data/home-local"

if [ ! -d "${ROOT_DIR}" ]; then
  mkdir "${ROOT_DIR}"
fi

export COMFYUI_PORT=31490

. conf/functions.sh
has_rocm
activate_venv
setup_comfyui
has_cuda
launch_comfyui