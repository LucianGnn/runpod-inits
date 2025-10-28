#!/usr/bin/env bash
set -euo pipefail

# RunPod bootstrap — ComfyUI + Manager + TTS-Audio-Suite + IndexTTS (models+assets)
# Env:
#   HF_TOKEN            (optional; saved at $WORKSPACE/HF_TOKEN; needed if your HF dataset is private)
#   WORKSPACE           (default: /workspace)
#   ASSET_DATASET       (default: LucianGn/IndexTTS2)
#   HF_REV              (default: main)
#   WF_NAME             (default: IndexTTS2.json)
#   VOICE_DIR_NAME      (default: indextts)

WORKSPACE="${WORKSPACE:-/workspace}"
COMFY="$WORKSPACE/ComfyUI"
CUSTOM="$COMFY/custom_nodes"
VENV="$COMFY/venv"
MODEL_ROOT="$COMFY/models"
TTS_SUITE_DIR="$CUSTOM/tts_audio_suite"
IDX_NODE_DIR="$CUSTOM/ComfyUI-Index-TTS"
ASSET_DATASET="${ASSET_DATASET:-LucianGn/IndexTTS2}"
HF_REV="${HF_REV:-main}"
WF_NAME="${WF_NAME:-IndexTTS2.json}"
VOICE_DIR_NAME="${VOICE_DIR_NAME:-indextts}"
VOICES_DST="$TTS_SUITE_DIR/voices_examples/$VOICE_DIR_NAME"
WF_DST="$COMFY/user/default/workflows"
INPUT_DIR="$COMFY/input"

export DEBIAN_FRONTEND=noninteractive
mkdir -p "$WORKSPACE" "$WF_DST" "$VOICES_DST" "$INPUT_DIR"

# --- HF token reuse ---
if [ -z "${HF_TOKEN:-}" ] && [ -f "$WORKSPACE/HF_TOKEN" ]; then
  export HF_TOKEN="$(cat "$WORKSPACE/HF_TOKEN")"
fi
[ -n "${HF_TOKEN:-}" ] && printf "%s" "$HF_TOKEN" > "$WORKSPACE/HF_TOKEN" || true

# --- OS deps ---
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -y || true
  apt-get install -y git git-lfs python3-venv python3-dev build-essential ffmpeg aria2 curl ca-certificates libgl1 libglib2.0-0 || true
fi

