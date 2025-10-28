#!/usr/bin/env bash
set -euo pipefail
trap 'echo "[!] bootstrap failed at line $LINENO"; exit 1' ERR

# RunPod bootstrap — ComfyUI + Manager + TTS-Audio-Suite + IndexTTS (models+assets)
# Env:
#   HF_TOKEN            (opțional; salvat în $WORKSPACE/HF_TOKEN; necesar dacă datasetul e privat)
#   WORKSPACE           (default: /workspace)
#   ASSET_DATASET       (default: LucianGn/IndexTTS2)
#   HF_REV              (default: main)
#   WF_NAME             (default: IndexTTS2.json)
#   VOICE_DIR_NAME      (default: indextts)
#   FORCE_BOOTSTRAP     (default: 0)  set 1 ca să refaci instalarea grea
# Rulează ComfyUI pe 0.0.0.0:8188

WORKSPACE="${WORKSPACE:-/workspace}"
COMFY="$WORKSPACE/ComfyUI"
CUSTOM="$COMFY/custom_nodes"
VENV="$COMFY/venv"
MODEL_ROOT="$COMFY/models"
CACHE_DIR="$MODEL_ROOT/.hf_cache"
BOOT_SENTINEL="$WORKSPACE/.bootstrap_done"

TTS_SUITE_DIR="$CUSTOM/tts_audio_suite"
IDX_NODE_DIR="$CUSTOM/ComfyUI-Index-TTS"
MANAGER_DIR="$CUSTOM/ComfyUI-Manager"

ASSET_DATASET="${ASSET_DATASET:-LucianGn/IndexTTS2}"
HF_REV="${HF_REV:-main}"
WF_NAME="${WF_NAME:-IndexTTS2.json}"
VOICE_DIR_NAME="${VOICE_DIR_NAME:-indextts}"
VOICES_DST="$TTS_SUITE_DIR/voices_examples/$VOICE_DIR_NAME"
WF_DST="$COMFY/user/default/workflows"
INPUT_DIR="$COMFY/input"

export DEBIAN_FRONTEND=noninteractive
mkdir -p "$WORKSPACE" "$WF_DST" "$VOICES_DST" "$INPUT_DIR" "$CACHE_DIR"

# HF token reuse
if [ -z "${HF_TOKEN:-}" ] && [ -f "$WORKSPACE/HF_TOKEN" ]; then
  export HF_TOKEN="$(cat "$WORKSPACE/HF_TOKEN")"
fi
[ -n "${HF_TOKEN:-}" ] && printf "%s" "$HF_TOKEN" > "$WORKSPACE/HF_TOKEN" || true

# --- Funcții utilitare ---
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

# OS deps
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -y || true
  apt-get install -y git git-lfs python3-venv python3-dev build-essential ffmpeg aria2 curl ca-certificates libgl1 libglib2.0-0 || true
fi

# --- Bootstrap greu (o singură dată) ---
if [ "${FORCE_BOOTSTRAP:-0}" = "1" ] || [ ! -f "$BOOT_SENTINEL" ]; then
  # ComfyUI
  ensure_repo "$COMFY" https://github.com/comfyanonymous/ComfyUI
  [ -f "$COMFY/main.py" ] || { echo "[!] ComfyUI main.py missing"; exit 1; }

  # Python venv
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

  # Comfy reqs (best effort)
  [ -f "$COMFY/requirements.txt" ] && python -m pip install -r "$COMFY/requirements.txt" --progress-bar off || true

  # Custom nodes
  ensure_repo "$MANAGER_DIR"  https://github.com/ltdrdata/ComfyUI-Manager
  [ -f "$MANAGER_DIR/requirements.txt" ] && pip_quiet -r "$MANAGER_DIR/requirements.txt" || true

  ensure_repo "$IDX_NODE_DIR" https://github.com/chenpipi0807/ComfyUI-Index-TTS
  [ -f "$IDX_NODE_DIR/requirements.txt" ] && pip_quiet -r "$IDX_NODE_DIR/requirements.txt" || true

  ensure_repo "$TTS_SUITE_DIR" https://github.com/diodiogod/TTS-Audio-Suite
  [ -f "$TTS_SUITE_DIR/requirements.txt" ] && pip_quiet -r "$TTS_SUITE_DIR/requirements.txt" || true

  # Dependențe suplimentare pentru IndexTTS & ModelScope/Transformers
  pip_quiet accelerate modelscope huggingface_hub hf_transfer

  # Symlink către pachetul complet 'indextts' (folosit de TTS-Audio-Suite)
  VENDOR_IDX="$IDX_NODE_DIR/indextts2/vendor/indextts"
  if [ -d "$VENDOR_IDX" ] && [ ! -e "$TTS_SUITE_DIR/indextts" ]; then
    ln -s "$VENDOR_IDX" "$TTS_SUITE_DIR/indextts"
  fi

  # Persist HF + PYTHONPATH robust
  HF_ENV="$VENV/hf.env"
  cat > "$HF_ENV" <<EOF
