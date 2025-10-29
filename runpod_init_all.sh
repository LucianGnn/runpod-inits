#!/usr/bin/env bash
set -euo pipefail
trap 'echo "[!] bootstrap failed at line $LINENO" >&2' ERR

# =========================
#   SETTINGS (override via env)
# =========================
WORKSPACE="${WORKSPACE:-/workspace}"
COMFY="$WORKSPACE/ComfyUI"
VENV="$COMFY/venv"
CUSTOM="$COMFY/custom_nodes"
MANAGER_DIR="$CUSTOM/ComfyUI-Manager"
TTS_SUITE_DIR="$CUSTOM/tts_audio_suite"          # denumire folder (stabil)
CACHE_DIR="$COMFY/models/.hf_cache"

# HF assets (workflow + voci)
ASSET_DATASET="${ASSET_DATASET:-LucianGn/IndexTTS2}"
HF_REV="${HF_REV:-main}"
WF_NAME="${WF_NAME:-IndexTTS2.json}"
WF_DST="$COMFY/user/default/workflows"

VOICE_DIR_NAME="${VOICE_DIR_NAME:-indextts}"
VOICES_DST="$TTS_SUITE_DIR/voices_examples/$VOICE_DIR_NAME"
FORCE_ASSETS="${FORCE_ASSETS:-0}"

# Jupyter
START_JUPYTER="${START_JUPYTER:-0}"              # setează 1 ca să pornești Jupyter pe 8888
JUPYTER_DIR="${JUPYTER_DIR:-$WORKSPACE/jupyter}"
JUPYTER_PORT="${JUPYTER_PORT:-8888}"

# =========================
#   PREP
# =========================
export DEBIAN_FRONTEND=noninteractive
mkdir -p "$WORKSPACE" "$CUSTOM" "$WF_DST" "$VOICES_DST" "$CACHE_DIR" "$JUPYTER_DIR"

# Refolosește HF_TOKEN dacă există salvat
if [ -z "${HF_TOKEN:-}" ] && [ -f "$WORKSPACE/HF_TOKEN" ]; then
  export HF_TOKEN="$(cat "$WORKSPACE/HF_TOKEN")"
fi
[ -n "${HF_TOKEN:-}" ] && printf "%s" "$HF_TOKEN" > "$WORKSPACE/HF_TOKEN" || true

# =========================
#   OS deps
# =========================
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -y || true
  apt-get install -y --no-install-recommends \
    git git-lfs python3-venv python3-dev build-essential \
    ffmpeg aria2 curl ca-certificates \
    libgl1 libglib2.0-0 libsndfile1 \
    portaudio19-dev \
    > /dev/null
fi

# =========================
#   Funcții
# =========================
ensure_repo () {
  local path="$1" url="$2"
  if [ ! -d "$path/.git" ]; then
    rm -rf "$path" || true
    git clone "$url" "$path"
  else
    (cd "$path" && git reset --hard && git pull --ff-only || true)
  fi
}

pipq () { python -m pip install -U --progress-bar off "$@"; }

# =========================
#   ComfyUI + VENV
# =========================
ensure_repo "$COMFY" https://github.com/comfyanonymous/ComfyUI
[ -f "$COMFY/main.py" ] || { echo "[!] ComfyUI main.py missing"; exit 1; }

[ -d "$VENV" ] || python3 -m venv "$VENV"
# shellcheck disable=SC1091
source "$VENV/bin/activate"
pipq pip wheel setuptools

# PyTorch (cu121 – stabil pt imagini CUDA 12.4)
pipq --extra-index-url https://download.pytorch.org/whl/cu121 torch torchvision torchaudio

# Dependențele ComfyUI (best effort)
[ -f "$COMFY/requirements.txt" ] && pipq -r "$COMFY/requirements.txt" || true

# =========================
#   Manager
# =========================
ensure_repo "$MANAGER_DIR" https://github.com/ltdrdata/ComfyUI-Manager
[ -f "$MANAGER_DIR/requirements.txt" ] && pipq -r "$MANAGER_DIR/requirements.txt" || true

# =========================
#   TTS-Audio-Suite (fără ComfyUI-Index-TTS!)
# =========================
# (1) Asigură că nu există nodul conflictual ComfyUI-Index-TTS
rm -rf "$CUSTOM/ComfyUI-Index-TTS" 2>/dev/null || true

# (2) Instalează TTS-Audio-Suite
if [ ! -d "$TTS_SUITE_DIR/.git" ]; then
  git clone https://github.com/diodiogod/TTS-Audio-Suite "$TTS_SUITE_DIR"
else
  (cd "$TTS_SUITE_DIR" && git reset --hard && git pull --ff-only || true)
fi

# (3) Dependențe minime necesare pentru suite + engines
# - huggingface_hub < 1.0 e OK cu Transformers 4.57.x (noi folosim 0.36.x din Comfy)
# - audio stack: librosa, soundfile (libsndfile e în sistem), soxr, numba, llvmlite, matplotlib
# - text utils: omegaconf, WeTextProcessing (+ pynini doar pe Linux)
pipq "huggingface_hub>=0.34,<1.0" \
     accelerate safetensors omegaconf \
     librosa soundfile soxr matplotlib \
     "WeTextProcessing>=1.0.3"

# Pynini (Linux only; e OK să pice pe alte OS-uri)
if [[ "$(uname -s)" == "Linux" ]]; then
  pipq pynini || true
