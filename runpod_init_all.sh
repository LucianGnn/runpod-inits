#!/usr/bin/env bash
# runpod_init_all.sh — ComfyUI + Manager + TTS-Audio-Suite + HF assets + Jupyter
# Idempotent: safe to run on every pod start.

set -euo pipefail
trap 'echo "[!] bootstrap failed at line $LINENO"; exit 1' ERR

# --------- CONFIG (env overrides allowed) ---------
WORKSPACE="${WORKSPACE:-/workspace}"
COMFY="$WORKSPACE/ComfyUI"
VENV="$COMFY/venv"
CUSTOM="$COMFY/custom_nodes"
MANAGER_DIR="$CUSTOM/ComfyUI-Manager"
TTS_DIR="$CUSTOM/tts_audio_suite"     # diodiogod/TTS-Audio-Suite

# HF dataset (private OK if HF_TOKEN set in env or saved token file)
ASSET_DATASET="${ASSET_DATASET:-LucianGn/IndexTTS2}"
HF_REV="${HF_REV:-main}"
WF_NAME="${WF_NAME:-IndexTTS2.json}"
VOICE_DIR_NAME="${VOICE_DIR_NAME:-indextts}"

WF_DST="$COMFY/user/default/workflows"
VOICES_DST="$TTS_DIR/voices_examples/$VOICE_DIR_NAME"
CACHE_DIR="$COMFY/models/.hf_cache"

# Re-download assets even if they exist (0/1)
FORCE_ASSETS="${FORCE_ASSETS:-0}"
# --------------------------------------------------

mkdir -p "$WORKSPACE" "$WF_DST" "$VOICES_DST" "$CACHE_DIR"

# Reuse HF token if previously saved
if [ -z "${HF_TOKEN:-}" ] && [ -f "$WORKSPACE/HF_TOKEN" ]; then
  export HF_TOKEN="$(cat "$WORKSPACE/HF_TOKEN")"
fi
[ -n "${HF_TOKEN:-}" ] && printf "%s" "$HF_TOKEN" > "$WORKSPACE/HF_TOKEN" || true

# Base OS deps (best effort)
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -y || true
  apt-get install -y git git-lfs python3-venv python3-dev build-essential \
                     ffmpeg curl ca-certificates libgl1 libglib2.0-0 \
                     aria2 >/dev/null || true
fi

