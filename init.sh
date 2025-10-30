#!/usr/bin/env bash
set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
COMFY_DIR="${COMFY_DIR:-$WORKSPACE/ComfyUI}"
HOST="${COMFY_HOST:-0.0.0.0}"
COMFY_PORT="${COMFY_PORT:-8188}"

SKIP_JUPYTER="${SKIP_JUPYTER:-0}"
JUPYTER_PORT="${JUPYTER_PORT:-8888}"
JUPYTER_TOKEN="${JUPYTER_TOKEN:-runpod}"

echo "[SYS] Installing base packages..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  git ca-certificates curl python3 python3-venv python3-dev build-essential procps

# --- ComfyUI clone/update ---
if [ ! -d "$COMFY_DIR/.git" ]; then
  echo "[GIT] Cloning ComfyUI -> $COMFY_DIR"
  git clone https://github.com/comfyanonymous/ComfyUI "$COMFY_DIR"
else
  echo "[GIT] Updating ComfyUI"
  git -C "$COMFY_DIR" fetch --all || true
  # aliniază la remote HEAD (nu presupune master)
  CU_HEAD="$(git -C "$COMFY_DIR" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/master)"
  CU_BRANCH="${CU_HEAD#origin/}"
  git -C "$COMFY_DIR" checkout -B "$CU_BRANCH" "origin/$CU_BRANCH" || true
  git -C "$COMFY_DIR" reset --hard "origin/$CU_BRANCH" || true
fi

# --- venv & deps ---
if [ ! -d "$COMFY_DIR/venv" ]; then
  echo "[PY] Creating venv"
  python3 -m venv "$COMFY_DIR/venv"
fi
# shellcheck source=/dev/null
source "$COMFY_DIR/venv/bin/activate"
python -m pip install --upgrade pip setuptools wheel
[ -f "$COMFY_DIR/requirements.txt" ] && pip install --no-cache-dir -r "$COMFY_DIR/requirements.txt"

# --- ComfyUI-Manager (robust main/master) ---
CUSTOM_NODES="$COMFY_DIR/custom_nodes"
MANAGER_DIR="$CUSTOM_NODES/ComfyUI-Manager"
mkdir -p "$CUSTOM_NODES"
if [ ! -d "$MANAGER_DIR/.git" ]; then
  echo "[GIT] Cloning ComfyUI-Manager"
  git clone https://github.com/ltdrdata/ComfyUI-Manager "$MANAGER_DIR"
else
  echo "[GIT] Updating ComfyUI-Manager"
  git -C "$MANAGER_DIR" fetch --all || true
fi
M_HEAD="$(git -C "$MANAGER_DIR" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)"
M_BRANCH="${M_HEAD#origin/}"
git -C "$MANAGER_DIR" checkout -B "$M_BRANCH" "origin/$M_BRANCH" || true
git -C "$MANAGER_DIR" reset --hard "origin/$M_BRANCH" || true
[ -f "$MANAGER_DIR/requirements.txt" ] && pip install --no-cache-dir -r "$MANAGER_DIR/requirements.txt" || true

# --- launch ComfyUI (background) ---
mkdir -p "$WORKSPACE"
cd "$COMFY_DIR"
( command -v fuser >/dev/null 2>&1 && fuser -k "${COMFY_PORT}/tcp" ) || true
echo "[RUN] Starting ComfyUI on ${HOST}:${COMFY_PORT}"
nohup python main.py --listen "$HOST" --port "$COMFY_PORT" > "$WORKSPACE/comfyui.log" 2>&1 &

# --- Jupyter optional (foreground) ---
if [ "$SKIP_JUPYTER" != "1" ]; then
  pip install --no-cache-dir jupyterlab
  echo "[RUN] JupyterLab on 0.0.0.0:${JUPYTER_PORT} (token: ${JUPYTER_TOKEN})"
  exec jupyter lab --ServerApp.ip=0.0.0.0 --ServerApp.port="$JUPYTER_PORT" \
       --ServerApp.allow_remote_access=True --ServerApp.token="$JUPYTER_TOKEN" --no-browser
else
  echo "[OK] ComfyUI running. Tail: tail -f $WORKSPACE/comfyui.log"
  exec bash -lc "while sleep 3600; do :; done"
fi
