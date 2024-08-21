# Docker Compose for Stable Diffusion for ROCm
Simple docker compose for getting ComfyUI and sd-webui (Forge) up and running with minimal modification on the main system.

## Requirements
* docker-compose
* AMD GPU (PRs for other cards are welcome)
* ROCm components
  * I'm on Arch linux and used opencl-amd package
* checkpoints are saved into **data/checkpoints** other model files in their respective subfolder, for example
**data/comfyui/models** or **data/sd-webui/models**

## Instructions
1. clone this repo
2. open repo directory in terminal
3. start up the docker container by typing:
   1. `docker-compose up`
   2. It will take a while to download all python libraries
   3. wait a while until you see the text:  `To see the GUI go to: http://0.0.0.0:80`
   4. After getting that message start ComfyUI by open browser with the following link: http://localhost
   5. or WebUI by going to http://localhost:81

The script creates a marker file that will skip downloading of python libraries to speedup the startup.

If you want to start over you can run this oneliner:
* `rm data/home/.*_initialized; rm -fr data/home/venv*;  sudo docker-compose up --force-recreate`

## Notes
Big thanks for all Open Source gang that have made this possible.

## Links
* ComfyUI: https://github.com/comfyanonymous/ComfyUI
* Automatic1111: https://github.com/AUTOMATIC1111/stable-diffusion-webui
* WebUI Forge: https://github.com/lllyasviel/stable-diffusion-webui-forge