# --- ComfyUI clone/update ---
if [ ! -d "$COMFY/.git" ]; then
  rm -rf "$COMFY" || true
  (cd "$WORKSPACE" && git clone https://github.com/comfyanonymous/ComfyUI)
else
  (cd "$COMFY" && git reset --hard && git pull --ff-only || true)
fi
[ -f "$COMFY/main.py" ] || { echo "[!] ComfyUI main.py missing"; exit 1; }

# --- Python venv + core deps ---
[ -d "$VENV" ] || python3 -m venv "$VENV"
# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -m pip install -U pip wheel setuptools --progress-bar off

# Torch (prefer CUDA 12.1 wheel; fall back to CPU if no GPU)
python - <<'PY' || \
( command -v nvidia-smi >/dev/null 2>&1 && python -m pip install --index-url https://download.pytorch.org/whl/cu121 torch torchvision torchaudio --progress-bar off ) || \
python -m pip install torch torchvision torchaudio --progress-bar off
import importlib,sys; sys.exit(0 if importlib.util.find_spec("torch") else 1)
PY

# ComfyUI requirements (best effort)
[ -f "$COMFY/requirements.txt" ] && python -m pip install -r "$COMFY/requirements.txt" --progress-bar off || true

# --- Custom nodes: Manager + TTS-Audio-Suite ---
if [ ! -d "$MANAGER_DIR/.git" ]; then
  git clone https://github.com/ltdrdata/ComfyUI-Manager "$MANAGER_DIR"
else
  (cd "$MANAGER_DIR" && git pull --ff-only || true)
fi
[ -f "$MANAGER_DIR/requirements.txt" ] && python -m pip install -r "$MANAGER_DIR/requirements.txt" --progress-bar off || true

if [ ! -d "$TTS_DIR/.git" ]; then
  git clone https://github.com/diodiogod/TTS-Audio-Suite "$TTS_DIR"
else
  (cd "$TTS_DIR" && git pull --ff-only || true)
fi
[ -f "$TTS_DIR/requirements.txt" ] && python -m pip install -r "$TTS_DIR/requirements.txt" --progress-bar off || true

# --- Extra deps required by TTS-Audio-Suite (IndexTTS path) ---
python - <<'PY'
import sys, subprocess
pkgs = [
  "librosa>=0.11.0",
  "soundfile>=0.12.1",
  "matplotlib>=3.7",
  "omegaconf>=2.3.0",
  "pynini==2.1.6; platform_system!='Windows'",
  "WeTextProcessing>=1.0.3; platform_system!='Windows'",
]
subprocess.check_call([sys.executable, "-m", "pip", "install", "-U", *pkgs, "--progress-bar", "off"])
PY

# --- Make TTS-Audio-Suite's 'utils' importable everywhere ---
HF_ENV="$VENV/hf.env"
cat > "$HF_ENV" <<EOF
export HF_TOKEN="${HF_TOKEN:-}"
export HF_ENDPOINT="https://huggingface.co"
export HF_HOME="$CACHE_DIR"
export HF_HUB_ENABLE_HF_TRANSFER=1
# Ensure 'from utils...' inside TTS-Audio-Suite resolves:
export PYTHONPATH="$TTS_DIR:$TTS_DIR/engines:\${PYTHONPATH:-}"
EOF
grep -q "hf.env" "$VENV/bin/activate" || echo 'test -f "${VIRTUAL_ENV}/hf.env" && . "${VIRTUAL_ENV}/hf.env"' >> "$VENV/bin/activate"
# load now too
# shellcheck disable=SC1091
. "$HF_ENV" || true

# --- Download HF ASSETS (workflow + voices) via curl (works for private if HF_TOKEN) ---
_auth_hdr=()
[ -n "${HF_TOKEN:-}" ] && _auth_hdr=(-H "Authorization: Bearer $HF_TOKEN")
base="https://huggingface.co/datasets/${ASSET_DATASET}/resolve/${HF_REV}"

dl() {
  local url="$1" dst="$2"
  if [ "$FORCE_ASSETS" != "1" ] && [ -f "$dst" ]; then
    echo "[skip] $dst"; return 0
  fi
  echo "[get]  $dst"
  curl -fsSL "${_auth_hdr[@]}" -o "$dst" "$url"
}

mkdir -p "$WF_DST" "$VOICES_DST"
dl "${base}/${WF_NAME}"                               "$WF_DST/${WF_NAME}"
dl "${base}/Morpheus.wav"                             "$VOICES_DST/Morpheus.wav"
dl "${base}/Morpheus.txt"                             "$VOICES_DST/Morpheus.txt"
dl "${base}/Morpheus.reference.txt"                   "$VOICES_DST/Morpheus.reference.txt"
dl "${base}/Morpheus_v3_british_accent.wav"           "$VOICES_DST/Morpheus_v3_british_accent.wav"
dl "${base}/Morpheus_v3_british_accent.txt"           "$VOICES_DST/Morpheus_v3_british_accent.txt"
dl "${base}/Morpheus_v3_british_accent.reference.txt" "$VOICES_DST/Morpheus_v3_british_accent.reference.txt"
# filename with space => URL-encoded %20
dl "${base}/Morpheus%20_v2_us_accent.wav"             "$VOICES_DST/Morpheus _v2_us_accent.wav"
dl "${base}/Morpheus%20_v2_us_accent.txt"             "$VOICES_DST/Morpheus _v2_us_accent.txt"
dl "${base}/Morpheus%20_v2_us_accent.reference.txt"   "$VOICES_DST/Morpheus _v2_us_accent.reference.txt"

echo "[ok] Assets:"
echo " - $WF_DST/${WF_NAME}"
echo " - $VOICES_DST/*"

# --- Start Jupyter on 8888 (no token) ---
if ! ss -ltn | awk '{print $4}' | grep -q ':8888$'; then
  nohup "$VENV/bin/python" -m jupyter lab \
      --ip=0.0.0.0 --port=8888 --no-browser \
      --ServerApp.token='' --ServerApp.password='' \
      > "$WORKSPACE/jupyter.log" 2>&1 &
  echo "[ok] Jupyter started on 0.0.0.0:8888 (log: $WORKSPACE/jupyter.log)"
else
  echo "[skip] Jupyter already on 8888"
fi

# --- Start ComfyUI on 8188 ---
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
