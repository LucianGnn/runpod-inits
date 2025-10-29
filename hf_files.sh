#!/usr/bin/env bash
set -euo pipefail
trap 'echo "[!] bootstrap failed at line $LINENO"; exit 1' ERR

# ========= Config =========
WORKSPACE="${WORKSPACE:-/workspace}"
COMFY="$WORKSPACE/ComfyUI"
VENV="$COMFY/venv"
CUSTOM="$COMFY/custom_nodes"
MANAGER_DIR="$CUSTOM/ComfyUI-Manager"

# Jupyter on 8888, ComfyUI on 8188
JUPYTER_PORT="${JUPYTER_PORT:-8888}"
COMFY_PORT="${COMFY_PORT:-8188}"

# HF (pentru assets) – datasetul tău privat/public
ASSET_DATASET="${ASSET_DATASET:-LucianGn/IndexTTS2}"
HF_REV="${HF_REV:-main}"
WF_NAME="${WF_NAME:-IndexTTS2.json}"
WF_DST="$COMFY/user/default/workflows"

VOICE_DIR_NAME="${VOICE_DIR_NAME:-indextts}"
VOICES_DST="$COMFY/custom_nodes/tts_audio_suite/voices_examples/$VOICE_DIR_NAME"

# Redownload assets chiar dacă există (0/1)
FORCE_ASSETS="${FORCE_ASSETS:-0}"

# Instalează dep-uri audio acum (0/1). Recomand 1, ca să nu ai erori când pui TTS-Audio-Suite din Manager.
INSTALL_AUDIO_DEPS="${INSTALL_AUDIO_DEPS:-1}"

# Rulează bootstrapul greu doar o dată (setați FORCE_BOOTSTRAP=1 când vrei reinit)
BOOT_SENTINEL="$WORKSPACE/.bootstrap_done"
# =========================

mkdir -p "$WORKSPACE" "$WF_DST" "$VOICES_DST"

# HF token reuse (pentru dataset privat)
if [ -z "${HF_TOKEN:-}" ] && [ -f "$WORKSPACE/HF_TOKEN" ]; then
  export HF_TOKEN="$(cat "$WORKSPACE/HF_TOKEN")"
fi
[ -n "${HF_TOKEN:-}" ] && printf "%s" "$HF_TOKEN" > "$WORKSPACE/HF_TOKEN" || true

# --- OS deps de bază ---
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -y || true
  apt-get install -y git git-lfs python3-venv python3-dev build-essential \
    ffmpeg aria2 curl ca-certificates libgl1 libglib2.0-0 > /dev/null || true
fi

pip_quiet () { python -m pip install -U "$@" --progress-bar off; }