export HF_TOKEN="${HF_TOKEN:-}"
export HF_ENDPOINT="https://huggingface.co"
export HF_HOME="$CACHE_DIR"
export HF_HUB_ENABLE_HF_TRANSFER=1
export DS_BUILD_OPS=0
# Import IndexTTS for TTS-Audio-Suite (robust cu nounset)
export PYTHONPATH="$TTS_SUITE_DIR:$TTS_SUITE_DIR/engines/index_tts:$IDX_NODE_DIR/indextts2/vendor:\${PYTHONPATH:-}"
EOF
  grep -q "hf.env" "$VENV/bin/activate" || echo 'test -f "${VIRTUAL_ENV}/hf.env" && . "${VIRTUAL_ENV}/hf.env"' >> "$VENV/bin/activate"

  # Assets din HF: workflow + voci Morpheus
  python - <<'PY' || true
import os, pathlib, shutil
from huggingface_hub import hf_hub_download
repo  = os.getenv("ASSET_DATASET","LucianGn/IndexTTS2")
rev   = os.getenv("HF_REV","main")
wf    = os.getenv("WF_NAME","IndexTTS2.json")
wf_dst= pathlib.Path("/workspace/ComfyUI/user/default/workflows"); wf_dst.mkdir(parents=True, exist_ok=True)
voices_dst = pathlib.Path("/workspace/ComfyUI/custom_nodes/tts_audio_suite/voices_examples")/os.getenv("VOICE_DIR_NAME","indextts")
voices_dst.mkdir(parents=True, exist_ok=True)

# Workflow
try:
    p = hf_hub_download(repo_id=repo, repo_type="dataset", filename=wf, revision=rev)
    shutil.copy2(p, wf_dst / wf)
    print(f"[ok] workflow -> {wf_dst/wf}")
except Exception as e:
    print("[warn] workflow download failed:", e)

names = [
    "Morpheus.wav","Morpheus.txt","Morpheus.reference.txt",
    "Morpheus_v3_british_accent.wav","Morpheus_v3_british_accent.txt","Morpheus_v3_british_accent.reference.txt",
    "Morpheus _v2_us_accent.wav","Morpheus _v2_us_accent.txt","Morpheus _v2_us_accent.reference.txt",
]
for name in names:
    try:
        p = hf_hub_download(repo_id=repo, repo_type="dataset", filename=name, revision=rev)
        shutil.copy2(p, voices_dst / name)
        print(f"[ok] voice -> {voices_dst/name}")
    except Exception as e:
        print(f"[warn] voice {name} failed:", e)
PY

  date > "$BOOT_SENTINEL"
else
  # Bootstrap rapid (skip instalații grele)
  # shellcheck disable=SC1091
  source "$VENV/bin/activate"
fi

# Launcher + start (fără -u ca să nu stricăm env-urile altora)
if [ ! -f "$COMFY/start.sh" ]; then
  cat > "$COMFY/start.sh" <<'SH'
#!/usr/bin/env bash
set -e -o pipefail
source /workspace/ComfyUI/venv/bin/activate
# hf.env e deja sourced prin activate; PYTHONPATH e robust: ${PYTHONPATH:-}
exec python -u /workspace/ComfyUI/main.py --listen 0.0.0.0 --port 8188
SH
  chmod +x "$COMFY/start.sh"
fi
export PYTHONPATH="...:${PYTHONPATH:-}"

echo "[run] ComfyUI on 0.0.0.0:8188"
exec "$COMFY/start.sh"
