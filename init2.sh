#!/usr/bin/env bash
set -euo pipefail

# ============== Config (editabile) ==============
WORKSPACE="${WORKSPACE:-/workspace}"
COMFY_DIR="${COMFY_DIR:-$WORKSPACE/ComfyUI}"
HOST="${COMFY_HOST:-0.0.0.0}"
COMFY_PORT="${COMFY_PORT:-8188}"

# Jupyter (setează SKIP_JUPYTER=1 ca să-l dezactivezi)
SKIP_JUPYTER="${SKIP_JUPYTER:-0}"
JUPYTER_PORT="${JUPYTER_PORT:-8888}"
JUPYTER_ROOT="${JUPYTER_ROOT:-$WORKSPACE}"

# HF Token (dacă ai acces gated / vrei viteză + rate limit mai mare)
export HF_TOKEN="${HF_TOKEN:-}"

# PyTorch control:
#  - implicit NU schimbă stack-ul existent.
#  - dacă vrei să impui versiune (ex. 2.8 cu CUDA 12.8, ca pe PC), setează:
#    PIN_TORCH=1 TORCH_INDEX_URL=https://download.pytorch.org/whl/cu128 TORCH_PKGS="torch==2.8.0+cu128 torchaudio==2.8.0+cu128 torchvision==0.23.0+cu128"
PIN_TORCH="${PIN_TORCH:-0}"
TORCH_INDEX_URL="${TORCH_INDEX_URL:-}"
TORCH_PKGS="${TORCH_PKGS:-}"

LOGFILE="$WORKSPACE/init.log"
COMFY_LOG="$WORKSPACE/comfyui.log"

STAMP_DIR="$WORKSPACE/.boot"
S_SYS="$STAMP_DIR/sys.ok"
S_COMFY="$STAMP_DIR/comfy.ok"
S_VENV="$STAMP_DIR/venv.ok"
S_TORCH="$STAMP_DIR/torch.ok"
S_MGR="$STAMP_DIR/manager.ok"
S_AUDIO="$STAMP_DIR/audio.ok"
S_CUST="$STAMP_DIR/custom.ok"
S_WAVS="$STAMP_DIR/voices.ok"
S_PREFETCH="$STAMP_DIR/prefetch.ok"
S_FBOOT="$STAMP_DIR/first_boot_done"
S_JUPYTER="$STAMP_DIR/jupyter.ok"
S_SPEED="$STAMP_DIR/speed.ok"

log(){ echo "[$(date +'%F %T')] $*" | tee -a "$LOGFILE" ; }
step(){ local f="$1"; shift; [ -f "$f" ] && { log "✓ Skip: $*"; return 1; } || { log "→ $*"; return 0; } }
mark(){ mkdir -p "$STAMP_DIR"; : > "$1"; }

mkdir -p "$WORKSPACE"
exec > >(tee -a "$LOGFILE") 2>&1
log "=== Idempotent ComfyUI + TTS Audio Suite init (speed+cache+safe-boot) ==="

# ============== Speed Pack + Cache (HF + LFS + aria2) ==============
if step "$S_SPEED" "Install git-lfs + aria2, enable HF Transfer, set caches"; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends git-lfs aria2
  git lfs install

  # Cache-uri persistente
  export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$WORKSPACE/.cache}"
  export HF_HOME="${HF_HOME:-$WORKSPACE/.cache/huggingface}"
  export HF_HUB_CACHE="${HF_HUB_CACHE:-$HF_HOME/hub}"
  mkdir -p "$HF_HUB_CACHE"

  # Downloader HF rapid (Rust)
  python3 -m pip install --upgrade pip setuptools wheel
  python3 -m pip install --no-cache-dir "huggingface_hub==0.35.3" "hf_transfer>=0.1.6"

  # Activează HF transfer parționat
  export HF_HUB_ENABLE_HF_TRANSFER=1
  # Folosește safetensors rapid pe GPU când e suportat
  export SAFETENSORS_FAST_GPU=1
  export TRANSFORMERS_USE_SAFETENSORS=1

  # Dacă ai token, lasă-l vizibil pentru huggingface_hub
  if [ -n "${HF_TOKEN:-}" ]; then
    export HUGGING_FACE_HUB_TOKEN="$HF_TOKEN"
  fi
  mark "$S_SPEED"
fi

# ============== Sys deps (minime + audio) ==============
if step "$S_SYS" "Installing base packages (apt)"; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git ca-certificates curl python3 python3-venv python3-dev build-essential \
    procps net-tools lsof ffmpeg portaudio19-dev espeak espeak-data
  mark "$S_SYS"
fi

# ============== ComfyUI clone/update ==============
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

# ============== Python venv ==============
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

# ============== (Optional) Pin PyTorch exact ==============
if [ "$PIN_TORCH" = "1" ] && step "$S_TORCH" "Pin PyTorch stack ($TORCH_PKGS) via $TORCH_INDEX_URL"; then
  pip uninstall -y torch torchaudio torchvision torchcodec || true
  if [ -n "$TORCH_INDEX_URL" ]; then
    pip install --no-cache-dir --force-reinstall --no-deps --index-url "$TORCH_INDEX_URL" $TORCH_PKGS
  else
    # Dacă nu dai index explicit, instalează din indexul implicit
    pip install --no-cache-dir --force-reinstall --no-deps $TORCH_PKGS
  fi
  # curăță variabilele de pip pentru restul dependențelor
  unset PIP_INDEX_URL PIP_EXTRA_INDEX_URL PIP_CONSTRAINT || true
  mark "$S_TORCH"
