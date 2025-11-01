#!/usr/bin/env bash
set -euo pipefail

# ============== Config ==============
WORKSPACE="${WORKSPACE:-/workspace}"
COMFY_DIR="${COMFY_DIR:-$WORKSPACE/ComfyUI}"
HOST="${COMFY_HOST:-0.0.0.0}"
COMFY_PORT="${COMFY_PORT:-8188}"

SKIP_JUPYTER="${SKIP_JUPYTER:-0}"
JUPYTER_PORT="${JUPYTER_PORT:-8888}"
JUPYTER_ROOT="${JUPYTER_ROOT:-$WORKSPACE}"

export HF_TOKEN="${HF_TOKEN:-}"          # optional

# Pin PyTorch ca pe PC (dacă vrei 2.8/cu128)
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

log(){ echo "[$(date +'%F %T')] $*" | tee -a "$LOGFILE"; }
step(){ local f="$1"; shift; [ -f "$f" ] && { log "✓ Skip: $*"; return 1; } || { log "→ $*"; return 0; } }
mark(){ mkdir -p "$STAMP_DIR"; : > "$1"; }

mkdir -p "$WORKSPACE"
exec > >(tee -a "$LOGFILE") 2>&1
log "=== ComfyUI + TTS Audio Suite init (loop-safe, cache, Jupyter) ==="

# ---------- Cache-uri HF ----------
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$WORKSPACE/.cache}"
export HF_HOME="${HF_HOME:-$WORKSPACE/.cache/huggingface}"
export HF_HUB_CACHE="${HF_HUB_CACHE:-$HF_HOME/hub}"
mkdir -p "$HF_HUB_CACHE"

# Preferințe runtime (activate DEVREME ca să fie vizibile în toate Python-urile)
export HF_HUB_ENABLE_HF_TRANSFER=1
export TRANSFORMERS_USE_SAFETENSORS=1
export SAFETENSORS_FAST_GPU=1
export TORCHAUDIO_USE_TORCHCODEC=0   # împiedică apelul implicit TorchCodec

# ---------- Sys deps ----------
if step "$S_SYS" "Install base packages"; then
  apt-get update || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git git-lfs ca-certificates curl python3 python3-venv python3-dev build-essential \
    procps net-tools lsof ffmpeg portaudio19-dev espeak espeak-data aria2 || true
  git lfs install || true
  mark "$S_SYS"
fi

# ---------- ComfyUI ----------
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

# ---------- VENV ----------
if step "$S_VENV" "Create/prepare Python venv"; then
  [ -d "$COMFY_DIR/venv" ] || python3 -m venv "$COMFY_DIR/venv"
  # shellcheck disable=SC1091
  source "$COMFY_DIR/venv/bin/activate"
  python -m pip install --upgrade pip setuptools wheel
  mark "$S_VENV"
else
  # shellcheck disable=SC1091
  source "$COMFY_DIR/venv/bin/activate"
fi

# IMPORTANT: instalăm aici hub + transfer (în VENV)
pip install --no-cache-dir "huggingface_hub==0.35.3" "hf_transfer>=0.1.6" safetensors || true

# ---------- Torch (opțional pin 2.8/cu128) ----------
if [ "$PIN_TORCH" = "1" ] && step "$S_TORCH" "Pin PyTorch stack ($TORCH_PKGS)"; then
  pip uninstall -y torch torchaudio torchvision torchcodec || true
  if [ -n "$TORCH_INDEX_URL" ]; then
    pip install --no-cache-dir --force-reinstall --no-deps --index-url "$TORCH_INDEX_URL" $TORCH_PKGS
  else
    pip install --no-cache-dir --force-reinstall --no-deps $TORCH_PKGS
  fi
  unset PIP_INDEX_URL PIP_EXTRA_INDEX_URL PIP_CONSTRAINT || true
  mark "$S_TORCH"
else
  log "✓ Skip: Leaving existing PyTorch as-is."
fi

# ---------- Dependențe Comfy core ----------
if [ -f "$COMFY_DIR/requirements.txt" ]; then
  log "Installing ComfyUI requirements.txt"
  pip install --no-cache-dir -r "$COMFY_DIR/requirements.txt" || true
fi

# ---------- ComfyUI-Manager (safe boot) ----------
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

