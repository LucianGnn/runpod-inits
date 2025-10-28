#!/usr/bin/env bash
set -euo pipefail

# RunPod bootstrap — ComfyUI + Manager + TTS-Audio-Suite + IndexTTS (models+assets)
# Env utile:
#   HF_TOKEN          (opțional; salvat în $WORKSPACE/HF_TOKEN; necesar dacă datasetul e privat)
#   WORKSPACE         (default: /workspace)
#   ASSET_DATASET     (default: LucianGn/IndexTTS2)  # HF dataset cu workflow + voci
#   HF_REV            (default: main)
#   WF_NAME           (default: IndexTTS2.json)
#   VOICE_DIR_NAME    (default: indextts)            # subfolder în tts_audio_suite/voices_examples/
#   FORCE_SETUP=1     (optional) forțează reinstalarea dependențelor (altfel fast-boot)
#
# Pornește ComfyUI pe 0.0.0.0:8188

WORKSPACE="${WORKSPACE:-/workspace}"
COMFY="$WORKSPACE/ComfyUI"
CUSTOM="$COMFY/custom_nodes"
USERDIR="$COMFY/user"
VENV="$COMFY/venv"
MODEL_ROOT="$COMFY/models"
TTS_SUITE_DIR="$CUSTOM/tts_audio_suite"
IDX_NODE_DIR="$CUSTOM/ComfyUI-Index-TTS"
PERSIST_DIR="$WORKSPACE/.persist"
SETUP_SENTINEL="$WORKSPACE/.setup_done"

ASSET_DATASET="${ASSET_DATASET:-LucianGn/IndexTTS2}"
HF_REV="${HF_REV:-main}"
WF_NAME="${WF_NAME:-IndexTTS2.json}"
VOICE_DIR_NAME="${VOICE_DIR_NAME:-indextts}"
VOICES_DST="$TTS_SUITE_DIR/voices_examples/$VOICE_DIR_NAME"
WF_DST="$COMFY/user/default/workflows"
INPUT_DIR="$COMFY/input"

export DEBIAN_FRONTEND=noninteractive

mkdir -p "$WORKSPACE" "$PERSIST_DIR" "$VOICES_DST" "$WF_DST" "$INPUT_DIR"

# --- HF token reuse ---
if [ -z "${HF_TOKEN:-}" ] && [ -f "$WORKSPACE/HF_TOKEN" ]; then
  export HF_TOKEN="$(cat "$WORKSPACE/HF_TOKEN")"
fi
[ -n "${HF_TOKEN:-}" ] && printf "%s" "$HF_TOKEN" > "$WORKSPACE/HF_TOKEN" || true

# --- OS deps (best effort) ---
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -y || true
  apt-get install -y git git-lfs python3-venv python3-dev build-essential \
                     ffmpeg aria2 curl ca-certificates libgl1 libglib2.0-0 rsync || true
fi
git lfs install --skip-repo || true

# --- Funcții helper ---
backup_if_reclone() {
  # salvează custom_nodes + user ca să nu se piardă la re-clone
  [ -d "$CUSTOM" ] && rsync -a "$CUSTOM/" "$PERSIST_DIR/custom_nodes/" || true
  [ -d "$USERDIR" ] && rsync -a "$USERDIR/" "$PERSIST_DIR/user/" || true
}
restore_after_reclone() {
  [ -d "$PERSIST_DIR/custom_nodes" ] && rsync -a "$PERSIST_DIR/custom_nodes/" "$CUSTOM/" || true
  [ -d "$PERSIST_DIR/user" ]        && rsync -a "$PERSIST_DIR/user/"        "$USERDIR/" || true
}

