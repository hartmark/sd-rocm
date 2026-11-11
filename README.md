# Docker Compose for Stable Diffusion for ROCm

Simple docker compose for getting ComfyUI and sd-webui (Forge) up and running with minimal modification on the main system.

## Requirements

* docker-compose
* AMD GPU (PRs for other cards are welcome)
* checkpoints are saved into **data/checkpoints** other model files in their respective subfolder, for example
  **data/comfyui/models** or **data/sd-webui/models**

## Instructions

1. clone this repo
2. open repo directory in terminal
3. start up the docker container by typing:
   1. `docker-compose up`
   2. It will take a while to download all python libraries
   3. wait a while until you see the text:  `To see the GUI go to: http://0.0.0.0:31488`
   4. After getting that message start ComfyUI by open browser with the following link: http://localhost:31488
   5. or WebUI by going to http://localhost:31489

### Container image

`docker-compose up` (or the `podman-quadlets/sd-rocm.build` quadlet) builds `localhost/sd-rocm:slim` from
`podman-quadlets/Dockerfile`, with the repo root as build context:

```
podman build -f podman-quadlets/Dockerfile -t localhost/sd-rocm:slim .
```

It is about 0.5 GB instead of the ~54 GB `rocm/pytorch` image used earlier. ROCm, PyTorch and MIOpen come from
TheRock's pip wheels in the venv under `data/home-*`, so the image only carries Ubuntu 26.04 LTS, a standalone
CPython (`PYTHON_VERSION`, default 3.12, via [python-build-standalone](https://github.com/astral-sh/python-build-standalone),
because 26.04 ships only Python 3.14), the system libraries the venv loads, the prebuilt `hsa-gentle-wait` shim and
`librocm_smi64.so.7` from AMD's `rocm-smi-lib` package (onnxruntime's ROCm provider needs it, e.g. for face swap).

There is no compiler in the image, so a custom node whose pip dependency only ships source cannot be built inside
the container. An existing venv created with another image keeps working when its Python minor version matches.

ComfyUI writes generated images to `data/output` (`/root/comfyui/output` in the container).

Personal settings go in `conf/.env` (all instances) or `conf/.env.<DOCKER_INSTANCE>`, e.g. `conf/.env.comfyui`.
`functions.sh` reads them after the quadlet/compose environment, so they override its defaults without editing
tracked files. Both are gitignored; `conf/.env.example` lists the supported settings.

### Run locally (no Docker)

You can also run without containers using the helper script:

```
./run-local.sh
```

- On first run it will create a Python virtual environment and set up ComfyUI, ROCm PyTorch and Flash Attention.
- It creates a marker file in the data directory to skip repeated heavy setup on subsequent runs.
- By default it prompts whether to reinstall ROCm Torch and Flash Attention. To automate, use environment variables:
  - `NON_INTERACTIVE=1` to disable prompts
  - `REINSTALL_ROCM=yes` to reinstall ROCm Torch in non-interactive mode
  - `REINSTALL_FLASH=yes` to reinstall Flash Attention in non-interactive mode

You can customize behavior via a `.env` file at the repo root (auto-loaded) or by exporting variables before running:

- `PYTHON_VERSION` (default `3.12`)
- `ROCM_VERSION` (`nightly`, `release`, or `cpuonly`; default `nightly` for local run)
- `ROOT_DIR` (default `${PWD}/data/home-local`)
- `COMFYUI_PORT` (default `31490`)

run-local.sh also reads `conf/.env` and `conf/.env.local-comfyui`, like the containers. It does not set the
memory settings of the ComfyUI quadlet, so on a box that is short of RAM copy them there, e.g.
`DISABLE_PINNED_MEMORY=1`, `MMAP_TORCH=1`, `HIGH_VRAM=1`, `GPU_PINNED_MIN_XFER_SIZE=100000` (see `conf/.env.example`).

Example non-interactive run on CPU-only:

```
ROCM_VERSION=cpuonly NON_INTERACTIVE=1 ./run-local.sh
```

Important: The provided .env in this repo is tailored for Docker and sets ROOT_DIR=/root. When running locally as a non-root user, run-local.sh will ignore ROOT_DIR=/root and use ${PWD}/data/home-local instead. To explicitly control this, set ROOT_DIR to a writable directory when invoking the script or in your own .env.local file.

Examples:
```
ROOT_DIR="$PWD/data/home-local" ./run-local.sh
# or
export ROOT_DIR="$PWD/data/home-local"; ./run-local.sh
```

