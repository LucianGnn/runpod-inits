#!/usr/bin/env bash
set -euo pipefail

# Compact RunPod bootstrap — ComfyUI + IndexTTS-2 (+ optional nodes, workflow+audio assets)
# Env:
#   HF_TOKEN              (optional; persisted at $WORKSPACE/HF_TOKEN; required for private HF downloads)
#   INSTALL_NODES_URL     (optional; raw URL to install_nodes.sh)
#   NODES_FILE            (optional; default $WORKSPACE/nodes.txt)
#   EXTRA_NODES           (optional; space-separated "user/repo user/repo ...")
#   TTS2_PROMPT_CHOICE    (optional; 1=HF official [default], 2=mirror)
#   WORKSPACE             (optional; default /workspace)
#   HF_REV                (optional; default main) revision for HF dataset
#   # Overrides for HF asset dataset and names (defaults match your repo):
#   ASSET_DATASET         (default: LucianGn/IndexTTS2)
#   WF_NAME               (default: IndexTTS2.json)
#   AUDIO1_NAME           (default: emoji ref.mp3)
#   AUDIO2_NAME           (default: morph.wav)
# Starts ComfyUI on 0.0.0.0:8188

WORKSPACE="${WORKSPACE:-/workspace}"
COMFY="$WORKSPACE/ComfyUI"
CUSTOM="$COMFY/custom_nodes"
VENV="$COMFY/venv"
MODEL_ROOT="$COMFY/models/IndexTTS-2"
NODE_TTS="$CUSTOM/ComfyUI-Index-TTS"
NODES_FILE="${NODES_FILE:-$WORKSPACE/nodes.txt}"
WF_DIR="$COMFY/user/default/workflows"
IN_DIR="$COMFY/input"
export DEBIAN_FRONTEND=noninteractive
export DS_BUILD_OPS=0

mkdir -p "$WORKSPACE" "$WF_DIR" "$IN_DIR"

# HF token reuse
if [ -z "${HF_TOKEN:-}" ] && [ -f "$WORKSPACE/HF_TOKEN" ]; then
  export HF_TOKEN="$(cat "$WORKSPACE/HF_TOKEN")"
fi
[ -n "${HF_TOKEN:-}" ] && printf "%s" "$HF_TOKEN" > "$WORKSPACE/HF_TOKEN" || true

# OS deps (best effort)
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -y || true
  apt-get install -y git python3-venv python3-dev build-essential ffmpeg aria2 curl ca-certificates libgl1 libglib2.0-0 || true
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
python - <<'PY' || ( command -v nvidia-smi >/dev/null 2>&1 && python -m pip install --index-url https://download.pytorch.org/whl/cu121 torch torchvision torchaudio --progress-bar off ) || python -m pip install torch torchvision torchaudio --progress-bar off
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
# necesar pentru device_map/tp_plan din Transformers/ModelScope
pip install -U accelerate --progress-bar off

# HF login (Python, non-interactive) + transfer accel
python -m pip install -U huggingface_hub hf_transfer --progress-bar off
python - <<'PY' || true
import os
from huggingface_hub import login
tok=os.getenv("HF_TOKEN")
print("HF login: token missing -> skip") if not tok else login(token=tok, add_to_git_credential=True)
PY

# Persist HF env
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

# Download IndexTTS-2 models (non-interactive)
if [ ! -f "$MODEL_ROOT/semantic_codec/model.safetensors" ]; then
  CHOICE="${TTS2_PROMPT_CHOICE:-1}"  # 1=HF official (default), 2=mirror
  if [ -f "$NODE_TTS/TTS2_download.py" ]; then
    ( export HF_HOME="$MODEL_ROOT/hf_cache" HF_HUB_ENABLE_HF_TRANSFER=1; printf "%s
" "$CHOICE" | python "$NODE_TTS/TTS2_download.py" ) || true
  else
    # fallback: fetch script from upstream
    mkdir -p "$COMFY/scripts"
    curl -fsSL https://raw.githubusercontent.com/chenpipi0807/ComfyUI-Index-TTS/main/TTS2_download.py -o "$COMFY/scripts/TTS2_download.py"
    ( cd "$COMFY/scripts" && export HF_HOME="$MODEL_ROOT/hf_cache" HF_HUB_ENABLE_HF_TRANSFER=1; printf "%s
" "$CHOICE" | python TTS2_download.py ) || true
  fi
fi

# Ensure base files (handles your FileNotFoundError case)
python - <<'PY' || true
import pathlib
from huggingface_hub import snapshot_download
dst="/workspace/ComfyUI/models/IndexTTS-2"
need=["bpe.model","config.yaml","feat1.pt","feat2.pt","gpt.pth","s2mel.pth","wav2vec2bert_stats.pt","campplus_cn_common.bin"]
p=pathlib.Path(dst); p.mkdir(parents=True, exist_ok=True)
missing=[f for f in need if not (p/f).exists()]
if missing:
    snapshot_download(repo_id="IndexTeam/IndexTTS-2", allow_patterns=need,
                      local_dir=dst, local_dir_use_symlinks=False, resume_download=True)
    print("Ensured IndexTTS-2 base files.")
else:
    print("IndexTTS-2 base files already present.")
PY

# Fallback: if some other script downloaded to /workspace/models/IndexTTS-2, link it
[ -d /workspace/models/IndexTTS-2 ] && [ ! -e "$MODEL_ROOT" ] && ln -s /workspace/models/IndexTTS-2 "$MODEL_ROOT" || true

# ======= CUSTOM: Download workflow + 2 audio files from your HF dataset =======
ASSET_DATASET="${ASSET_DATASET:-LucianGn/IndexTTS2}"
HF_REV="${HF_REV:-main}"
WF_NAME="${WF_NAME:-IndexTTS2.json}"
AUDIO1_NAME="${AUDIO1_NAME:-emoji ref.mp3}"
AUDIO2_NAME="${AUDIO2_NAME:-morph.wav}"

python - <<'PY' || true
import os, shutil, pathlib
from huggingface_hub import hf_hub_download
repo = os.getenv("ASSET_DATASET","LucianGn/IndexTTS2")
rev  = os.getenv("HF_REV","main")
items = [
  (os.getenv("WF_NAME","IndexTTS2.json"), "/workspace/ComfyUI/user/default/workflows"),
  (os.getenv("AUDIO1_NAME","emoji ref.mp3"), "/workspace/ComfyUI/input"),
  (os.getenv("AUDIO2_NAME","morph.wav"), "/workspace/ComfyUI/input"),
]
for name, folder in items:
    folder = pathlib.Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    dest = folder / name
    if dest.exists():
        print(f"[skip] {dest} already exists")
        continue
    try:
        p = hf_hub_download(repo_id=repo, repo_type="dataset", filename=name, revision=rev)
        shutil.copy2(p, dest)
        print(f"[ok] saved {dest}")
    except Exception as e:
        print(f"[warn] failed to fetch {name} from {repo}@{rev}: {e}")
PY
# ======= END CUSTOM ASSETS =======

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
