#!/usr/bin/env bash
set -Eeuo pipefail

# RunPod bootstrap — ComfyUI + Manager + TTS-Audio-Suite + IndexTTS (models+assets)
# Montează volumul persistent la /workspace ca să nu re-descarci la fiecare boot.
#
# ENV (opțional):
#   HF_TOKEN              (salvat în $WORKSPACE/HF_TOKEN; necesar dacă HF dataset e privat)
#   WORKSPACE             (default: /workspace)
#   ASSET_DATASET         (default: LucianGn/IndexTTS2)
#   HF_REV                (default: main)
#   WF_NAME               (default: IndexTTS2.json)
#   VOICE_DIR_NAME        (default: indextts)  # subfolder în tts_audio_suite/voices_examples/
#   FORCE_TORCH_REINSTALL=1                    # forțează reinstalarea Torch dacă ai coruperi

export DEBIAN_FRONTEND=noninteractive
WORKSPACE="${WORKSPACE:-/workspace}"
COMFY="$WORKSPACE/ComfyUI"
CUSTOM="$COMFY/custom_nodes"
VENV="$COMFY/venv"
MODEL_ROOT="$COMFY/models"
MANAGER_DIR="$CUSTOM/ComfyUI-Manager"
TTS_SUITE_DIR="$CUSTOM/tts_audio_suite"
IDX_NODE_DIR="$CUSTOM/ComfyUI-Index-TTS"
WF_DST="$COMFY/user/default/workflows"
INPUT_DIR="$COMFY/input"
ASSET_DATASET="${ASSET_DATASET:-LucianGn/IndexTTS2}"
HF_REV="${HF_REV:-main}"
WF_NAME="${WF_NAME:-IndexTTS2.json}"
VOICE_DIR_NAME="${VOICE_DIR_NAME:-indextts}"
VOICES_DST="$TTS_SUITE_DIR/voices_examples/$VOICE_DIR_NAME"

mkdir -p "$WORKSPACE" "$WF_DST" "$INPUT_DIR" "$CUSTOM" "$MODEL_ROOT" "$VOICES_DST"

# HF token reuse
if [ -z "${HF_TOKEN:-}" ] && [ -f "$WORKSPACE/HF_TOKEN" ]; then
  export HF_TOKEN="$(cat "$WORKSPACE/HF_TOKEN")"
fi
[ -n "${HF_TOKEN:-}" ] && printf "%s" "$HF_TOKEN" > "$WORKSPACE/HF_TOKEN" || true

# OS deps
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -y || true
  apt-get install -y git git-lfs python3-venv python3-dev build-essential ffmpeg aria2 curl ca-certificates libgl1 libglib2.0-0 || true
fi