## Hints

To make the docker created files accessable from your own user run these commands

```
sudo setfacl -d -m "u:${USER}:rwX" data/
sudo setfacl -R -m "u:${USER}:rwX" data/
```

You can run in CPU-only mode by setting `ROCM_VERSION=cpuonly` and remove the lines with `/dev/kfd` in **docker-compose.yml**


## Profiling (time and GPU memory)

You can enable an optional profiling mode for ComfyUI when running locally. It will:
- Continuously sample and log GPU memory usage (allocated, reserved, peak) and process RSS to a CSV file.
- Optionally run a PyTorch profiler (CPU + ROCm/CUDA) and export a Chrome trace JSON.

How to use:

1) Enable profiling for a run by setting `PROFILING=1`:

```
PROFILING=1 ./run-local.sh
```

2) Outputs will be stored under a timestamped folder:

```
${ROOT_DIR}/profiles/<YYYYMMDD-HHMMSS>/
  - memory_log.csv        # periodic memory samples
  - torch_trace.json      # Chrome trace from torch profiler
```

Environment variables (optional):
- `PROFILING_SAMPLING_INTERVAL` (default `2`): seconds between memory samples.
- `PROFILING_TORCH_PROFILER` (default `1`): set to `0` to disable the torch profiler and only collect memory samples.
- `PROFILING_EXPORT_GZIP` (default `1`): when enabled, also writes a compressed `*.json.gz` version of every exported trace (recommended for Perfetto UI).
- `PROFILING_RECORD_SHAPES` (default `0`): enable to record input shapes; increases trace size.
- `PROFILING_WITH_STACK` (default `0`): enable to capture Python stack traces; increases trace size.

How to get torch_trace.json (step-by-step):
- Start ComfyUI with profiling enabled:
  - `PROFILING=1 ./run-local.sh`
  - Optional: leave the default `PROFILING_TORCH_PROFILER=1` so the trace is recorded.
- Use ComfyUI as usual to reproduce the behavior you want to profile.
- Stop ComfyUI (Ctrl+C in the terminal). On shutdown, the profiler writes the trace to:
  - `${ROOT_DIR}/profiles/<YYYYMMDD-HHMMSS>/torch_trace.json`
- Open the trace in one of the following tools:
  - Chrome: open `chrome://tracing` and load the file
  - Perfetto UI: https://ui.perfetto.dev (you can load `.json` or the compressed `.json.gz` directly)
  - Note: Firefox Profiler expects a different profile format and typically cannot import Chrome Trace JSON. Use Perfetto or Chrome for these traces.

Viewing and correlating data:
- `torch_trace.json` (and `torch_trace.json.gz`) show detailed operator timelines (CPU and, if available, ROCm GPU activity through the CUDA flag).
- `memory_log.csv` provides a coarse timeline of process RSS and GPU memory usage to correlate with actions in ComfyUI.

Notes:
- Profiling is opt-in and does not change the default behavior if `PROFILING` is not set.
- On ROCm builds, the torch profiler uses the CUDA activity flag internally but maps to HIP; it works if `torch.cuda.is_available()` returns true.
- The trace is written when the app shuts down (Ctrl+C). On shutdown you should see a message like: `[profiler] Exported Chrome trace to: .../torch_trace.json`.
- On-demand export without stopping: send SIGUSR1 to the running process (Linux/macOS). Example: `pkill -USR1 -f profiler_runner.py`. Each signal writes a timestamped snapshot (e.g., `torch_trace-YYYYMMDD-HHMMSS-<n>.json`) and automatically restarts the profiler to continue recording; on final shutdown it writes `torch_trace.json`.

### Troubleshooting trace loading
- If Perfetto (or your browser) complains about memory or 2 GB ArrayBuffer limits, load the compressed `.json.gz` file instead of the raw `.json`.
- To reduce trace size further, keep `PROFILING_RECORD_SHAPES=0` and `PROFILING_WITH_STACK=0` (defaults). Enable them only when necessary.
- Firefox Profiler generally cannot import Chrome Trace JSON. Use Chrome `chrome://tracing` or Perfetto UI.

 ## Notes

Big thanks for all Open Source gangs that have made this possible.

## Links

* ComfyUI: https://github.com/comfyanonymous/ComfyUI
* Automatic1111: https://github.com/AUTOMATIC1111/stable-diffusion-webui
* WebUI Forge: https://github.com/lllyasviel/stable-diffusion-webui-forge
