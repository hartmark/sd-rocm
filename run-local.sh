#!/bin/sh
###
# Running on arch you need to install:
# rocminfo 
# pyenv
###

PYTHON_VERSION="3.12"
ROCM_VERSION="release"
export DOCKER_INSTANCE="local-comfyui"
ROOT_DIR="${PWD}/data/home-local"

if [ ! -d "${ROOT_DIR}" ]; then
  mkdir "${ROOT_DIR}"
fi

COMFYUI_PORT=8080

source conf/functions.sh
has_rocm
activate_venv
setup_comfyui
has_cuda
launch_comfyui