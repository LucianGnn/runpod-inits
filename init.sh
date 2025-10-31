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

STAMP_DIR="$WORKSPACE/.boot"
S_SYS="$STAMP_DIR/sys.ok"
S_VENV="$STAMP_DIR/venv.ok"
S_TORCH="$STAMP_DIR/torch.ok"
S_COMFY="$STAMP_DIR/comfy.ok"
S_MGR="$STAMP_DIR/manager.cloned"
S_AUDIO="$STAMP_DIR/audio.ok"
S_CUST="$STAMP_DIR/custom.ok"
S_WAVS="$STAMP_DIR/voices.ok"
S_FBOOT="$STAMP_DIR/first_boot_done"

log(){ echo "[$(date +'%F %T')] $*" | tee -a "$LOGFILE" ; }
step(){ local f="$1"; shift; [ -f "$f" ] && { log "✓ Skip: $*"; return 1; } || { log "→ $*"; return 0; } }
mark(){ mkdir -p "$STAMP_DIR"; : > "$1"; }

mkdir -p "$WORKSPACE"
exec > >(tee -a "$LOGFILE") 2>&1
log "=== Idempotent ComfyUI + TTS Audio Suite init ==="

# ================== Sys deps ==================
if step "$S_SYS" "Installing base packages (apt)"; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git ca-certificates curl python3 python3-venv python3-dev build-essential \
    procps net-tools lsof ffmpeg portaudio19-dev espeak espeak-data
  mark "$S_SYS"
fi

# ================== ComfyUI clone/update ==================
if step "$S_COMFY" "Clone/Update ComfyUI -> $COMFY_DIR"; then
  if [ ! -d "$COMFY_DIR/.git" ]; then
    git clone https://github.com/comfyanonymous/ComfyUI.git "$COMFY_DIR"
  else
    git -C "$COMFY_DIR" fetch --all || true
    CU_HEAD="$(git -C "$COMFY_DIR" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/master)"
    CU_BRANCH="${CU_HEAD#origin/}"
    git -C "$COMFY_DIR" checkout -B "$CU_BRANCH" "origin/$CU_BRANCH" || true
    git -C "$COMFY_DIR" reset --hard "origin/$CU_BRANCH" || true
  fi
  mark "$S_COMFY"
fi

# ================== Python venv ==================
if step "$S_VENV" "Create/prepare Python venv"; then
  [ -d "$COMFY_DIR/venv" ] || python3 -m venv "$COMFY_DIR/venv"
  # shellcheck source=/dev/null
  source "$COMFY_DIR/venv/bin/activate"
  python -m pip install --upgrade pip setuptools wheel
  mark "$S_VENV"
else
  # shellcheck source=/dev/null
  source "$COMFY_DIR/venv/bin/activate"
fi

# ================== Torch stack (pin cu124) ==================
if step "$S_TORCH" "Install PyTorch 2.4 + CUDA 12.4 (no TorchCodec)"; then
  pip uninstall -y torch torchaudio torchvision torchcodec || true
  pip install --no-cache-dir --force-reinstall --no-deps \
    torch==2.4.0+cu124 torchaudio==2.4.0+cu124 torchvision==0.19.0+cu124 \
    --index-url https://download.pytorch.org/whl/cu124
  # Nu lăsăm index-ul PyTorch setat global
  unset PIP_INDEX_URL PIP_EXTRA_INDEX_URL PIP_CONSTRAINT || true
  # Dezactivăm TorchCodec pentru torchaudio și persistăm în venv
  export TORCHAUDIO_USE_TORCHCODEC=0
  grep -q 'TORCHAUDIO_USE_TORCHCODEC' "$COMFY_DIR/venv/bin/activate" || \
    echo 'export TORCHAUDIO_USE_TORCHCODEC=0' >> "$COMFY_DIR/venv/bin/activate"
  mark "$S_TORCH"
fi

# ================== Dependențe ComfyUI ==================
if [ -f "$COMFY_DIR/requirements.txt" ]; then
  log "Installing ComfyUI requirements.txt"
  pip install --no-cache-dir -r "$COMFY_DIR/requirements.txt" || true
