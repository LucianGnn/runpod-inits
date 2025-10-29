#!/usr/bin/env bash
set -euo pipefail
trap 'echo "[!] failed at line $LINENO"; exit 1' ERR

# ======== Config ========
WORKSPACE="${WORKSPACE:-/workspace}"
COMFY="$WORKSPACE/ComfyUI"
VENV="$COMFY/venv"
CUSTOM="$COMFY/custom_nodes"
MANAGER_DIR="$CUSTOM/ComfyUI-Manager"
PORT="${PORT:-8188}"
FORCE_BOOTSTRAP="${FORCE_BOOTSTRAP:-0}"
BOOT_SENTINEL="$WORKSPACE/.comfy_boot_done"
export DEBIAN_FRONTEND=noninteractive

mkdir -p "$WORKSPACE"

# ======== Helpers ========
ensure_repo () {
  local path="$1" url="$2"
  if [ ! -d "$path/.git" ]; then
    rm -rf "$path" || true
    git clone "$url" "$path"
  else
    (cd "$path" && git reset --hard && git pull --ff-only || true)
  fi
}
pip_quiet () { python -m pip install -U "$@" --progress-bar off; }

# ======== OS deps (best effort) ========
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -y || true
  apt-get install -y git git-lfs python3-venv python3-dev build-essential \
                     ffmpeg curl ca-certificates libgl1 libglib2.0-0 || true
fi

# ======== Bootstrap (one-time heavy work) ========
if [ "$FORCE_BOOTSTRAP" = "1" ] || [ ! -f "$BOOT_SENTINEL" ]; then
  # ComfyUI
  ensure_repo "$COMFY" https://github.com/comfyanonymous/ComfyUI
  [ -f "$COMFY/main.py" ] || { echo "[!] ComfyUI main.py missing"; exit 1; }

  # Python venv
  [ -d "$VENV" ] || python3 -m venv "$VENV"
  # shellcheck disable=SC1091
  source "$VENV/bin/activate"
  pip_quiet pip wheel setuptools

  # Torch (prefer cu121 wheels). Falls back to CPU wheels if nu există GPU.
  python - <<'PY' || \
  ( command -v nvidia-smi >/dev/null 2>&1 && python -m pip install --index-url https://download.pytorch.org/whl/cu121 torch torchvision torchaudio --progress-bar off ) || \
  python -m pip install torch torchvision torchaudio --progress-bar off
import importlib,sys; sys.exit(0 if importlib.util.find_spec("torch") else 1)
PY

  # Comfy core requirements
  [ -f "$COMFY/requirements.txt" ] && python -m pip install -r "$COMFY/requirements.txt" --progress-bar off || true

  # ComfyUI-Manager (for managing nodes later, din UI)
  ensure_repo "$MANAGER_DIR" https://github.com/ltdrdata/ComfyUI-Manager
  [ -f "$MANAGER_DIR/requirements.txt" ] && pip_quiet -r "$MANAGER_DIR/requirements.txt" || true

  date > "$BOOT_SENTINEL"
else
  # shellcheck disable=SC1091
  source "$VENV/bin/activate"
fi

# ======== Launcher ========
if [ ! -f "$COMFY/start.sh" ]; then
  cat > "$COMFY/start.sh" <<SH
#!/usr/bin/env bash
set -euo pipefail
source "$VENV/bin/activate"
exec python "$COMFY/main.py" --listen 0.0.0.0 --port ${PORT}
SH
  chmod +x "$COMFY/start.sh"
fi

echo "[ok] ComfyUI + Manager ready. Starting on 0.0.0.0:${PORT}"
exec "$COMFY/start.sh"
