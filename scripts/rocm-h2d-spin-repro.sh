#!/usr/bin/env bash
# Repro: ROCm gfx120x (RDNA4) H2D copies busy-spin in rocr BusyWaitSignal::WaitRelaxed
# under host-memory pressure.  https://github.com/ROCm/TheRock/issues/7832
#
# Self-contained: creates a venv, pulls a ROCm torch wheel from TheRock, then runs
# the test. Only needs: bash, python3 (3.10-3.12), curl, ~7 GiB free disk, an AMD GPU.
#
#   ./rocm-h2d-spin-repro.sh                       # auto: newest nightly for detected GPU
#   GFX=gfx1201 ./rocm-h2d-spin-repro.sh           # force arch (skip detection)
#   TORCH_SPEC='torch[device-gfx1201]==2.15.0a0+rocm10.1.0a20260902' ./rocm-h2d-spin-repro.sh
#   PY=/path/to/python-with-torch ./rocm-h2d-spin-repro.sh   # use existing torch, no venv
#   TARGET_AVAIL_GIB=2 ./rocm-h2d-spin-repro.sh    # RAM left free during the test (default 3)
#   AMD_LOG_LEVEL=3 ./rocm-h2d-spin-repro.sh       # also dump the copy path
#   ./rocm-h2d-spin-repro.sh HSA_XNACK=1 HSA_ENABLE_SDMA=0   # pass extra env to the run
#
# PASS  = every copy fast (< a few s), thread never spins on a stuck copy
# FAIL  = one+ copies take many seconds..minutes AND during them the worker thread
#         is in state R at ~100% CPU while the GPU is idle  ->  the bug
#         (a >DEADLINE faulthandler dump == a hard hang)
set -eu

# ---------------- config ----------------
HERE="$(cd "$(dirname "$0")" && pwd)"
VENV="${VENV:-$HERE/venv-rocm-repro}"
ROCM_INDEX="${ROCM_INDEX:-https://nightly.repo.amd.com/rocm/whl-next/}"
TORCH_SPEC="${TORCH_SPEC:-}"                       # empty => torch[device-<gfx>] (unpinned)
GFX="${GFX:-}"                                     # empty => auto-detect
PY="${PY:-}"                                       # empty => use/create the venv

BIGFILE="${BIGFILE:-/var/tmp/h2d_repro.bin}"
FILE_GIB="${FILE_GIB:-6}"
CHUNK_MB="${CHUNK_MB:-32}"
NCHUNKS="${NCHUNKS:-420}"
TARGET_AVAIL_GIB="${TARGET_AVAIL_GIB:-3}"          # RAM left free while the test runs
VRAM_LEAVE_GIB="${VRAM_LEAVE_GIB:-1.6}"
DEADLINE="${DEADLINE:-240}"

for kv in "$@"; do export "$kv"; done              # extra HSA_* / AMD_* env for the run

# ---------------- gpu arch ----------------
detect_gfx () {
  local n="" b
  for b in rocminfo /opt/rocm/bin/rocminfo; do
    { command -v "$b" >/dev/null 2>&1 || [ -x "$b" ]; } || continue
    n=$("$b" 2>/dev/null | grep -oE 'gfx[0-9a-f]+' | grep -v gfx000 | head -1) && [ -n "$n" ] && break
  done
  if [ -z "$n" ] && command -v rocm_agent_enumerator >/dev/null 2>&1; then
    n=$(rocm_agent_enumerator 2>/dev/null | grep -v gfx000 | head -1)
  fi
  printf '%s' "$n"
}
[ -z "$GFX" ] && GFX="$(detect_gfx)" || true
[ -z "$GFX" ] && { echo "!! could not detect GPU arch; set GFX=gfx1200 / gfx1201 / ..." >&2; exit 2; }
case "$GFX" in
  gfx1100|gfx1101|gfx1102|gfx1103|gfx110x) DEV_EXTRA="device-gfx110x" ;;
  gfx1200)                                 DEV_EXTRA="device-gfx1200" ;;
  gfx1201)                                 DEV_EXTRA="device-gfx1201" ;;
  *)                                       DEV_EXTRA="device-$GFX" ;;   # best effort
esac
echo ">> GPU arch: $GFX   pip extra: [$DEV_EXTRA]"

