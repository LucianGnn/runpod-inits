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
JUPYTER_ROOT="${JUPYTER_ROOT:-$WORKSPACE}"

log() { echo "[$(date +'%H:%M:%S')] $*"; }

# ================== Sys deps ==================
log "Installing base packages..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  git ca-certificates curl python3 python3-venv python3-dev build-essential \
  procps net-tools lsof

mkdir -p "$WORKSPACE"

# ================== ComfyUI clone/update ==================
if [ ! -d "$COMFY_DIR/.git" ]; then
  log "Cloning ComfyUI -> $COMFY_DIR"
  git clone https://github.com/comfyanonymous/ComfyUI.git "$COMFY_DIR"
else
  log "Updating ComfyUI"
  git -C "$COMFY_DIR" fetch --all || true
  CU_HEAD="$(git -C "$COMFY_DIR" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/master)"
  CU_BRANCH="${CU_HEAD#origin/}"
  git -C "$COMFY_DIR" checkout -B "$CU_BRANCH" "origin/$CU_BRANCH" || true
  git -C "$COMFY_DIR" reset --hard "origin/$CU_BRANCH" || true
fi

# ================== Python venv & deps ==================
if [ ! -d "$COMFY_DIR/venv" ]; then
  log "Creating Python venv"
  python3 -m venv "$COMFY_DIR/venv"
fi
# shellcheck source=/dev/null
source "$COMFY_DIR/venv/bin/activate"
python -m pip install --upgrade pip setuptools wheel
[ -f "$COMFY_DIR/requirements.txt" ] && pip install --no-cache-dir -r "$COMFY_DIR/requirements.txt"

# ================== ComfyUI-Manager only ==================
CUSTOM_NODES="$COMFY_DIR/custom_nodes"
MANAGER_DIR="$CUSTOM_NODES/ComfyUI-Manager"
mkdir -p "$CUSTOM_NODES"

if [ ! -d "$MANAGER_DIR/.git" ]; then
  log "Cloning ComfyUI-Manager"
  git clone https://github.com/ltdrdata/ComfyUI-Manager "$MANAGER_DIR" || true
else
  log "Updating ComfyUI-Manager"
  git -C "$MANAGER_DIR" fetch --all || true
fi
if [ -d "$MANAGER_DIR/.git" ]; then
  M_HEAD="$(git -C "$MANAGER_DIR" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)"
  M_BRANCH="${M_HEAD#origin/}"
  git -C "$MANAGER_DIR" checkout -B "$M_BRANCH" "origin/$M_BRANCH" || true
  git -C "$MANAGER_DIR" reset --hard "origin/$M_BRANCH" || true
  [ -f "$MANAGER_DIR/requirements.txt" ] && pip install --no-cache-dir -r "$MANAGER_DIR/requirements.txt" || true
else
  log "WARNING: ComfyUI-Manager clone failed; continui fără Manager."
fi

# ================== Launch ComfyUI (background) ==================
cd "$COMFY_DIR"
( command -v fuser >/dev/null 2>&1 && fuser -k "${COMFY_PORT}/tcp" ) || true
log "Starting ComfyUI on ${HOST}:${COMFY_PORT}"
nohup python main.py --listen "$HOST" --port "$COMFY_PORT" > "$WORKSPACE/comfyui.log" 2>&1 &

# ================== JupyterLab (optional, foreground) ==================
if [ "$SKIP_JUPYTER" != "1" ]; then
  log "Installing JupyterLab"
  pip install --no-cache-dir jupyterlab

  log "Starting JupyterLab on 0.0.0.0:${JUPYTER_PORT} (token: ${JUPYTER_TOKEN})"
  exec jupyter lab \
    --ServerApp.ip=0.0.0.0 \
    --ServerApp.port="$JUPYTER_PORT" \
    --ServerApp.allow_remote_access=True \
    --ServerApp.token="$JUPYTER_TOKEN" \
    --ServerApp.root_dir="$JUPYTER_ROOT" \
    --ServerApp.allow_origin="*" \
    --ServerApp.disable_check_xsrf=True \
    --ServerApp.allow_root=True \
    --no-browser
else
  log "ComfyUI running. Tail logs with: tail -f $WORKSPACE/comfyui.log"
  # Ține containerul în viață când Jupyter e dezactivat
  exec bash -lc "while sleep 3600; do :; done"
fi
