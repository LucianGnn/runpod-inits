#!/usr/bin/env bash
set -euo pipefail

# Compact RunPod bootstrap — ComfyUI + IndexTTS-2 + optional nodes
# Reads env:
#   HF_TOKEN                (optional; will be persisted at $WORKSPACE/HF_TOKEN)
#   INSTALL_NODES_URL       (optional; raw URL to install_nodes.sh)
#   NODES_FILE              (optional; default $WORKSPACE/nodes.txt)
#   EXTRA_NODES             (optional; space-separated "user/repo user/repo ...")
#   WORKSPACE               (optional; default /workspace)
# Starts ComfyUI on 0.0.0.0:8188

WORKSPACE="${WORKSPACE:-/workspace}"
COMFY="$WORKSPACE/ComfyUI"
CUSTOM="$COMFY/custom_nodes"
VENV="$COMFY/venv"
MODEL_ROOT="$COMFY/models/IndexTTS-2"
NODE_TTS="$CUSTOM/ComfyUI-Index-TTS"
NODES_FILE="${NODES_FILE:-$WORKSPACE/nodes.txt}"
export DEBIAN_FRONTEND=noninteractive
export DS_BUILD_OPS=0

mkdir -p "$WORKSPACE"

# Save HF token for reuse
if [ -z "${HF_TOKEN:-}" ] && [ -f "$WORKSPACE/HF_TOKEN" ]; then
  export HF_TOKEN="$(cat "$WORKSPACE/HF_TOKEN")"
fi
[ -n "${HF_TOKEN:-}" ] && printf "%s" "$HF_TOKEN" > "$WORKSPACE/HF_TOKEN" || true

# OS deps (best effort)
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -y || true
  apt-get install -y git python3-venv python3-dev build-essential ffmpeg aria2 curl ca-certificates || true
fi

# Clone/Update ComfyUI
if [ ! -d "$COMFY" ]; then
  (cd "$WORKSPACE" && git clone https://github.com/comfyanonymous/ComfyUI)
else
  (cd "$COMFY" && git pull --ff-only || true)
fi

# Python venv
if [ ! -d "$VENV" ]; then
  python3 -m venv "$VENV"
fi
# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -m pip install -U pip wheel setuptools --progress-bar off

# Torch (GPU if available)
python - <<'PY' || \
( command -v nvidia-smi >/dev/null 2>&1 && python -m pip install --index-url https://download.pytorch.org/whl/cu121 torch torchvision torchaudio --progress-bar off ) || \
python -m pip install torch torchvision torchaudio --progress-bar off
import importlib,sys; sys.exit(0 if importlib.util.find_spec("torch") else 1)
PY

# Comfy requirements (best effort)
[ -f "$COMFY/requirements.txt" ] && python -m pip install -r "$COMFY/requirements.txt" --progress-bar off || true

# IndexTTS-2 node
if [ ! -d "$NODE_TTS/.git" ]; then
  git clone https://github.com/chenpipi0807/ComfyUI-Index-TTS "$NODE_TTS"
else
  (cd "$NODE_TTS" && git pull --ff-only || true)
fi
[ -f "$NODE_TTS/requirements.txt" ] && pip install -r "$NODE_TTS/requirements.txt" --progress-bar off || true

# HF login + persist env
python -m pip install -U huggingface_hub --progress-bar off
if [ -n "${HF_TOKEN:-}" ]; then
  huggingface-cli login --token "$HF_TOKEN" --add-to-git-credential -y || true
fi
mkdir -p "$MODEL_ROOT/hf_cache"
HF_ENV="$VENV/hf.env"
cat > "$HF_ENV" <<EOF
export HF_TOKEN="${HF_TOKEN:-}"
export HF_ENDPOINT="https://huggingface.co"
export HF_HOME="$MODEL_ROOT/hf_cache"
export HF_HUB_ENABLE_HF_TRANSFER=1
export DS_BUILD_OPS=0
EOF
grep -q "hf.env" "$VENV/bin/activate" || echo 'test -f "${VIRTUAL_ENV}/hf.env" && . "${VIRTUAL_ENV}/hf.env"' >> "$VENV/bin/activate"

# Download IndexTTS-2 models (if not present)
if [ ! -f "$MODEL_ROOT/semantic_codec/model.safetensors" ]; then
  mkdir -p "$COMFY/scripts"
  if [ ! -f "$COMFY/scripts/TTS2_download.py" ]; then
    curl -fsSL https://raw.githubusercontent.com/chenpipi0807/ComfyUI-Index-TTS/main/TTS2_download.py -o "$COMFY/scripts/TTS2_download.py"
  fi
  ( cd "$COMFY/scripts" && HF_HOME="$MODEL_ROOT/hf_cache" HF_HUB_ENABLE_HF_TRANSFER=1 printf "1\n" | python TTS2_download.py ) || true
fi

# Optional: install additional nodes via install_nodes.sh
FETCHED=""
if [ -f "$WORKSPACE/install_nodes.sh" ]; then
  cp -f "$WORKSPACE/install_nodes.sh" "$WORKSPACE/install_nodes.run.sh" && FETCHED="$WORKSPACE/install_nodes.run.sh"
elif [ -n "${INSTALL_NODES_URL:-}" ]; then
  curl -fsSL "$INSTALL_NODES_URL" -o "$WORKSPACE/install_nodes.run.sh" && FETCHED="$WORKSPACE/install_nodes.run.sh"
elif [ -f "/mnt/data/install_nodes.sh" ]; then
  cp -f /mnt/data/install_nodes.sh "$WORKSPACE/install_nodes.run.sh" && FETCHED="$WORKSPACE/install_nodes.run.sh"
fi
if [ -n "$FETCHED" ]; then
  chmod +x "$FETCHED"
  COMFY_DIR="$COMFY" NODES_FILE="$NODES_FILE" EXTRA_NODES="${EXTRA_NODES:-}" bash "$FETCHED" || true
fi

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
