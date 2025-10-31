#!/usr/bin/env bash
set -euo pipefail

# ================== Config ==================
WORKSPACE="${WORKSPACE:-/workspace}"
COMFY_DIR="${COMFY_DIR:-$WORKSPACE/ComfyUI}"
HOST="${COMFY_HOST:-0.0.0.0}"
COMFY_PORT="${COMFY_PORT:-8188}"

# Jupyter (set SKIP_JUPYTER=1 ca să-l dezactivezi)
SKIP_JUPYTER="${SKIP_JUPYTER:-0}"
JUPYTER_PORT="${JUPYTER_PORT:-8888}"
JUPYTER_TOKEN="${JUPYTER_TOKEN:-runpod}"
JUPYTER_ROOT="${JUPYTER_ROOT:-$WORKSPACE}"

LOGFILE="$WORKSPACE/init.log"
COMFY_LOG="$WORKSPACE/comfyui.log"
STAMP="$WORKSPACE/.first_boot_done"

log(){ echo "[$(date +'%F %T')] $*" | tee -a "$LOGFILE" ; }

mkdir -p "$WORKSPACE"
exec > >(tee -a "$LOGFILE") 2>&1

log "=== First-boot safe init starting ==="

# ================== Sys deps ==================
log "Installing base packages (apt)..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  git ca-certificates curl python3 python3-venv python3-dev build-essential \
  procps net-tools lsof ffmpeg portaudio19-dev espeak espeak-data

# ================== ComfyUI clone/update ==================
if [ ! -d "$COMFY_DIR/.git" ]; then
  log "Cloning ComfyUI -> $COMFY_DIR"
  git clone https://github.com/comfyanonymous/ComfyUI.git "$COMFY_DIR"
else
  log "Updating ComfyUI"
  git -C "$COMFY_DIR" fetch --all || true
  CU_HEAD="$(git -C "$COMFY_DIR" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/master)"
  CU_BRANCH="${CU_HEAD#origin/}"
  git -C "$COMFY_DIR" checkout -B "$CU_BRANCH" "origin/$CU_BRANCH" || true
  git -C "$COMFY_DIR" reset --hard "origin/$CU_BRANCH" || true
fi

# ================== Python venv ==================
if [ ! -d "$COMFY_DIR/venv" ]; then
  log "Creating Python venv"
  python3 -m venv "$COMFY_DIR/venv"
fi
# shellcheck source=/dev/null
source "$COMFY_DIR/venv/bin/activate"
python -m pip install --upgrade pip setuptools wheel

# ================== Torch stack (pin cu124) ==================
# Install *only* torch/torchaudio/torchvision from PyTorch mirror, without changing global index
pip install --no-cache-dir \
  --index-url https://download.pytorch.org/whl/cu124 \
  torch==2.4.0+cu124 torchaudio==2.4.0+cu124 torchvision==0.19.0+cu124

# Ensure any previous global pin is removed for the rest of pip installs
unset PIP_INDEX_URL || true
unset PIP_EXTRA_INDEX_URL || true
unset PIP_CONSTRAINT || true

# Persist only the TorchCodec toggle in venv
grep -q 'TORCHAUDIO_USE_TORCHCODEC' "$COMFY_DIR/venv/bin/activate" || \
  echo 'export TORCHAUDIO_USE_TORCHCODEC=0' >> "$COMFY_DIR/venv/bin/activate"
export TORCHAUDIO_USE_TORCHCODEC=0

# ================== Dependențe ComfyUI & Manager ==================
# (ComfyUI core)
[ -f "$COMFY_DIR/requirements.txt" ] && pip install --no-cache-dir -r "$COMFY_DIR/requirements.txt"

# (Manager)
CUSTOM_NODES="$COMFY_DIR/custom_nodes"
MANAGER_DIR="$CUSTOM_NODES/ComfyUI-Manager"
mkdir -p "$CUSTOM_NODES"
if [ ! -d "$MANAGER_DIR/.git" ]; then
  log "Cloning ComfyUI-Manager"
  git clone https://github.com/ltdrdata/ComfyUI-Manager "$MANAGER_DIR" || true
else
  log "Updating ComfyUI-Manager"
  git -C "$MANAGER_DIR" fetch --all || true
  M_HEAD="$(git -C "$MANAGER_DIR" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)"
  M_BRANCH="${M_HEAD#origin/}"
  git -C "$MANAGER_DIR" checkout -B "$M_BRANCH" "origin/$M_BRANCH" || true
  git -C "$MANAGER_DIR" reset --hard "origin/$M_BRANCH" || true