# --- Clone/repair ComfyUI ---
if [ ! -d "$COMFY/.git" ]; then
  rm -rf "$COMFY" || true
  (cd "$WORKSPACE" && git clone https://github.com/comfyanonymous/ComfyUI)
else
  (cd "$COMFY" && git reset --hard && git pull --ff-only || true)
fi
# re-clone if missing core files
[ -f "$COMFY/main.py" ] || { rm -rf "$COMFY"; (cd "$WORKSPACE" && git clone https://github.com/comfyanonymous/ComfyUI); }

# --- Python venv ---
[ -d "$VENV" ] || python3 -m venv "$VENV"
# IMPORTANT: do not let 'activate' die on unset variables
set +u
# shellcheck disable=SC1091
source "$VENV/bin/activate"
set -u
python -m pip install -U pip wheel setuptools --progress-bar off

# --- Torch (GPU dacă există) ---
python - <<'PY' || \
( command -v nvidia-smi >/dev/null 2>&1 && python -m pip install --index-url https://download.pytorch.org/whl/cu121 torch torchvision torchaudio --progress-bar off ) || \
python -m pip install torch torchvision torchaudio --progress-bar off
import importlib,sys; sys.exit(0 if importlib.util.find_spec("torch") else 1)
PY

# --- Comfy requirements (best effort) ---
[ -f "$COMFY/requirements.txt" ] && python -m pip install -r "$COMFY/requirements.txt" --progress-bar off || true

# --- Custom nodes ---

# 1) ComfyUI-Manager (UI manager)
MANAGER_DIR="$CUSTOM/ComfyUI-Manager"
if [ ! -d "$MANAGER_DIR/.git" ]; then
  git clone https://github.com/ltdrdata/ComfyUI-Manager "$MANAGER_DIR"
else
  (cd "$MANAGER_DIR" && git pull --ff-only || true)
fi
[ -f "$MANAGER_DIR/requirements.txt" ] && pip install -r "$MANAGER_DIR/requirements.txt" --progress-bar off || true

# 2) ComfyUI-Index-TTS (full vendor 'indextts' code)
if [ ! -d "$IDX_NODE_DIR/.git" ]; then
  git clone https://github.com/chenpipi0807/ComfyUI-Index-TTS "$IDX_NODE_DIR"
else
  (cd "$IDX_NODE_DIR" && git pull --ff-only || true)
fi
[ -f "$IDX_NODE_DIR/requirements.txt" ] && pip install -r "$IDX_NODE_DIR/requirements.txt" --progress-bar off || true

# 3) TTS-Audio-Suite
if [ ! -d "$TTS_SUITE_DIR/.git" ]; then
  git clone https://github.com/diodiogod/TTS-Audio-Suite "$TTS_SUITE_DIR"
else
  (cd "$TTS_SUITE_DIR" && git pull --ff-only || true)
fi
[ -f "$TTS_SUITE_DIR/requirements.txt" ] && pip install -r "$TTS_SUITE_DIR/requirements.txt" --progress-bar off || true

# --- Extra deps for IndexTTS stacks ---
python -m pip install -U accelerate modelscope huggingface_hub hf_transfer --progress-bar off

# --- SAFE hf.env (NO unbound var) + PYTHONPATH fix ---
HF_ENV="$VENV/hf.env"
mkdir -p "$(dirname "$HF_ENV")"
cat > "$HF_ENV" <<'EOF'
# This file is sourced under 'set -u' sometimes; keep it safe.
export HF_ENDPOINT="https://huggingface.co"
export HF_HUB_ENABLE_HF_TRANSFER=1
export DS_BUILD_OPS=0
# ensure HF_TOKEN/HF_HOME only if present/desired
: "${HF_TOKEN:=}"
: "${HF_HOME:=}"
# Safe PYTHONPATH append
: "${PYTHONPATH:=}"
# Paths for IndexTTS imports used by TTS-Audio-Suite
export PYTHONPATH="/workspace/ComfyUI/custom_nodes/tts_audio_suite:/workspace/ComfyUI/custom_nodes/tts_audio_suite/engines/index_tts:/workspace/ComfyUI/custom_nodes/ComfyUI-Index-TTS/indextts2/vendor:${PYTHONPATH}"
EOF

# keep HF vars consistent for this session too
export HF_TOKEN="${HF_TOKEN:-}"
export HF_HOME="${MODEL_ROOT}/.hf_cache"

# --- Link vendor indextts into TTS-Audio-Suite (if missing) ---
VENDOR_IDX="$IDX_NODE_DIR/indextts2/vendor/indextts"
if [ -d "$VENDOR_IDX" ] && [ ! -e "$TTS_SUITE_DIR/indextts" ]; then
  ln -s "$VENDOR_IDX" "$TTS_SUITE_DIR/indextts"
fi

# --- Assets din HF: workflow + Voices ---
python - <<'PY' || true
import os, pathlib, shutil
from huggingface_hub import hf_hub_download
repo  = os.getenv("ASSET_DATASET","LucianGn/IndexTTS2")
rev   = os.getenv("HF_REV","main")
wf    = os.getenv("WF_NAME","IndexTTS2.json")
wf_dst= pathlib.Path("/workspace/ComfyUI/user/default/workflows"); wf_dst.mkdir(parents=True, exist_ok=True)
voices_dst = pathlib.Path("/workspace/ComfyUI/custom_nodes/tts_audio_suite/voices_examples/" + os.getenv("VOICE_DIR_NAME","indextts"))
voices_dst.mkdir(parents=True, exist_ok=True)

# Workflow
try:
    p = hf_hub_download(repo_id=repo, repo_type="dataset", filename=wf, revision=rev)
    shutil.copy2(p, wf_dst / wf)
    print(f"[ok] workflow -> {wf_dst/wf}")
except Exception as e:
    print("[warn] workflow download failed:", e)

# Voices (complete list from your dataset)
names = [
    "Morpheus.wav","Morpheus.txt","Morpheus.reference.txt",
    "Morpheus_v3_british_accent.wav","Morpheus_v3_british_accent.txt","Morpheus_v3_british_accent.reference.txt",
    "Morpheus _v2_us_accent.wav","Morpheus _v2_us_accent.txt","Morpheus _v2_us_accent.reference.txt",
]
for name in names:
    try:
        p = hf_hub_download(repo_id=repo, repo_type="dataset", filename=name, revision=rev)
        shutil.copy2(p, voices_dst / name)
        print(f"[ok] voice -> {voices_dst/name}")
    except Exception as e:
        print(f"[warn] voice {name} failed:", e)
PY

# --- start.sh: sursează hf.env în mod sigur și pornește ComfyUI ---
if [ ! -f "$COMFY/start.sh" ]; then
  cat > "$COMFY/start.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# activate venv but guard against unset vars while sourcing
set +u
source /workspace/ComfyUI/venv/bin/activate
# source hf.env safely
[ -f "/workspace/ComfyUI/venv/hf.env" ] && source /workspace/ComfyUI/venv/hf.env || true
set -u
exec python /workspace/ComfyUI/main.py --listen 0.0.0.0 --port 8188
SH
  chmod +x "$COMFY/start.sh"
else
  # always ensure start.sh has the safe hf.env sourcing
  grep -q 'source /workspace/ComfyUI/venv/hf.env' "$COMFY/start.sh" || \
  sed -i 's|source /workspace/ComfyUI/venv/bin/activate|set +u\
source /workspace/ComfyUI/venv/bin/activate\
[ -f "/workspace/ComfyUI/venv/hf.env" ] && source /workspace/ComfyUI/venv/hf.env || true\
set -u|' "$COMFY/start.sh"
fi

echo "[run] ComfyUI on 0.0.0.0:8188"
exec "$COMFY/start.sh"