# --- Clone/repair ComfyUI (fără să pierzi nodurile/user) ---
if [ ! -d "$COMFY/.git" ]; then
  rm -rf "$COMFY" || true
  (cd "$WORKSPACE" && git clone https://github.com/comfyanonymous/ComfyUI)
else
  (cd "$COMFY" && git reset --hard && git pull --ff-only || true)
fi
# dacă lipsesc fișierele cheie -> re-clone + restore
if [ ! -f "$COMFY/main.py" ]; then
  backup_if_reclone
  rm -rf "$COMFY"
  (cd "$WORKSPACE" && git clone https://github.com/comfyanonymous/ComfyUI)
  restore_after_reclone
fi
git -C "$COMFY" config --global --add safe.directory "$COMFY" || true

# --- Python venv ---
[ -d "$VENV" ] || python3 -m venv "$VENV"
# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -m pip install -U pip wheel setuptools --progress-bar off

fast_boot=0
if [ -f "$SETUP_SENTINEL" ] && [ "${FORCE_SETUP:-0}" != "1" ]; then
  fast_boot=1
  echo "[fast-boot] Skip reinstall heavy deps (set FORCE_SETUP=1 pentru full setup)."
fi

if [ "$fast_boot" -eq 0 ]; then
  # --- Torch (GPU dacă există) ---
  python - <<'PY' || \
  ( command -v nvidia-smi >/dev/null 2>&1 && python -m pip install --index-url https://download.pytorch.org/whl/cu121 torch torchvision torchaudio --progress-bar off ) || \
  python -m pip install torch torchvision torchaudio --progress-bar off
import importlib,sys; sys.exit(0 if importlib.util.find_spec("torch") else 1)
PY

  # --- Comfy requirements (best effort, fără -U ca să nu refacă tot mereu) ---
  [ -f "$COMFY/requirements.txt" ] && python -m pip install -r "$COMFY/requirements.txt" --progress-bar off || true

  # --- Custom nodes ---

  # 1) ComfyUI-Manager
  MANAGER_DIR="$CUSTOM/ComfyUI-Manager"
  if [ ! -d "$MANAGER_DIR/.git" ]; then
    git clone https://github.com/ltdrdata/ComfyUI-Manager "$MANAGER_DIR"
  else
    (cd "$MANAGER_DIR" && git pull --ff-only || true)
  fi
  [ -f "$MANAGER_DIR/requirements.txt" ] && pip install -r "$MANAGER_DIR/requirements.txt" --progress-bar off || true

  # 2) ComfyUI-Index-TTS (sursa indextts completă)
  if [ ! -d "$IDX_NODE_DIR/.git" ]; then
    git clone https://github.com/chenpipi0807/ComfyUI-Index-TTS "$IDX_NODE_DIR"
  else
    (cd "$IDX_NODE_DIR" && git pull --ff-only || true)
  fi
  [ -f "$IDX_NODE_DIR/requirements.txt" ] && pip install -r "$IDX_NODE_DIR/requirements.txt" --progress-bar off || true

  # 3) TTS-Audio-Suite
  if [ ! -d "$TTS_SUITE_DIR/.git" ]; then
    git clone https://github.com/diodiogod/TTS-Audio-Suite "$TTS_SUITE_DIR"
  else
    (cd "$TTS_SUITE_DIR" && git pull --ff-only || true)
  fi
  [ -f "$TTS_SUITE_DIR/requirements.txt" ] && pip install -r "$TTS_SUITE_DIR/requirements.txt" --progress-bar off || true

  # Dependențe suplimentare care au tot dat erori în loguri
  python -m pip install \
    "transformers>=4.49.0" accelerate modelscope huggingface_hub hf_transfer \
    soundfile librosa pydub --progress-bar off || true

  # --- Rezolvă importul 'indextts.gpt.model_v2' pentru TTS-Audio-Suite ---
  VENDOR_IDX="$IDX_NODE_DIR/indextts2/vendor/indextts"
  if [ -d "$VENDOR_IDX" ] && [ ! -e "$TTS_SUITE_DIR/indextts" ]; then
    ln -s "$VENDOR_IDX" "$TTS_SUITE_DIR/indextts"
  fi

  # --- Login HF (Python, non-interactiv) + accel transfer ---
  python - <<'PY' || true
import os
from huggingface_hub import login
tok=os.getenv("HF_TOKEN")
print("HF login: token missing -> skip") if not tok else login(token=tok, add_to_git_credential=True)
PY

  # --- Persist HF + PYTHONPATH în venv ---
  mkdir -p "$VENV"
  HF_ENV="$VENV/hf.env"
  cat > "$HF_ENV" <<EOF
export HF_TOKEN="${HF_TOKEN:-}"
export HF_ENDPOINT="https://huggingface.co"
export HF_HOME="$MODEL_ROOT/.hf_cache"
export HF_HUB_ENABLE_HF_TRANSFER=1
export DS_BUILD_OPS=0
# Importuri IndexTTS pentru TTS-Audio-Suite
export PYTHONPATH="$TTS_SUITE_DIR:$TTS_SUITE_DIR/engines/index_tts:$IDX_NODE_DIR/indextts2/vendor:\$PYTHONPATH"
EOF
  grep -q "hf.env" "$VENV/bin/activate" || echo 'test -f "${VIRTUAL_ENV}/hf.env" && . "${VIRTUAL_ENV}/hf.env"' >> "$VENV/bin/activate"

  # --- Assets din HF: workflow + voci Morpheus (idempotent) ---
  python - <<'PY' || true
import os, pathlib, shutil
from huggingface_hub import hf_hub_download

repo  = os.getenv("ASSET_DATASET","LucianGn/IndexTTS2")
rev   = os.getenv("HF_REV","main")
wf    = os.getenv("WF_NAME","IndexTTS2.json")

wf_dst = pathlib.Path("/workspace/ComfyUI/user/default/workflows"); wf_dst.mkdir(parents=True, exist_ok=True)
voices_dst = pathlib.Path(os.getenv("VOICES_DST","/workspace/ComfyUI/custom_nodes/tts_audio_suite/voices_examples/indextts"))
voices_dst.mkdir(parents=True, exist_ok=True)

def fetch(name, dst_folder):
    dest = dst_folder / name
    if dest.exists():
        print(f"[skip] {dest} already exists")
        return
    p = hf_hub_download(repo_id=repo, repo_type="dataset", filename=name, revision=rev)
    shutil.copy2(p, dest)
    print(f"[ok] saved -> {dest}")

# Workflow
try:
    fetch(wf, wf_dst)
except Exception as e:
    print("[warn] workflow download failed:", e)

# Voci Morpheus (wav + .txt + .reference.txt)
names = [
    "Morpheus.wav","Morpheus.txt","Morpheus.reference.txt",
    "Morpheus_v3_british_accent.wav","Morpheus_v3_british_accent.txt","Morpheus_v3_british_accent.reference.txt",
    "Morpheus _v2_us_accent.wav","Morpheus _v2_us_accent.txt","Morpheus _v2_us_accent.reference.txt",
]
for n in names:
    try:
        fetch(n, voices_dst)
    except Exception as e:
        print(f"[warn] voice {n} failed:", e)
PY

  touch "$SETUP_SENTINEL"
fi

# --- Launcher + start ---
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
