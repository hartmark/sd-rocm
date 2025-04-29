#!/bin/sh
###
# Running on arch you need to install:
# rocminfo - unless you're using cpuonly
# pyenv
###

export PYTHON_VERSION="3.12"
#export ROCM_VERSION="release"
export ROCM_VERSION="nightly"
export DOCKER_INSTANCE="local-comfyui"
export ROOT_DIR="${PWD}/data/home-local"

if [ ! -d "${ROOT_DIR}" ]; then
  mkdir "${ROOT_DIR}"
fi

export COMFYUI_PORT=31490

. conf/functions.sh
has_rocm
activate_venv

printf "Reinstall ROCm torch? (y/N): "
read -r reinstall_rocm
reinstall_rocm=${reinstall_rocm:-n}
if [[ $reinstall_rocm =~ ^[Yy]$ ]]; then
  install_rocm_torch
else
  echo "Skipping ROCm torch reinstallation."
fi

printf "Reinstall Flash Attention? (y/N): "
read -r reinstall_flash
reinstall_flash=${reinstall_flash:-n}
if [[ $reinstall_flash =~ ^[Yy]$ ]]; then
  install_flash_attention
else
  echo "Skipping Flash Attention reinstallation."
fi

setup_comfyui
has_cuda
launch_comfyui