fi

# ================== ComfyUI-Manager ==================
CUSTOM_NODES="$COMFY_DIR/custom_nodes"
MANAGER_DIR="$CUSTOM_NODES/ComfyUI-Manager"
mkdir -p "$CUSTOM_NODES"
if [ ! -f "$S_MGR" ]; then
  log "Sync ComfyUI-Manager"
  if [ ! -d "$MANAGER_DIR/.git" ]; then
    git clone https://github.com/ltdrdata/ComfyUI-Manager "$MANAGER_DIR" || true
  else
    git -C "$MANAGER_DIR" fetch --all || true
  fi
  if [ -d "$MANAGER_DIR/.git" ]; then
    M_HEAD="$(git -C "$MANAGER_DIR" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)"
    M_BRANCH="${M_HEAD#origin/}"
    git -C "$MANAGER_DIR" checkout -B "$M_BRANCH" "origin/$M_BRANCH" || true
    git -C "$MANAGER_DIR" reset --hard "origin/$M_BRANCH" || true
    [ -f "$MANAGER_DIR/requirements.txt" ] && pip install --no-cache-dir -r "$MANAGER_DIR/requirements.txt" || true
  fi
  mark "$S_MGR"
else
  log "✓ Skip: ComfyUI-Manager already synced"
fi

# ================== AUDIO deps pentru TTS Audio Suite ==================
if step "$S_AUDIO" "Install audio deps for TTS Audio Suite"; then
  pip install --no-cache-dir \
    soundfile==0.13.1 librosa==0.11.0 numba==0.62.1 \
    cached-path==1.8.0 onnxruntime-gpu==1.20.1 audio-separator==0.39.1
  mark "$S_AUDIO"
fi

# ================== Instalează deps pentru toate custom nodes ==================
if step "$S_CUST" "Install custom nodes requirements (if any)"; then
  if [ -d "$CUSTOM_NODES" ]; then
    while IFS= read -r -d '' req; do
      log "→ Installing: $(dirname "$req")/requirements.txt"
      pip install --no-cache-dir -r "$req" || true
    done < <(find "$CUSTOM_NODES" -maxdepth 2 -type f -name 'requirements.txt' -print0)
  fi
  mark "$S_CUST"
fi

# ================== Convertor automat voice refs -> WAV ==================
VOICES_ROOT="$CUSTOM_NODES/TTS-Audio-Suite/voices_examples"
if [ -d "$VOICES_ROOT" ] && [ ! -f "$S_WAVS" ]; then
  log "Converting voice refs to WAV (44.1kHz mono)..."
  while IFS= read -r -d '' f; do
    wav="${f%.*}.wav"
    [ -f "$wav" ] || ffmpeg -y -hide_banner -loglevel error -i "$f" -ar 44100 -ac 1 "$wav"
  done < <(find "$VOICES_ROOT" -type f \( -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.aac' \) -print0)
  mark "$S_WAVS"
else
  log "✓ Skip: voice refs conversion (none or already done)"
fi

# ================== Self-test audio (fără TorchCodec) ==================
log "Running audio self-test"
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

# ================== Safe-boot Manager la prima rulare ==================
if [ ! -f "$S_FBOOT" ]; then
  log "First boot -> SAFE mode (temporarily disable ComfyUI-Manager to avoid loops)"
  [ -d "$MANAGER_DIR" ] && mv "$MANAGER_DIR" "${MANAGER_DIR}.off" || true
  : > "$S_FBOOT"
else
  if [ -d "${MANAGER_DIR}.off" ]; then
    log "Re-enabling ComfyUI-Manager"
    mv "${MANAGER_DIR}.off" "$MANAGER_DIR" || true
  fi
fi

# ================== Launch ComfyUI (guard împotriva dublării) ==================
cd "$COMFY_DIR"
if pgrep -f "$COMFY_DIR/venv/bin/python .*main.py" >/dev/null 2>&1; then
  log "ComfyUI already running; skip start."
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
  log "Installing JupyterLab (first time may take a bit)"
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