# Prima pornire -> dezactivează temporar Manager-ul
if [ ! -f "$S_FBOOT" ]; then
  log "First boot SAFE mode: disable ComfyUI-Manager to avoid UI update loops"
  [ -d "$MANAGER_DIR" ] && mv "$MANAGER_DIR" "${MANAGER_DIR}.off" || true
  : > "$S_FBOOT"
else
  if [ -d "${MANAGER_DIR}.off" ]; then
    log "Re-enabling ComfyUI-Manager"
    mv "${MANAGER_DIR}.off" "$MANAGER_DIR" || true
  fi
fi

# ---------- Audio deps pentru TTS Audio Suite ----------
if step "$S_AUDIO" "Install audio deps"; then
  pip install --no-cache-dir \
    soundfile==0.13.1 librosa==0.11.0 numba==0.62.1 \
    cached-path==1.8.0 onnxruntime-gpu==1.20.1 audio-separator==0.39.1
  mark "$S_AUDIO"
fi

# ---------- Instalează deps pentru toate custom nodes ----------
if step "$S_CUST" "Install custom-nodes requirements"; then
  if [ -d "$CUSTOM_NODES" ]; then
    while IFS= read -r -d '' req; do
      log "→ Installing: $(dirname "$req")/requirements.txt"
      pip install --no-cache-dir -r "$req" || true
    done < <(find "$CUSTOM_NODES" -maxdepth 2 -type f -name 'requirements.txt' -print0)
  fi
  mark "$S_CUST"
fi

# ---------- Prefetch (încălzire cache HF, fără a opri init pe eroare) ----------
if step "$S_PREFETCH" "Prefetch tokenizer + HuBERT into HF cache"; then
  set +e
  python - <<'PY'
import os
from huggingface_hub import snapshot_download
cache_dir = os.environ.get("HF_HUB_CACHE", "/workspace/.cache/huggingface/hub")
def grab(repo, allow=None):
    kw = dict(repo_id=repo, cache_dir=cache_dir, local_files_only=False, resume_download=True)
    if allow: kw["allow_patterns"]=allow
    try:
        p = snapshot_download(**kw)
        print(f"[prefetch] OK {repo} -> {p}")
    except Exception as e:
        print(f"[prefetch] WARN {repo}: {e} -> retry w/o hf_transfer")
        os.environ["HF_HUB_ENABLE_HF_TRANSFER"]="0"
        try:
            p = snapshot_download(**kw)
            print(f"[prefetch] OK(fallback) {repo} -> {p}")
        except Exception as e2:
            print(f"[prefetch] SKIP {repo}: {e2}")
grab("bosonai/higgs-audio-v2-tokenizer")
grab("facebook/hubert-base-ls960", allow=["config.json","pytorch_model.bin","preprocessor_config.json"])
PY
  set -e
  mark "$S_PREFETCH"
fi

# ---------- Convertor voice refs -> WAV ----------
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

# ---------- Self-test audio (nu oprim init pe eroare) ----------
log "Running audio self-test"
set +e
python - <<'PY'
import os, soundfile, tempfile, numpy as np
# citim/ scriem prin soundfile ca să nu atingem TorchCodec deloc
print("Audio Self-Test: TORCHAUDIO_USE_TORCHCODEC =", os.getenv("TORCHAUDIO_USE_TORCHCODEC"))
sr=44100
x=(0.1*np.sin(2*np.pi*440*np.arange(int(0.1*sr))/sr)).astype('float32')
tmp= tempfile.NamedTemporaryFile(suffix=".wav", delete=False).name
soundfile.write(tmp, x, sr)
data, rate = soundfile.read(tmp)
assert rate==sr and data.size>0
print("Audio IO OK ✅ (soundfile path)")
PY
set -e

# ---------- Launch ComfyUI ----------
cd "$COMFY_DIR"
if pgrep -f "$COMFY_DIR/venv/bin/python .*main.py" >/dev/null 2>&1; then
  log "ComfyUI already running; skip start."
else
  ( command -v fuser >/dev/null 2>&1 && fuser -k "${COMFY_PORT}/tcp" ) || true
  log "Starting ComfyUI on ${HOST}:${COMFY_PORT}"
  export PYTHONUNBUFFERED=1
  nohup python main.py --listen "$HOST" --port "$COMFY_PORT" > "$COMFY_LOG" 2>&1 &
  log "Comfy log at: $COMFY_LOG"
fi

# ---------- JupyterLab ----------
if [ "$SKIP_JUPYTER" != "1" ]; then
  if step "$S_JUPYTER" "Installing JupyterLab"; then
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