fi
[ -f "$MANAGER_DIR/requirements.txt" ] && pip install --no-cache-dir -r "$MANAGER_DIR/requirements.txt" || true

# ================== AUDIO deps pentru TTS Audio Suite ==================
pip install --no-cache-dir \
  soundfile==0.13.1 librosa==0.11.0 numba==0.62.1 \
  cached-path==1.8.0 onnxruntime-gpu==1.20.1 audio-separator==0.39.1

# ================== Instalează deps pentru toate custom nodes ==================
if [ -d "$CUSTOM_NODES" ]; then
  while IFS= read -r -d '' req; do
    log "Installing custom node deps: $(dirname "$req")/requirements.txt"
    pip install --no-cache-dir -r "$req" || true
  done < <(find "$CUSTOM_NODES" -maxdepth 2 -type f -name 'requirements.txt' -print0)
fi

# ================== Convertor automat voice refs -> WAV ==================
VOICES_ROOT="$CUSTOM_NODES/TTS-Audio-Suite/voices_examples"
if [ -d "$VOICES_ROOT" ]; then
  log "Converting voice refs to WAV (44.1kHz mono)..."
  while IFS= read -r -d '' f; do
    wav="${f%.*}.wav"
    [ -f "$wav" ] || ffmpeg -y -hide_banner -loglevel error -i "$f" -ar 44100 -ac 1 "$wav"
  done < <(find "$VOICES_ROOT" -type f \( -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.aac' \) -print0)
fi

# ================== Self-test audio (fără TorchCodec) ==================
python - <<'PY'
import os, torchaudio, soundfile, tempfile, numpy as np
print("Audio Self-Test: TORCHAUDIO_USE_TORCHCODEC =", os.getenv("TORCHAUDIO_USE_TORCHCODEC"))
sr=44100
x=(0.1*np.sin(2*np.pi*440*np.arange(int(0.1*sr))/sr)).astype('float32')
tmp= tempfile.NamedTemporaryFile(suffix=".wav", delete=False).name
soundfile.write(tmp, x, sr)
wav, rate = torchaudio.load(tmp)
assert rate==sr and wav.numel()>0
print("Audio IO OK ✅ (torchaudio 2.4 no TorchCodec)")
PY

# ================== Safe boot pentru prima pornire ==================
SAFE_BOOT=0
if [ ! -f "$STAMP" ]; then
  SAFE_BOOT=1
  log "First boot detected -> SAFE_BOOT=1 (dezactivez temporar ComfyUI-Manager ca să evit loop-ul)."
  [ -d "$MANAGER_DIR" ] && mv "$MANAGER_DIR" "${MANAGER_DIR}.off" || true
  touch "$STAMP"
else
  # re-enable Manager dacă a fost oprit la primul boot
  if [ -d "${MANAGER_DIR}.off" ]; then
    log "Re-enabling ComfyUI-Manager."
    mv "${MANAGER_DIR}.off" "$MANAGER_DIR" || true
  fi
fi

# ================== Launch ComfyUI (guard împotriva dublării) ==================
cd "$COMFY_DIR"
if pgrep -f "$COMFY_DIR/venv/bin/python .*main.py" >/dev/null 2>&1; then
  log "ComfyUI pare deja pornit; sar peste start."
else
  ( command -v fuser >/dev/null 2>&1 && fuser -k "${COMFY_PORT}/tcp" ) || true
  log "Starting ComfyUI on ${HOST}:${COMFY_PORT}"
  export PYTHONUNBUFFERED=1
  export TORCHAUDIO_USE_TORCHCODEC=0
  nohup python main.py --listen "$HOST" --port "$COMFY_PORT" > "$COMFY_LOG" 2>&1 &
  log "Comfy log at: $COMFY_LOG"
fi

# ================== JupyterLab (optional, foreground) ==================
if [ "$SKIP_JUPYTER" != "1" ]; then
  log "Installing JupyterLab"
  pip install --no-cache-dir jupyterlab
  log "Starting JupyterLab on 0.0.0.0:${JUPYTER_PORT} (no token)"
  exec jupyter lab --ServerApp.ip=0.0.0.0 --ServerApp.port="$JUPYTER_PORT" \
    --ServerApp.allow_remote_access=True --ServerApp.root_dir="$JUPYTER_ROOT" \
    --ServerApp.allow_origin="*" --ServerApp.disable_check_xsrf=True \
    --ServerApp.allow_root=True --IdentityProvider.token=""
else
  log "ComfyUI running. Tail logs with: tail -f $COMFY_LOG"
  exec bash -lc "while sleep 3600; do :; done"
fi
