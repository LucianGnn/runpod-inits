#!/usr/bin/env bash
set -euo pipefail

# ========= Config =========
WORKSPACE="${WORKSPACE:-/workspace}"
COMFY_DIR="${COMFY_DIR:-$WORKSPACE/ComfyUI}"
PORT="${COMFY_PORT:-8188}"
HOST="${COMFY_HOST:-0.0.0.0}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

# ========= APT deps (minimal) =========
if ! command -v git >/dev/null 2>&1 || ! command -v $PYTHON_BIN >/dev/null 2>&1; then
  echo "[APT] Installing base packages..."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git ca-certificates $PYTHON_BIN python3-venv python3-dev build-essential
fi

# ========= Clone ComfyUI =========
if [ ! -d "$COMFY_DIR/.git" ]; then
  echo "[GIT] Cloning ComfyUI into $COMFY_DIR ..."
  git clone https://github.com/comfyanonymous/ComfyUI.git "$COMFY_DIR"
else
  echo "[GIT] ComfyUI exists — pulling latest..."
  git -C "$COMFY_DIR" fetch --all
  git -C "$COMFY_DIR" reset --hard origin/master
fi

# ========= Python venv + deps =========
if [ ! -d "$COMFY_DIR/venv" ]; then
  echo "[PY] Creating venv..."
  $PYTHON_BIN -m venv "$COMFY_DIR/venv"
fi

# shellcheck source=/dev/null
source "$COMFY_DIR/venv/bin/activate"
python -m pip install --upgrade pip setuptools wheel

# ComfyUI's own requirements
if [ -f "$COMFY_DIR/requirements.txt" ]; then
  echo "[PIP] Installing ComfyUI requirements..."
  pip install --no-cache-dir -r "$COMFY_DIR/requirements.txt"
fi

# ========= Install ComfyUI-Manager only =========
CUSTOM_NODES="$COMFY_DIR/custom_nodes"
MANAGER_DIR="$CUSTOM_NODES/ComfyUI-Manager"
mkdir -p "$CUSTOM_NODES"

if [ ! -d "$MANAGER_DIR/.git" ]; then
  echo "[GIT] Cloning ComfyUI-Manager..."
  git clone https://github.com/ltdrdata/ComfyUI-Manager "$MANAGER_DIR"
else
  echo "[GIT] Updating ComfyUI-Manager..."
  git -C "$MANAGER_DIR" fetch --all
  git -C "$MANAGER_DIR" reset --hard origin/master
fi

# Manager extras (if any)
if [ -f "$MANAGER_DIR/requirements.txt" ]; then
  echo "[PIP] Installing Manager requirements..."
  pip install --no-cache-dir -r "$MANAGER_DIR/requirements.txt" || true
fi

# ========= Launch (background) =========
echo "[RUN] Starting ComfyUI on ${HOST}:${PORT} ..."
cd "$COMFY_DIR"
# kill previous ComfyUI bound to PORT (safe no-op if none)
if command -v fuser >/dev/null 2>&1; then fuser -k "${PORT}/tcp" || true; fi
nohup python main.py --listen "$HOST" --port "$PORT" > "$WORKSPACE/comfyui.log" 2>&1 &

sleep 1
echo "[OK] ComfyUI running. UI: http://${HOST}:${PORT} (if remote, use your server IP)"
echo "[LOG] Tail logs: tail -f $WORKSPACE/comfyui.log"
