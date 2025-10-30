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

# ================== Sys deps ==================
echo "[SYS] Installing base packages..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  git ca-certificates curl python3 python3-venv python3-dev build-essential \
  procps net-tools lsof

# ================== ComfyUI clone/update ==================
if [ ! -d "$COMFY_DIR/.git" ]; then
  echo "[GIT] Cloning ComfyUI -> $COMFY_DIR"
  git clone https://github.com/comfyanonymous/ComfyUI.git "$COMFY_DIR"
else
  echo "[GIT] Updating ComfyUI"
  git -C "$COMFY_DIR" fetch --all
  git -C "$COMFY_DIR" reset --hard origin/master
fi

# ================== Python venv & deps ==================
if [ ! -d "$COMFY_DIR/venv" ]; then
  echo "[PY] Creating venv"
  python3 -m venv "$COMFY_DIR/venv"
fi
# shellcheck source=/dev/null
source "$COMFY_DIR/venv/bin/activate"
python -m pip install --upgrade pip setuptools wheel

if [ -f "$COMFY_DIR/requirements.txt" ]; then
  echo "[PIP] Installing ComfyUI requirements"
  pip install --no-cache-dir -r "$COMFY_DIR/requirements.txt"
fi

# ================== ComfyUI-Manager only ==================
CUSTOM_NODES="$COMFY_DIR/custom_nodes"
MANAGER_DIR="$CUSTOM_NODES/ComfyUI-Manager"
mkdir -p "$CUSTOM_NODES"

if [ ! -d "$MANAGER_DIR/.git" ]; then
  echo "[GIT] Cloning ComfyUI-Manager"
  git clone https://github.com/ltdrdata/ComfyUI-Manager "$MANAGER_DIR"
else
  echo "[GIT] Updating ComfyUI-Manager"
  git -C "$MANAGER_DIR" fetch --all
  git -C "$MANAGER_DIR" reset --hard origin/master
fi
if [ -f "$MANAGER_DIR/requirements.txt" ]; then
  echo "[PIP] Installing Manager requirements"
  pip install --no-cache-dir -r "$MANAGER_DIR/requirements.txt" || true
fi

# ================== Launch ComfyUI (background) ==================
mkdir -p "$WORKSPACE"
cd "$COMFY_DIR"

# free port if occupied
( command -v fuser >/dev/null 2>&1 && fuser -k "${COMFY_PORT}/tcp" ) || true

echo "[RUN] Starting ComfyUI on ${HOST}:${COMFY_PORT}"
nohup python main.py --listen "$HOST" --port "$COMFY_PORT" > "$WORKSPACE/comfyui.log" 2>&1 &

# ================== JupyterLab (optional) ==================
if [ "$SKIP_JUPYTER" != "1" ]; then
  echo "[PIP] Installing JupyterLab"
  pip install --no-cache-dir jupyterlab
  echo "[RUN] Starting JupyterLab on 0.0.0.0:${JUPYTER_PORT} (token: ${JUPYTER_TOKEN})"
  exec jupyter lab \
    --ServerApp.ip=0.0.0.0 \
    --ServerApp.port="$JUPYTER_PORT" \
    --ServerApp.allow_remote_access=True \
    --ServerApp.token="$JUPYTER_TOKEN" \
    --no-browser
else
  echo "[OK] ComfyUI running. Tail logs with: tail -f $WORKSPACE/comfyui.log"
  # keep the container alive if no Jupyter in foreground
  exec bash -lc "while sleep 3600; do :; done"
fi