# --- Bootstrap greu (o singură dată) ---
if [ "${FORCE_BOOTSTRAP:-0}" = "1" ] || [ ! -f "$BOOT_SENTINEL" ]; then
  # Clone ComfyUI curat
  if [ ! -d "$COMFY/.git" ]; then
    rm -rf "$COMFY" || true
    (cd "$WORKSPACE" && git clone https://github.com/comfyanonymous/ComfyUI)
  else
    (cd "$COMFY" && git reset --hard && git pull --ff-only || true)
  fi
  [ -f "$COMFY/main.py" ] || { echo "[!] ComfyUI main.py missing"; exit 1; }

  # Venv
  [ -d "$VENV" ] || python3 -m venv "$VENV"
  # shellcheck disable=SC1091
  source "$VENV/bin/activate"
  pip_quiet pip wheel setuptools

  # Torch (GPU dacă există)
  python - <<'PY' || \
  ( command -v nvidia-smi >/dev/null 2>&1 && python -m pip install --index-url https://download.pytorch.org/whl/cu121 torch torchvision torchaudio --progress-bar off ) || \
  python -m pip install torch torchvision torchaudio --progress-bar off
import importlib,sys; sys.exit(0 if importlib.util.find_spec("torch") else 1)
PY

  # Comfy requirements (best effort)
  [ -f "$COMFY/requirements.txt" ] && python -m pip install -r "$COMFY/requirements.txt" --progress-bar off || true

  # Manager
  if [ ! -d "$MANAGER_DIR/.git" ]; then
    git clone https://github.com/ltdrdata/ComfyUI-Manager "$MANAGER_DIR"
  else
    (cd "$MANAGER_DIR" && git reset --hard && git pull --ff-only || true)
  fi
  [ -f "$MANAGER_DIR/requirements.txt" ] && pip_quiet -r "$MANAGER_DIR/requirements.txt" || true

  # Dep-uri audio (ca să fii pregătit de TTS-Audio-Suite mai târziu)
  if [ "$INSTALL_AUDIO_DEPS" = "1" ]; then
    pip_quiet librosa soundfile matplotlib WeTextProcessing pynini omegaconf
  fi

  # Jupyter Lab (port 8888)
  pip_quiet jupyterlab

  # HF assets via curl (fără huggingface_hub)
  _auth_hdr=()
  [ -n "${HF_TOKEN:-}" ] && _auth_hdr=(-H "Authorization: Bearer $HF_TOKEN")
  base="https://huggingface.co/datasets/${ASSET_DATASET}/resolve/${HF_REV}"

  dl() { # $1=url, $2=dest
    local url="$1" dst="$2"
    if [ "$FORCE_ASSETS" != "1" ] && [ -f "$dst" ]; then
      echo "[skip] $dst (exists)"; return 0
    fi
    echo "[get]  $dst"
    curl -fsSL "${_auth_hdr[@]}" -o "$dst" "$url"
  }

  # workflow
  dl "${base}/${WF_NAME}" "$WF_DST/${WF_NAME}"

  # voices (atenție la numele cu spațiu)
  dl "${base}/Morpheus.wav"                              "$VOICES_DST/Morpheus.wav"
  dl "${base}/Morpheus.txt"                              "$VOICES_DST/Morpheus.txt"
  dl "${base}/Morpheus.reference.txt"                    "$VOICES_DST/Morpheus.reference.txt"
  dl "${base}/Morpheus_v3_british_accent.wav"            "$VOICES_DST/Morpheus_v3_british_accent.wav"
  dl "${base}/Morpheus_v3_british_accent.txt"            "$VOICES_DST/Morpheus_v3_british_accent.txt"
  dl "${base}/Morpheus_v3_british_accent.reference.txt"  "$VOICES_DST/Morpheus_v3_british_accent.reference.txt"
  dl "${base}/Morpheus%20_v2_us_accent.wav"              "$VOICES_DST/Morpheus _v2_us_accent.wav"
  dl "${base}/Morpheus%20_v2_us_accent.txt"              "$VOICES_DST/Morpheus _v2_us_accent.txt"
  dl "${base}/Morpheus%20_v2_us_accent.reference.txt"    "$VOICES_DST/Morpheus _v2_us_accent.reference.txt"

  # launcher: pornește Jupyter + ComfyUI
  cat > "$COMFY/start_all.sh" <<SH
#!/usr/bin/env bash
set -euo pipefail
source "$VENV/bin/activate"
jupyter lab --ip=0.0.0.0 --port=${JUPYTER_PORT} --no-browser > "$WORKSPACE/jupyter.log" 2>&1 &
exec python "$COMFY/main.py" --listen 0.0.0.0 --port ${COMFY_PORT}
SH
  chmod +x "$COMFY/start_all.sh"

  date > "$BOOT_SENTINEL"
else
  # bootstrap rapid: doar activează venv-ul
  # shellcheck disable=SC1091
  source "$VENV/bin/activate"
fi

echo "[run] ComfyUI: http://0.0.0.0:${COMFY_PORT}  |  Jupyter: http://0.0.0.0:${JUPYTER_PORT}"
exec "$COMFY/start_all.sh"