fi

# =========================
#   PYTHONPATH robust (fără 'unbound variable')
# =========================
HF_ENV="$VENV/hf.env"
cat > "$HF_ENV" <<EOF
export HF_TOKEN="${HF_TOKEN:-}"
export HF_ENDPOINT="https://huggingface.co"
export HF_HOME="$CACHE_DIR"
export HF_HUB_ENABLE_HF_TRANSFER=1
export DS_BUILD_OPS=0
# TTS-Audio-Suite pathing pentru importuri: utils.*, engines.*, etc.
export PYTHONPATH="$TTS_SUITE_DIR:$TTS_SUITE_DIR/engines:$TTS_SUITE_DIR/utils:\${PYTHONPATH:-}"
EOF
grep -q 'hf.env' "$VENV/bin/activate" || echo 'test -f "${VIRTUAL_ENV}/hf.env" && . "${VIRTUAL_ENV}/hf.env"' >> "$VENV/bin/activate"

# =========================
#   HF Assets (workflow + voci)
# =========================
_auth_hdr=()
[ -n "${HF_TOKEN:-}" ] && _auth_hdr=(-H "Authorization: Bearer $HF_TOKEN")

dl() {
  local url="$1" dst="$2"
  if [ "$FORCE_ASSETS" != "1" ] && [ -f "$dst" ]; then
    echo "[skip] $dst"; return 0
  fi
  echo "[get] $dst"
  curl -fsSL "${_auth_hdr[@]}" -o "$dst" "$url"
}

base="https://huggingface.co/datasets/${ASSET_DATASET}/resolve/${HF_REV}"
mkdir -p "$WF_DST" "$VOICES_DST"

# Workflow
dl "${base}/${WF_NAME}" "$WF_DST/${WF_NAME}"

# Voices
dl "${base}/Morpheus.wav"                            "$VOICES_DST/Morpheus.wav"
dl "${base}/Morpheus.txt"                            "$VOICES_DST/Morpheus.txt"
dl "${base}/Morpheus.reference.txt"                  "$VOICES_DST/Morpheus.reference.txt"

dl "${base}/Morpheus_v3_british_accent.wav"          "$VOICES_DST/Morpheus_v3_british_accent.wav"
dl "${base}/Morpheus_v3_british_accent.txt"          "$VOICES_DST/Morpheus_v3_british_accent.txt"
dl "${base}/Morpheus_v3_british_accent.reference.txt" "$VOICES_DST/Morpheus_v3_british_accent.reference.txt"

dl "${base}/Morpheus%20_v2_us_accent.wav"            "$VOICES_DST/Morpheus _v2_us_accent.wav"
dl "${base}/Morpheus%20_v2_us_accent.txt"            "$VOICES_DST/Morpheus _v2_us_accent.txt"
dl "${base}/Morpheus%20_v2_us_accent.reference.txt"  "$VOICES_DST/Morpheus _v2_us_accent.reference.txt"

echo "[ok] HF assets -> $WF_DST/$WF_NAME, voices -> $VOICES_DST"

# =========================
#   Start scripts
# =========================
# Comfy start script (sourcing venv -> hf.env -> PYTHONPATH corect)
if [ ! -f "$COMFY/start.sh" ]; then
  cat > "$COMFY/start.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source /workspace/ComfyUI/venv/bin/activate
exec python -u /workspace/ComfyUI/main.py --listen 0.0.0.0 --port 8188
SH
  chmod +x "$COMFY/start.sh"
fi

# Jupyter (opțional)
if [ "$START_JUPYTER" = "1" ]; then
  pipq jupyterlab notebook ipykernel
  python -m ipykernel install --user --name comfyui-venv --display-name "ComfyUI venv" || true
  if [ ! -f "$WORKSPACE/start_jupyter.sh" ]; then
    cat > "$WORKSPACE/start_jupyter.sh" <<SH
#!/usr/bin/env bash
set -euo pipefail
source "$VENV/bin/activate"
jupyter lab --no-browser --ip=0.0.0.0 --port=${JUPYTER_PORT} --ServerApp.token='' --ServerApp.password='' --NotebookApp.allow_origin='*' --NotebookApp.allow_remote_access=True --NotebookApp.trust_xheaders=True --NotebookApp.disable_check_xsrf=True --notebook-dir="$JUPYTER_DIR"
SH
    chmod +x "$WORKSPACE/start_jupyter.sh"
  fi
fi

# Supervizor mic: pornește ComfyUI și, dacă e cazul, Jupyter
if [ ! -f "$WORKSPACE/start_all.sh" ]; then
  cat > "$WORKSPACE/start_all.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
/workspace/ComfyUI/start.sh &
COMFY_PID=$!
if [ "${START_JUPYTER:-0}" = "1" ]; then
  /workspace/start_jupyter.sh &
fi
wait $COMFY_PID
SH
  chmod +x "$WORKSPACE/start_all.sh"
fi

echo "[run] ComfyUI => http://0.0.0.0:8188"
if [ "$START_JUPYTER" = "1" ]; then
  echo "[run] Jupyter  => http://0.0.0.0:${JUPYTER_PORT}"
fi

# Rulează (Comfy în prim-plan; Jupyter în fundal dacă e activat)
exec "$WORKSPACE/start_all.sh"
