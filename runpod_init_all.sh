#!/usr/bin/env bash
set -euo pipefail

# RunPod bootstrap — ComfyUI + Manager + TTS-Audio-Suite + IndexTTS (models+assets)
# Persistență: montează volumul la /workspace ca să nu re-descarci la fiecare boot.
#
# ENV (opțional):
#   HF_TOKEN              (salvat în $WORKSPACE/HF_TOKEN; necesar dacă HF dataset e privat)
#   WORKSPACE             (default: /workspace)
#   ASSET_DATASET         (default: LucianGn/IndexTTS2)
#   HF_REV                (default: main)
#   WF_NAME               (default: IndexTTS2.json)
#   VOICE_DIR_NAME        (default: indextts)   # subfolder în tts_audio_suite/voices_examples/
#   FORCE_TORCH_REINSTALL=1  (forțează reinstalarea Torch dacă ai coruperi)

export DEBIAN_FRONTEND=noninteractive
WORKSPACE="${WORKSPACE:-/workspace}"
COMFY="$WORKSPACE/ComfyUI"
CUSTOM="$COMFY/custom_nodes"
VENV="$COMFY/venv"
MODEL_ROOT="$COMFY/models"
MANAGER_DIR="$CUSTOM/ComfyUI-Manager"
TTS_SUITE_DIR="$CUSTOM/tts_audio_suite"
IDX_NODE_DIR="$CUSTOM/ComfyUI-Index-TTS"

ASSET_DATASET="${ASSET_DATASET:-LucianGn/IndexTTS2}"
HF_REV="${HF_REV:-main}"
WF_NAME="${WF_NAME:-IndexTTS2.json}"
VOICE_DIR_NAME="${VOICE_DIR_NAME:-indextts}"
VOICES_DST="$TTS_SUITE_DIR/voices_examples/$VOICE_DIR_NAME"
WF_DST="$COMFY/user/default/workflows"
INPUT_DIR="$COMFY/input"

# Cache-uri persistente pentru boot-uri rapide
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_NO_INPUT=1
export PIP_DEFAULT_TIMEOUT=1000
export PIP_CACHE_DIR="$WORKSPACE/.cache/pip"
export HF_HOME="$WORKSPACE/.cache/huggingface"
mkdir -p "$PIP_CACHE_DIR" "$HF_HOME" "$WORKSPACE" "$WF_DST" "$VOICES_DST" "$INPUT_DIR"

# HF token reuse
if [ -z "${HF_TOKEN:-}" ] && [ -f "$WORKSPACE/HF_TOKEN" ]; then
  export HF_TOKEN="$(cat "$WORKSPACE/HF_TOKEN")"
fi
[ -n "${HF_TOKEN:-}" ] && printf "%s" "$HF_TOKEN" > "$WORKSPACE/HF_TOKEN" || true

# OS deps
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -y || true
  apt-get install -y git git-lfs python3-venv python3-dev build-essential \
    ffmpeg aria2 curl ca-certificates libgl1 libglib2.0-0 libsndfile1 || true
  git lfs install || true
fi