else
  log "✓ Skip: Leaving existing PyTorch as-is (recommended unless ai un motiv clar)."
fi

# ============== Dependențe ComfyUI core ==============
if [ -f "$COMFY_DIR/requirements.txt" ]; then
  log "Installing ComfyUI requirements.txt"
  pip install --no-cache-dir -r "$COMFY_DIR/requirements.txt" || true
fi

# ============== ComfyUI-Manager (safe-boot) ==============
CUSTOM_NODES="$COMFY_DIR/custom_nodes"
MANAGER_DIR="$CUSTOM_NODES/ComfyUI-Manager"
mkdir -p "$CUSTOM_NODES"

if step "$S_MGR" "Sync ComfyUI-Manager"; then
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
fi

# Prima pornire: dezactivez temporar Manager-ul ca să evit loop-uri
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

# ============== Audio deps pentru TTS Audio Suite ==============
if step "$S_AUDIO" "Install audio deps for TTS Audio Suite"; then
  pip install --no-cache-dir \
    soundfile==0.13.1 librosa==0.11.0 numba==0.62.1 \
    cached-path==1.8.0 onnxruntime-gpu==1.20.1 audio-separator==0.39.1
  mark "$S_AUDIO"
fi

# ============== Instalează deps pentru toate custom nodes ==============
if step "$S_CUST" "Install custom nodes requirements (if any)"; then
  if [ -d "$CUSTOM_NODES" ]; then
    while IFS= read -r -d '' req; do
      log "→ Installing: $(dirname "$req")/requirements.txt"
      pip install --no-cache-dir -r "$req" || true
    done < <(find "$CUSTOM_NODES" -maxdepth 2 -type f -name 'requirements.txt' -print0)
  fi
  mark "$S_CUST"
fi

# ============== Convertor automat voice refs -> WAV (44.1kHz mono) ==============
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

# ============== Prefetch (încălzește cache-ul HF) ==============
if step "$S_PREFETCH" "Prefetch common models/tokenizers into HF cache"; then
  python - <<'PY'
import os
from huggingface_hub import snapshot_download

cache_dir = os.environ.get("HF_HUB_CACHE", "/workspace/.cache/huggingface/hub")

def grab(repo, allow_patterns=None):
    kw = dict(repo_id=repo, cache_dir=cache_dir, local_files_only=False, resume_download=True)
    if allow_patterns: kw["allow_patterns"] = allow_patterns
    p = snapshot_download(**kw)
    print(f"[prefetch] {repo} -> {p}")

# Higgs tokenizer + HuBERT (folosite de tokenizerul HiggsAudio)
grab("bosonai/higgs-audio-v2-tokenizer")
grab("facebook/hubert-base-ls960", allow_patterns=["config.json","pytorch_model.bin","preprocessor_config.json"])
PY
  mark "$S_PREFETCH"
fi

# ============== Self-test audio (torchaudio; fără TorchCodec) ==============
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
print("Audio IO OK ✅")
PY

# ============== Launch ComfyUI (guard împotriva dublării) ==============
cd "$COMFY_DIR"
if pgrep -f "$COMFY_DIR/venv/bin/python .*main.py" >/dev/null 2>&1; then
  log "ComfyUI already running; skip start."
else
  ( command -v fuser >/dev/null 2>&1 && fuser -k "${COMFY_PORT}/tcp" ) || true
  log "Starting ComfyUI on ${HOST}:${COMFY_PORT}"
  export PYTHONUNBUFFERED=1
  # Preferă safetensors & HF transfer la runtime
  export TRANSFORMERS_USE_SAFETENSORS=1
  export SAFETENSORS_FAST_GPU=1
  export HF_HUB_ENABLE_HF_TRANSFER=1
  # (opțional) dezactivează TorchCodec cu torchaudio dacă te-a mușcat în trecut
  export TORCHAUDIO_USE_TORCHCODEC=0
  nohup python main.py --listen "$HOST" --port "$COMFY_PORT" > "$COMFY_LOG" 2>&1 &
  log "Comfy log at: $COMFY_LOG"
fi

# ============== JupyterLab (foreground) ==============
if [ "$SKIP_JUPYTER" != "1" ]; then
  if step "$S_JUPYTER" "Installing JupyterLab (first time may take a bit)"; then
    pip install --no-cache-dir jupyterlab
    mark "$S_JUPYTER"
  else
    log "✓ Skip: JupyterLab already installed"
  fi
  log "Starting JupyterLab on 0.0.0.0:${JUPYTER_PORT} (no token)"
  exec jupyter lab --ServerApp.ip=0.0.0.0 --ServerApp.port="$JUPYTER_PORT" \
    --ServerApp.allow_remote_access=True --ServerApp.root_dir="$JUPYTER_ROOT" \
    --ServerApp.allow_origin="*" --ServerApp.disable_check_xsrf=True \
    --ServerApp.allow_root=True --IdentityProvider.token=""
else
  log "ComfyUI running. Tail logs with: tail -f $COMFY_LOG"
  exec bash -lc "while sleep 3600; do :; done"
fi
