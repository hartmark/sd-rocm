#!/bin/bash
# NOTE: This script is to be run in docker container, not the host

source /conf/functions.sh
has_rocm
activate_venv
setup_webui
has_cuda
launch_webui