# Clone/repair ComfyUI (sigur la reboot)
if [ ! -d "$COMFY/.git" ]; then
  rm -rf "$COMFY" || true
  (cd "$WORKSPACE" && git clone https://github.com/comfyanonymous/ComfyUI)
else
  (cd "$COMFY" && git reset --hard && git pull --ff-only || true)
fi
# dacă lipsesc fișierele cheie, re-clone
[ -f "$COMFY/main.py" ] || { rm -rf "$COMFY"; (cd "$WORKSPACE" && git clone https://github.com/comfyanonymous/ComfyUI); }

# Python venv
[ -d "$VENV" ] || python3 -m venv "$VENV"
# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -m pip install -U pip wheel setuptools --progress-bar off

# Torch (GPU dacă există) — cu cache persistent
_need_torch_py=$(python - <<'PY'
import importlib,sys; sys.exit(0 if importlib.util.find_spec("torch") else 1)
PY
) || true
if [ "${FORCE_TORCH_REINSTALL:-0}" = "1" ] || [ -n "${_need_torch_py:-}" ]; then
  if command -v nvidia-smi >/dev/null 2>&1; then
    python -m pip install --index-url https://download.pytorch.org/whl/cu121 \
      torch torchvision torchaudio --progress-bar off
  else
    python -m pip install torch torchvision torchaudio --progress-bar off
  fi
fi

# Comfy requirements (best effort)
[ -f "$COMFY/requirements.txt" ] && python -m pip install -r "$COMFY/requirements.txt" --progress-bar off || true

# --- Custom nodes ---

# 1) ComfyUI-Manager (UI Extensions)
if [ ! -d "$MANAGER_DIR/.git" ]; then
  git clone https://github.com/ltdrdata/ComfyUI-Manager "$MANAGER_DIR"
else
  (cd "$MANAGER_DIR" && git pull --ff-only || true)
fi
[ -f "$MANAGER_DIR/requirements.txt" ] && pip install -r "$MANAGER_DIR/requirements.txt" --progress-bar off || true

# 2) ComfyUI-Index-TTS (sursa completă 'indextts' pentru importuri)
if [ ! -d "$IDX_NODE_DIR/.git" ]; then
  git clone https://github.com/chenpipi0807/ComfyUI-Index-TTS "$IDX_NODE_DIR"
else
  (cd "$IDX_NODE_DIR" && git pull --ff-only || true)
fi
[ -f "$IDX_NODE_DIR/requirements.txt" ] && pip install -r "$IDX_NODE_DIR/requirements.txt" --progress-bar off || true

# 3) TTS-Audio-Suite (engine + auto-download IndexTTS-2 la runtime)
if [ ! -d "$TTS_SUITE_DIR/.git" ]; then
  git clone https://github.com/diodiogod/TTS-Audio-Suite "$TTS_SUITE_DIR"
else
  (cd "$TTS_SUITE_DIR" && git pull --ff-only || true)
fi
[ -f "$TTS_SUITE_DIR/requirements.txt" ] && pip install -r "$TTS_SUITE_DIR/requirements.txt" --progress-bar off || true

# Dependențe suplimentare (acoperă erorile din logurile tale)
python -m pip install -U \
  accelerate modelscope huggingface_hub hf_transfer \
  diffusers opencv-python-headless moviepy imageio imageio-ffmpeg \
  ffmpeg-python deepdiff librosa==0.10.2.post1 soundfile numba pydub --progress-bar off || true

# --- Rezolvă importul 'indextts.gpt.model_v2' pentru TTS-Audio-Suite ---
# 1) symlink către pachetul complet 'indextts' din ComfyUI-Index-TTS
VENDOR_IDX="$IDX_NODE_DIR/indextts2/vendor/indextts"
if [ -d "$VENDOR_IDX" ] && [ ! -e "$TTS_SUITE_DIR/indextts" ]; then
  ln -s "$VENDOR_IDX" "$TTS_SUITE_DIR/indextts"
fi

# 2) hf.env: PYTHONPATH sigur (fără eroare la set -u)
HF_ENV="$VENV/hf.env"
mkdir -p "$(dirname "$HF_ENV")"
cat > "$HF_ENV" <<EOF
export HF_TOKEN="${HF_TOKEN:-}"
export HF_ENDPOINT="https://huggingface.co"
export HF_HOME="${HF_HOME:-$WORKSPACE/.cache/huggingface}"
export HF_HUB_ENABLE_HF_TRANSFER=1
export DS_BUILD_OPS=0
# Importuri IndexTTS pentru TTS-Audio-Suite (fallback la gol dacă PYTHONPATH nu e setat)
export PYTHONPATH="$TTS_SUITE_DIR:$TTS_SUITE_DIR/engines/index_tts:$IDX_NODE_DIR/indextts2/vendor:\${PYTHONPATH:-}"
EOF
grep -q "hf.env" "$VENV/bin/activate" || echo 'test -f "${VIRTUAL_ENV}/hf.env" && . "${VIRTUAL_ENV}/hf.env"' >> "$VENV/bin/activate"

# --- Assets din HF: workflow + voci Morpheus (în folderele tale exacte) ---
python - <<'PY' || true
import os, pathlib, shutil
from huggingface_hub import hf_hub_download, login
tok = os.getenv("HF_TOKEN")
if tok: 
    try: login(token=tok, add_to_git_credential=True)
    except Exception: pass

repo  = os.getenv("ASSET_DATASET","LucianGn/IndexTTS2")
rev   = os.getenv("HF_REV","main")
wf    = os.getenv("WF_NAME","IndexTTS2.json")
wf_dst= pathlib.Path("/workspace/ComfyUI/user/default/workflows"); wf_dst.mkdir(parents=True, exist_ok=True)
voices_dst = pathlib.Path(os.getenv("VOICES_DST","/workspace/ComfyUI/custom_nodes/tts_audio_suite/voices_examples/indextts"))
voices_dst.mkdir(parents=True, exist_ok=True)

def fetch(name, dst_dir):
    try:
        p = hf_hub_download(repo_id=repo, repo_type="dataset", filename=name, revision=rev)
        shutil.copy2(p, dst_dir / name)
        print(f"[ok] {name} -> {dst_dir/name}")
    except Exception as e:
        print(f"[warn] {name} failed: {e}")

# Workflow
fetch(wf, wf_dst)

# Vocile (wav + .txt + .reference.txt)
names = [
    "Morpheus.wav","Morpheus.txt","Morpheus.reference.txt",
    "Morpheus_v3_british_accent.wav","Morpheus_v3_british_accent.txt","Morpheus_v3_british_accent.reference.txt",
    "Morpheus _v2_us_accent.wav","Morpheus _v2_us_accent.txt","Morpheus _v2_us_accent.reference.txt",
]
for n in names: fetch(n, voices_dst)
PY

# Launcher + start
if [ ! -f "$COMFY/start.sh" ]; then
  cat > "$COMFY/start.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source /workspace/ComfyUI/venv/bin/activate
exec python /workspace/ComfyUI/main.py --listen 0.0.0.0 --port 8188
SH
  chmod +x "$COMFY/start.sh"
fi

echo "[run] ComfyUI on 0.0.0.0:8188"
exec "$COMFY/start.sh"
