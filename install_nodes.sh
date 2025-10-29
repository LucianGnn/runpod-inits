#!/usr/bin/env bash
set -euo pipefail
trap 'echo "[!] bootstrap failed at line $LINENO"; exit 1' ERR

# RunPod bootstrap — ComfyUI + Manager + TTS-Audio-Suite (fără ComfyUI-Index-TTS)
# Rulează ComfyUI pe 0.0.0.0:8188
# Env utile: HF_TOKEN (opțional), WORKSPACE (default /workspace)

WORKSPACE="${WORKSPACE:-/workspace}"
COMFY="$WORKSPACE/ComfyUI"
CUSTOM="$COMFY/custom_nodes"
VENV="$COMFY/venv"
MODEL_ROOT="$COMFY/models"
CACHE_DIR="$MODEL_ROOT/.hf_cache"
BOOT_SENTINEL="$WORKSPACE/.bootstrap_done"

MANAGER_DIR="$CUSTOM/ComfyUI-Manager"
TTS_SUITE_DIR="$CUSTOM/tts_audio_suite"

export DEBIAN_FRONTEND=noninteractive
mkdir -p "$WORKSPACE" "$CUSTOM" "$CACHE_DIR" "$COMFY/user/default/workflows" "$COMFY/input"

# HF token reuse
if [ -z "${HF_TOKEN:-}" ] && [ -f "$WORKSPACE/HF_TOKEN" ]; then
  export HF_TOKEN="$(cat "$WORKSPACE/HF_TOKEN")"
fi
[ -n "${HF_TOKEN:-}" ] && printf "%s" "$HF_TOKEN" > "$WORKSPACE/HF_TOKEN" || true

ensure_repo () {
  local path="$1" url="$2"
  if [ ! -d "$path/.git" ]; then
    rm -rf "$path" || true
    git clone --depth 1 "$url" "$path"
  else
    (cd "$path" && git reset --hard && git pull --ff-only || true)
  fi
}

pip_i () { python -m pip install -U --progress-bar off "$@"; }

# OS deps
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -y || true
  apt-get install -y git git-lfs python3-venv python3-dev build-essential ffmpeg aria2 curl ca-certificates libgl1 libglib2.0-0 || true
fi

# Bootstrap (o singură dată) sau forțat
if [ "${FORCE_BOOTSTRAP:-0}" = "1" ] || [ ! -f "$BOOT_SENTINEL" ]; then
  # ComfyUI + venv
  ensure_repo "$COMFY" https://github.com/comfyanonymous/ComfyUI
  [ -f "$COMFY/main.py" ] || { echo "[!] ComfyUI main.py missing"; exit 1; }

  [ -d "$VENV" ] || python3 -m venv "$VENV"
  # shellcheck disable=SC1091
  source "$VENV/bin/activate"
  pip_i pip wheel setuptools

  # Torch (GPU dacă există)
  python - <<'PY' || \
  ( command -v nvidia-smi >/dev/null 2>&1 && python -m pip install --index-url https://download.pytorch.org/whl/cu121 torch torchvision torchaudio --progress-bar off ) || \
  python -m pip install torch torchvision torchaudio --progress-bar off
import importlib,sys; sys.exit(0 if importlib.util.find_spec("torch") else 1)
PY

  # Comfy requirements (best effort)
  [ -f "$COMFY/requirements.txt" ] && python -m pip install -r "$COMFY/requirements.txt" --progress-bar off || true

  # Custom nodes — Manager
  ensure_repo "$MANAGER_DIR" https://github.com/ltdrdata/ComfyUI-Manager
  [ -f "$MANAGER_DIR/requirements.txt" ] && pip_i -r "$MANAGER_DIR/requirements.txt" || true

  # Custom nodes — TTS-Audio-Suite (SINGURUL pentru IndexTTS integrat)
  ensure_repo "$TTS_SUITE_DIR" https://github.com/diodiogod/TTS-Audio-Suite
  [ -f "$TTS_SUITE_DIR/requirements.txt" ] && pip_i -r "$TTS_SUITE_DIR/requirements.txt" || true

  # IMPORTANT: NU instalăm / NU clonăm ComfyUI-Index-TTS
  # Și dacă există din sesiuni vechi, îl eliminăm ca să nu-l încarce Managerul:
  rm -rf "$CUSTOM/ComfyUI-Index-TTS" || true

  # Dependențe audio suplimentare cerute de loguri
  # - librosa, soundfile, numba (backend pentru librosa), soxr, scikit-learn (librosa dep)
  # - matplotlib (cerut de BigVGAN utils din TTS suite)
  pip_i numpy "librosa>=0.10.0" "soundfile>=0.12.0" numba soxr scikit-learn matplotlib

  # Evităm conflict transformers/huggingface_hub (păstrăm hub < 1.0)
  pip_i "huggingface_hub>=0.34.0,<1.0" accelerate modelscope safetensors omegaconf

  # PortAudio (doar dacă vrei input microfon prin sounddevice; altfel ignoră)
  # Linux dev headers (comentat — multe imagini nu-l au):
  # apt-get install -y portaudio19-dev || true
  pip_i sounddevice || true

  # Exporturi persistente: cache HF + PYTHONPATH (TTS-Audio-Suite primește prioritate pt. pachetul its 'utils')
  HF_ENV="$VENV/hf.env"
  cat > "$HF_ENV" <<EOF
export HF_TOKEN="${HF_TOKEN:-}"
export HF_ENDPOINT="https://huggingface.co"
export HF_HOME="$CACHE_DIR"
export HF_HUB_ENABLE_HF_TRANSFER=1
export DS_BUILD_OPS=0
# Prioritate pentru pachetul 'utils' din TTS-Audio-Suite (evită 'utils' non-pachet din alte locuri)
export PYTHONPATH="$TTS_SUITE_DIR:$TTS_SUITE_DIR/engines/index_tts:\${PYTHONPATH:-}"
EOF
  grep -q "hf.env" "$VENV/bin/activate" || echo 'test -f "${VIRTUAL_ENV}/hf.env" && . "${VIRTUAL_ENV}/hf.env"' >> "$VENV/bin/activate"

  date > "$BOOT_SENTINEL"
else
  # shellcheck disable=SC1091
  source "$VENV/bin/activate"
fi

# start.sh
if [ ! -f "$COMFY/start.sh" ]; then
  cat > "$COMFY/start.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source /workspace/ComfyUI/venv/bin/activate
# hf.env e sourced via activate; PYTHONPATH are TTS suite în față
exec python -u /workspace/ComfyUI/main.py --listen 0.0.0.0 --port 8188
SH
  chmod +x "$COMFY/start.sh"
fi

echo "[run] ComfyUI on 0.0.0.0:8188"
exec "$COMFY/start.sh"