# ---------------- torch ----------------
if [ -z "$PY" ]; then
  if [ ! -x "$VENV/bin/python" ]; then
    echo ">> creating venv at $VENV"
    python3 -m venv "$VENV"
    "$VENV/bin/pip" -q install --upgrade pip
  fi
  PY="$VENV/bin/python"
fi
if ! "$PY" -c 'import torch' 2>/dev/null; then
  SPEC="${TORCH_SPEC:-torch[$DEV_EXTRA]}"
  echo ">> installing: $SPEC numpy   (index $ROCM_INDEX)"
  "$PY" -m pip install --pre --index-url "$ROCM_INDEX" "$SPEC" numpy
fi
"$PY" -c 'import torch,numpy; print(">> torch",torch.__version__,"| hip",torch.version.hip,"| numpy",numpy.__version__)'
"$PY" -c 'import torch,sys; sys.exit(0 if torch.cuda.is_available() else 1)' \
  || { echo "!! torch.cuda.is_available() == False — wrong wheel for $GFX?"; exit 3; }

# ---------------- big incompressible file ----------------
need=$((FILE_GIB*1024*1024*1024))
if [ ! -f "$BIGFILE" ] || [ "$(stat -c%s "$BIGFILE" 2>/dev/null || echo 0)" -lt "$need" ]; then
  echo ">> creating $BIGFILE (${FILE_GIB} GiB urandom, ~1-2 min)"
  head -c "$need" /dev/urandom > "$BIGFILE"
fi
if awk -v t="$TARGET_AVAIL_GIB" -v f="$FILE_GIB" 'BEGIN{exit !(t >= f-1)}'; then
  echo "!! TARGET_AVAIL_GIB ($TARGET_AVAIL_GIB) is not well below FILE_GIB ($FILE_GIB);" >&2
  echo "!! the file may stay page-cached and NOT reproduce. Lower TARGET_AVAIL_GIB." >&2
fi

# ---------------- adaptive RAM hog: grow (evicting page cache) until MemAvailable <= target ----------------
echo ">> pinning incompressible RAM until MemAvailable <= ${TARGET_AVAIL_GIB} GiB ..."
"$PY" -u - "$TARGET_AVAIL_GIB" <<'HOG' &
import sys,os,time
target_kb=int(float(sys.argv[1])*1048576)
def avail():
    for l in open("/proc/meminfo"):
        if l.startswith("MemAvailable"): return int(l.split()[1])
chunks=[]; step=1<<30  # 1 GiB
while avail() > target_kb:
    try:
        c=bytearray(step)
        for o in range(0,step,4096): c[o:o+64]=os.urandom(64)   # dirty every page, incompressible-ish
        chunks.append(c)
    except MemoryError:
        break
    if len(chunks)%4==0: sys.stderr.write("   hog: %d GiB, MemAvailable %.1f GiB\n"%(len(chunks),avail()/1048576)); sys.stderr.flush()
sys.stderr.write("   hog: holding %d GiB, MemAvailable %.1f GiB\n"%(len(chunks),avail()/1048576)); sys.stderr.flush()
while True:                                   # keep every page hot so it can't be reclaimed
    for c in chunks:
        for o in range(0,len(c),4096): c[o]^=1
    time.sleep(1)
HOG
HOG_PID=$!
trap 'kill -9 $HOG_PID 2>/dev/null || true' EXIT
# wait for the hog to actually reach the target (give up after ~4 min)
for _ in $(seq 1 240); do
  a=$(awk '/MemAvailable/{print int($2/1048576)}' /proc/meminfo)
  [ "$a" -le "$((TARGET_AVAIL_GIB + 1))" ] && break
  sleep 1
done
echo "--- free -m ---"; free -m | head -2

# ---------------- the test ----------------
BIGFILE="$BIGFILE" CHUNK_MB="$CHUNK_MB" NCHUNKS="$NCHUNKS" \
VRAM_LEAVE_GIB="$VRAM_LEAVE_GIB" DEADLINE="$DEADLINE" "$PY" -u - <<'PY'
import os, sys, time, threading, faulthandler, mmap, numpy as np, torch