# Clone/repair ComfyUI (idempotent)
if [ ! -d "$COMFY/.git" ]; then
  rm -rf "$COMFY" || true
  (cd "$WORKSPACE" && git clone https://github.com/comfyanonymous/ComfyUI)
else
  (cd "$COMFY" && git reset --hard && git pull --ff-only || true)
fi
[ -f "$COMFY/main.py" ] || { rm -rf "$COMFY"; (cd "$WORKSPACE" && git clone https://github.com/comfyanonymous/ComfyUI); }

# Python venv
[ -d "$VENV" ] || python3 -m venv "$VENV"
# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -m pip install -U pip wheel setuptools --progress-bar off

# Torch (GPU dacă există)
if [ "${FORCE_TORCH_REINSTALL:-}" = "1" ]; then
  python -m pip uninstall -y torch torchvision torchaudio || true
fi
python - <<'PY' || \
( command -v nvidia-smi >/dev/null 2>&1 && python -m pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cu121 torch torchvision torchaudio --progress-bar off ) || \
python -m pip install --no-cache-dir torch torchvision torchaudio --progress-bar off
import importlib,sys; sys.exit(0 if importlib.util.find_spec("torch") else 1)
PY

# Comfy requirements (best effort)
[ -f "$COMFY/requirements.txt" ] && python -m pip install -r "$COMFY/requirements.txt" --progress-bar off || true

# --- Custom nodes ---

# 1) ComfyUI-Manager
if [ ! -d "$MANAGER_DIR/.git" ]; then
  git clone https://github.com/ltdrdata/ComfyUI-Manager "$MANAGER_DIR"
else
  (cd "$MANAGER_DIR" && git pull --ff-only || true)
fi
[ -f "$MANAGER_DIR/requirements.txt" ] && pip install -r "$MANAGER_DIR/requirements.txt" --progress-bar off || true

# 2) ComfyUI-Index-TTS (sursa completă 'indextts' pentru importuri)
if [ ! -d "$IDX_NODE_DIR/.git" ]; then
  git clone https://github.com/chenpipi0807/ComfyUI-Index-TTS "$IDX_NODE_DIR"
else
  (cd "$IDX_NODE_DIR" && git pull --ff-only || true)
fi
[ -f "$IDX_NODE_DIR/requirements.txt" ] && pip install -r "$IDX_NODE_DIR/requirements.txt" --progress-bar off || true

# 3) TTS-Audio-Suite (engine + auto-download)
if [ ! -d "$TTS_SUITE_DIR/.git" ]; then
  git clone https://github.com/diodiogod/TTS-Audio-Suite "$TTS_SUITE_DIR"
else
  (cd "$TTS_SUITE_DIR" && git pull --ff-only || true)
fi
[ -f "$TTS_SUITE_DIR/requirements.txt" ] && pip install -r "$TTS_SUITE_DIR/requirements.txt" --progress-bar off || true

# Dep extra pentru IndexTTS (evită erorile device_map/accelerate)
python -m pip install -U --progress-bar off accelerate modelscope huggingface_hub hf_transfer

# --- Rezolvă importul 'indextts.gpt.model_v2' pentru TTS-Audio-Suite ---
# 1) symlink către pachetul complet 'indextts' din ComfyUI-Index-TTS
VENDOR_IDX="$IDX_NODE_DIR/indextts2/vendor/indextts"
if [ -d "$VENDOR_IDX" ] && [ ! -e "$TTS_SUITE_DIR/indextts" ]; then
  ln -s "$VENDOR_IDX" "$TTS_SUITE_DIR/indextts"
fi

# 2) hf.env cu căi ABSOLUTE și fallback sigur pentru PYTHONPATH
HF_ENV="$VENV/hf.env"
mkdir -p "$(dirname "$HF_ENV")"
cat > "$HF_ENV" <<'EOF'
export HF_ENDPOINT="https://huggingface.co"
export HF_HUB_ENABLE_HF_TRANSFER=1
export DS_BUILD_OPS=0
# Dacă ai token, îl preluăm din fișierul salvat de bootstrap (vede și start.sh)
[ -z "${HF_TOKEN:-}" ] && [ -f "/workspace/HF_TOKEN" ] && export HF_TOKEN="$(cat /workspace/HF_TOKEN)"
# PYTHONPATH safe (nu crapă la set -u) + căi ABSOLUTE pentru importul indextts:
export PYTHONPATH="/workspace/ComfyUI/custom_nodes/tts_audio_suite:/workspace/ComfyUI/custom_nodes/tts_audio_suite/engines/index_tts:/workspace/ComfyUI/custom_nodes/ComfyUI-Index-TTS/indextts2/vendor:${PYTHONPATH:-}"
EOF

# --- Assets din HF: workflow + voci Morpheus ---
python - <<'PY' || true
import os, pathlib, shutil
from huggingface_hub import hf_hub_download

repo  = os.getenv("ASSET_DATASET","LucianGn/IndexTTS2")
rev   = os.getenv("HF_REV","main")
wf    = os.getenv("WF_NAME","IndexTTS2.json")
wf_dst= pathlib.Path("/workspace/ComfyUI/user/default/workflows"); wf_dst.mkdir(parents=True, exist_ok=True)
voices_dst = pathlib.Path("/workspace/ComfyUI/custom_nodes/tts_audio_suite/voices_examples/" + os.getenv("VOICE_DIR_NAME","indextts"))
voices_dst.mkdir(parents=True, exist_ok=True)

# Workflow (idempotent)
dest = wf_dst / wf
if not dest.exists():
    try:
        p = hf_hub_download(repo_id=repo, repo_type="dataset", filename=wf, revision=rev)
        shutil.copy2(p, dest)
        print(f"[ok] workflow -> {dest}")
    except Exception as e:
        print("[warn] workflow download failed:", e)
else:
    print(f"[skip] workflow exists -> {dest}")

# Vocile Morpheus (wav + .txt + .reference.txt)
names = [
    "Morpheus.wav","Morpheus.txt","Morpheus.reference.txt",
    "Morpheus_v3_british_accent.wav","Morpheus_v3_british_accent.txt","Morpheus_v3_british_accent.reference.txt",
    "Morpheus _v2_us_accent.wav","Morpheus _v2_us_accent.txt","Morpheus _v2_us_accent.reference.txt",
]
for name in names:
    d = voices_dst / name
    if d.exists():
        print(f"[skip] voice exists -> {d}")
        continue
    try:
        p = hf_hub_download(repo_id=repo, repo_type="dataset", filename=name, revision=rev)
        shutil.copy2(p, d)
        print(f"[ok] voice -> {d}")
    except Exception as e:
        print(f"[warn] voice {name} failed:", e)
PY

# Launcher + start (sursa hf.env în mod safe fără să crape la -u)
if [ ! -f "$COMFY/start.sh" ]; then
  cat > "$COMFY/start.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
source /workspace/ComfyUI/venv/bin/activate
# sursează hf.env în mod safe (evităm 'unbound variable' de la -u)
set +u
[ -f "/workspace/ComfyUI/venv/hf.env" ] && . "/workspace/ComfyUI/venv/hf.env"
set -u
exec python /workspace/ComfyUI/main.py --listen 0.0.0.0 --port 8188
SH
  chmod +x "$COMFY/start.sh"
fi

echo "[run] ComfyUI on 0.0.0.0:8188"
exec "$COMFY/start.sh"
