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

log() { echo "[$(date +'%H:%M:%S')] $*"; }

# ================== Sys deps ==================
log "Installing base packages..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  git ca-certificates curl python3 python3-venv python3-dev build-essential \
  procps net-tools lsof ffmpeg portaudio19-dev espeak espeak-data libsndfile1
mkdir -p "$WORKSPACE"

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

# ================== Python venv & core stack ==================
if [ ! -d "$COMFY_DIR/venv" ]; then
  log "Creating Python venv"
  python3 -m venv "$COMFY_DIR/venv"
fi
# shellcheck source=/dev/null
source "$COMFY_DIR/venv/bin/activate"
python -m pip install --upgrade pip setuptools wheel

# --- PIN PyTorch 2.4 + CUDA 12.4 (fără TorchCodec) ---
export PIP_INDEX_URL="https://download.pytorch.org/whl/cu124"
CONSTR="$WORKSPACE/pip-constraints.txt"
cat > "$CONSTR" <<'TXT'
torch==2.4.0+cu124
torchaudio==2.4.0+cu124
torchvision==0.19.0+cu124
TXT
export PIP_CONSTRAINT="$CONSTR"

# Curățare și instalare „core”
pip uninstall -y torch torchaudio torchvision torchcodec || true
pip install --no-cache-dir --force-reinstall \
  torch==2.4.0+cu124 torchaudio==2.4.0+cu124 torchvision==0.19.0+cu124

# Persistă setările în venv pentru viitoare sesiuni
grep -q 'PIP_INDEX_URL=' "$COMFY_DIR/venv/bin/activate" || \
  echo 'export PIP_INDEX_URL=https://download.pytorch.org/whl/cu124' >> "$COMFY_DIR/venv/bin/activate"
grep -q 'PIP_CONSTRAINT=' "$COMFY_DIR/venv/bin/activate" || \
  echo 'export PIP_CONSTRAINT=/workspace/pip-constraints.txt' >> "$COMFY_DIR/venv/bin/activate"

# Dezactivează definitiv TorchCodec (folosește SoundFile/FFmpeg)
export TORCHAUDIO_USE_TORCHCODEC=0
grep -q 'TORCHAUDIO_USE_TORCHCODEC' "$COMFY_DIR/venv/bin/activate" || \
  echo 'export TORCHAUDIO_USE_TORCHCODEC=0' >> "$COMFY_DIR/venv/bin/activate"

# Dependențe ComfyUI de bază
[ -f "$COMFY_DIR/requirements.txt" ] && pip install --no-cache-dir -r "$COMFY_DIR/requirements.txt"

# ================== ComfyUI-Manager ==================
CUSTOM_NODES="$COMFY_DIR/custom_nodes"
MANAGER_DIR="$CUSTOM_NODES/ComfyUI-Manager"
mkdir -p "$CUSTOM_NODES"
if [ ! -d "$MANAGER_DIR/.git" ]; then
  log "Cloning ComfyUI-Manager"
  git clone https://github.com/ltdrdata/ComfyUI-Manager "$MANAGER_DIR" || true
else
  log "Updating ComfyUI-Manager"
  git -C "$MANAGER_DIR" fetch --all || true
fi
if [ -d "$MANAGER_DIR/.git" ]; then
  M_HEAD="$(git -C "$MANAGER_DIR" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)"
  M_BRANCH="${M_HEAD#origin/}"
  git -C "$MANAGER_DIR" checkout -B "$M_BRANCH" "origin/$M_BRANCH" || true
  git -C "$MANAGER_DIR" reset --hard "origin/$M_BRANCH" || true
  [ -f "$MANAGER_DIR/requirements.txt" ] && pip install --no-cache-dir -r "$MANAGER_DIR/requirements.txt" || true
else
  log "WARNING: ComfyUI-Manager clone failed; continuing without Manager."
fi

# ================== AUDIO deps pentru TTS Audio Suite (fără TorchCodec) ==================
pip install --no-cache-dir \
  soundfile==0.13.1 librosa==0.11.0 numba==0.62.1 \
  cached-path==1.8.0 onnxruntime-gpu==1.20.1 audio-separator==0.39.1

# Instalează deps pentru toate custom nodes (dacă au requirements.txt)
if [ -d "$CUSTOM_NODES" ]; then
  while IFS= read -r -d '' req; do
    log "Installing custom node deps: $(dirname "$req")/requirements.txt"
    pip install --no-cache-dir -r "$req" || true
  done < <(find "$CUSTOM_NODES" -maxdepth 2 -type f -name 'requirements.txt' -print0)
fi

# ================== Conversie automată voice refs -> WAV ==================
TTS_SUITE_DIR="$CUSTOM_NODES/TTS-Audio-Suite"
if [ -d "$TTS_SUITE_DIR" ]; then
  log "Converting MP3/M4A/AAC voice refs to WAV (44100 Hz, mono)..."
  while IFS= read -r -d '' f; do
    wav="${f%.*}.wav"
    if [ ! -f "$wav" ]; then
      ffmpeg -y -hide_banner -loglevel error -i "$f" -ar 44100 -ac 1 "$wav" || true
    fi
  done < <(find "$TTS_SUITE_DIR" -type f \( -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.aac' \) -print0)
fi

# ================== Self-tests ==================
python - <<'PY'
import os, torch, torchaudio, soundfile, tempfile, numpy as np
print("Torch:", torch.__version__)
print("Torchaudio:", torchaudio.__version__)
print("TORCHAUDIO_USE_TORCHCODEC =", os.getenv("TORCHAUDIO_USE_TORCHCODEC"))
# gen un ton scurt, salveaza WAV, reîncarcă prin torchaudio
sr=44100
x=(0.1*np.sin(2*np.pi*440*np.arange(int(0.1*sr))/sr)).astype('float32')
tmp= tempfile.NamedTemporaryFile(suffix=".wav", delete=False).name
soundfile.write(tmp, x, sr)
wav, rate = torchaudio.load(tmp)
assert rate==sr and wav.numel()>0
print("Audio IO OK ✅ using backend without TorchCodec")
PY

# ================== Launch ComfyUI (background) ==================
cd "$COMFY_DIR"
( command -v fuser >/dev/null 2>&1 && fuser -k "${COMFY_PORT}/tcp" ) || true
log "Starting ComfyUI on ${HOST}:${COMFY_PORT}"
export PYTHONUNBUFFERED=1
export TORCHAUDIO_USE_TORCHCODEC=0
nohup python main.py --listen "$HOST" --port "$COMFY_PORT" > "$WORKSPACE/comfyui.log" 2>&1 &
log "Comfy log at: $WORKSPACE/comfyui.log"

# ================== JupyterLab (optional, foreground) ==================
if [ "$SKIP_JUPYTER" != "1" ]; then
  log "Installing JupyterLab"
  pip install --no-cache-dir jupyterlab
  log "Starting JupyterLab on 0.0.0.0:${JUPYTER_PORT} (token: ${JUPYTER_TOKEN})"
  exec jupyter lab --ServerApp.ip=0.0.0.0 --ServerApp.port="$JUPYTER_PORT" \
    --ServerApp.allow_remote_access=True --ServerApp.root_dir="$JUPYTER_ROOT" \
    --ServerApp.allow_origin="*" --ServerApp.disable_check_xsrf=True \
    --ServerApp.allow_root=True --IdentityProvider.token=""
else
  log "ComfyUI running. Tail logs with: tail -f $WORKSPACE/comfyui.log"
  exec bash -lc "while sleep 3600; do :; done"
fi