TID   = threading.get_native_id()
STATE = {"copy_start": 0.0, "copy_idx": -1, "spin_cpu_pct": 0.0}   # main loop writes, watchdog reads
def wd():
    prev=None; INT=2.0
    while True:
        try:
            f=open(f"/proc/self/task/{TID}/stat").read().split()
            st,tk=f[2],int(f[13])+int(f[14])
            d = 0 if prev is None else tk-prev
            prev=tk
            cpu_pct = d / (INT*100.0) * 100.0          # ticks are 1/100 s
            cs=STATE["copy_start"]; stuck = bool(cs) and (time.time()-cs) > 3
            if stuck:
                STATE["spin_cpu_pct"] = max(STATE["spin_cpu_pct"], cpu_pct)
                tag = "  <<< copy #%d stalled %.0fs, thread state=%s using %.0f%% CPU%s" % (
                    STATE["copy_idx"], time.time()-cs, st, cpu_pct,
                    "  == SPINNING" if (st=="R" and cpu_pct>60) else "  (not spinning, good)")
            else:
                tag = ""
            print(f"  [wd] state={st}  {cpu_pct:3.0f}% CPU{tag}", flush=True)
        except Exception as e: print("  [wd]",e,flush=True)
        time.sleep(INT)

print("XNACK=%s SDMA=%s AMD_LOG_LEVEL=%s"%(os.environ.get("HSA_XNACK","<unset>"),
      os.environ.get("HSA_ENABLE_SDMA","<unset>"),os.environ.get("AMD_LOG_LEVEL","<unset>")),flush=True)
dev="cuda"; torch.cuda.init()
print("device:",torch.cuda.get_device_name(0),flush=True)
threading.Thread(target=wd,daemon=True).start()

free0,_=torch.cuda.mem_get_info()
ballast=torch.empty(max(0,free0-int(float(os.environ["VRAM_LEAVE_GIB"])*2**30)),dtype=torch.uint8,device=dev)
f1,_=torch.cuda.mem_get_info()
print(f"VRAM ballast set, {f1/2**30:.2f} GiB free",flush=True)

nb=int(os.environ["CHUNK_MB"])*1024*1024; N=int(os.environ["NCHUNKS"])
fd=os.open(os.environ["BIGFILE"],os.O_RDONLY); sz=os.fstat(fd).st_size
try: os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_RANDOM)          # kill readahead
except Exception: pass
def drop_cache():
    try: os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)     # evict this file from page cache
    except Exception: pass
drop_cache()
base=np.frombuffer(mmap.mmap(fd,0,prot=mmap.PROT_READ),dtype=np.uint8)
print(f"mmap {sz/2**30:.1f} GiB; {N} x  from_numpy(chunk).to(cuda).to(cpu)  ({os.environ['CHUNK_MB']} MiB); pages dropped from cache",flush=True)

faulthandler.dump_traceback_later(int(os.environ["DEADLINE"]),exit=True)
t0=time.time(); worst=0; slow=0
for i in range(N):
    if i and i%16==0: drop_cache()                    # the reads keep re-caching; keep it cold
    off=(i*nb)%(sz-nb)
    host=torch.from_numpy(base[off:off+nb])           # file-backed, pageable, non-resident
    STATE["copy_start"]=time.time(); STATE["copy_idx"]=i
    d=host.to(dev); torch.cuda.synchronize()
    e=d.to("cpu"); torch.cuda.synchronize()           # H2D then D2H, like GGUFModelPatcher.load
    dt=time.time()-STATE["copy_start"]; STATE["copy_start"]=0.0
    worst=max(worst,dt); slow+=dt>0.5; del d,e
    if dt>0.5 or i%50==0:
        print(f"  #{i:3d} copy {dt:6.2f}s  worst {worst:6.2f}s  slow(>0.5s)={slow}",flush=True)
faulthandler.cancel_dump_traceback_later()
spin = STATE["spin_cpu_pct"]
print(f"RESULT: {N} copies in {time.time()-t0:.1f}s | worst single copy {worst:.2f}s | "
      f"{slow} copies >0.5s | max CPU while a copy was stalled: {spin:.0f}%",flush=True)
# The bug is the *spin*: 100% CPU on a core while the GPU is idle and a copy hangs.
# worst>5s alone just means slow (memory pressure); the shim doesn't fix that.
if worst > 5 and spin > 60:
    print("VERDICT: FAIL (H2D copy stalls AND the thread busy-spins a core -> the bug)",flush=True)
elif worst > 5:
    print("VERDICT: STALLED-BUT-NOT-SPINNING (copies slow under pressure, but CPU is freed - shim working / bug mitigated)",flush=True)
else:
    print("VERDICT: PASS (no stalls)",flush=True)
PY
echo "python exit=$?   (a >${DEADLINE}s faulthandler dump == a hard hang)"
