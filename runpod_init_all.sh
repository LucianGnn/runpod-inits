#!/usr/bin/env bash
set -euo pipefail

# RunPod bootstrap — ComfyUI + Manager + TTS-Audio-Suite + IndexTTS (models+assets), idempotent
# ENV (poți suprascrie în RunPod):
#   WORKSPACE=/workspace                # asigură-te că e pe volumul persistent
#   HF_TOKEN=...                        # dacă datasetul HF e privat
#   ASSET_DATASET=LucianGn/IndexTTS2
#   HF_REV=main
#   WF_NAME=IndexTTS2.json
#   VOICE_DIR_NAME=indextts             # sub tts_audio_suite/voices_examples/
#   SKIP_UPDATE=0                       # pune 1 ca să nu mai facă git pull la boot
#
# Pornește ComfyUI pe 0.0.0.0:8188

WORKSPACE="${WORKSPACE:-/workspace}"
COMFY="$WORKSPACE/ComfyUI"
CUSTOM="$COMFY/custom_nodes"
VENV="$COMFY/venv"
MODEL_ROOT="$COMFY/models"
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
SENTINEL="$WORKSPACE/.bootstrap_done"

export DEBIAN_FRONTEND=noninteractive
mkdir -p "$WORKSPACE" "$WF_DST" "$VOICES_DST" "$INPUT_DIR" "$CUSTOM"

# HF token reuse (persistă pe volum)
if [ -z "${HF_TOKEN:-}" ] && [ -f "$WORKSPACE/HF_TOKEN" ]; then
  export HF_TOKEN="$(cat "$WORKSPACE/HF_TOKEN")"
fi
[ -n "${HF_TOKEN:-}" ] && printf "%s" "$HF_TOKEN" > "$WORKSPACE/HF_TOKEN" || true

# ---------- FIRST BOOT: instalații grele ----------
if [ ! -f "$SENTINEL" ]; then
  echo "[init] First boot — installing base deps"

  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y || true
    apt-get install -y git git-lfs python3-venv python3-dev build-essential ffmpeg aria2 curl ca-certificates libgl1 libglib2.0-0 || true
  fi

  # Clone ComfyUI (fresh)
  rm -rf "$COMFY" || true
  (cd "$WORKSPACE" && git clone https://github.com/comfyanonymous/ComfyUI)

  # VENV
  python3 -m venv "$VENV"
  # shellcheck disable=SC1091
  source "$VENV/bin/activate"
  python -m pip install -U pip wheel setuptools --progress-bar off

  # Torch (GPU dacă există)
  python - <<'PY' || \
  ( command -v nvidia-smi >/dev/null 2>&1 && python -m pip install --index-url https://download.pytorch.org/whl/cu121 torch torchvision torchaudio --progress-bar off ) || \
  python -m pip install torch torchvision torchaudio --progress-bar off
import importlib,sys; sys.exit(0 if importlib.util.find_spec("torch") else 1)
PY

  # Comfy requirements (best effort)
  [ -f "$COMFY/requirements.txt" ] && python -m pip install -r "$COMFY/requirements.txt" --progress-bar off || true

  # Custom nodes (Manager, Index-TTS, TTS-Audio-Suite)
  git clone https://github.com/ltdrdata/ComfyUI-Manager "$MANAGER_DIR"
  [ -f "$MANAGER_DIR/requirements.txt" ] && pip install -r "$MANAGER_DIR/requirements.txt" --progress-bar off || true

  git clone https://github.com/chenpipi0807/ComfyUI-Index-TTS "$IDX_NODE_DIR"
  [ -f "$IDX_NODE_DIR/requirements.txt" ] && pip install -r "$IDX_NODE_DIR/requirements.txt" --progress-bar off || true

  git clone https://github.com/diodiogod/TTS-Audio-Suite "$TTS_SUITE_DIR"
  [ -f "$TTS_SUITE_DIR/requirements.txt" ] && pip install -r "$TTS_SUITE_DIR/requirements.txt" --progress-bar off || true

  # Dependențe suplimentare
  python -m pip install -U accelerate modelscope huggingface_hub hf_transfer --progress-bar off

  # Link pachetul complet indextts pentru importuri în TTS-Audio-Suite
  VENDOR_IDX="$IDX_NODE_DIR/indextts2/vendor/indextts"
  if [ -d "$VENDOR_IDX" ] && [ ! -e "$TTS_SUITE_DIR/indextts" ]; then
    ln -s "$VENDOR_IDX" "$TTS_SUITE_DIR/indextts"
  fi

  # HF login (opțional)
  python - <<'PY' || true
import os
from huggingface_hub import login
tok=os.getenv("HF_TOKEN")
print("HF login: token missing -> skip") if not tok else login(token=tok, add_to_git_credential=True)
PY

  # Env HF + PYTHONPATH SAFE
  HF_ENV="$VENV/hf.env"
  cat > "$HF_ENV" <<EOF
export HF_TOKEN="${HF_TOKEN:-}"
export HF_ENDPOINT="https://huggingface.co"
export HF_HOME="$MODEL_ROOT/.hf_cache"
export HF_HUB_ENABLE_HF_TRANSFER=1
export DS_BUILD_OPS=0
# PYTHONPATH safe: adaugă sufixul doar dacă există deja
export PYTHONPATH="$TTS_SUITE_DIR:$TTS_SUITE_DIR/engines/index_tts:$IDX_NODE_DIR/indextts2/vendor\${PYTHONPATH:+:\$PYTHONPATH}"
EOF
  grep -q "hf.env" "$VENV/bin/activate" || echo 'test -f "${VIRTUAL_ENV}/hf.env" && . "${VIRTUAL_ENV}/hf.env"' >> "$VENV/bin/activate"

  # Assets din HF (workflow + voci Morpheus)
  python - <<'PY' || true
import os, pathlib, shutil
from huggingface_hub import hf_hub_download
repo  = os.getenv("ASSET_DATASET","LucianGn/IndexTTS2")
rev   = os.getenv("HF_REV","main")
wf    = os.getenv("WF_NAME","IndexTTS2.json")
wf_dst= pathlib.Path("/workspace/ComfyUI/user/default/workflows"); wf_dst.mkdir(parents=True, exist_ok=True)
voices_dst = pathlib.Path(os.getenv("VOICES_DST","/workspace/ComfyUI/custom_nodes/tts_audio_suite/voices_examples/indextts"))
voices_dst.mkdir(parents=True, exist_ok=True)
# Workflow
try:
    p = hf_hub_download(repo_id=repo, repo_type="dataset", filename=wf, revision=rev)
    shutil.copy2(p, wf_dst / wf)
    print(f"[ok] workflow -> {wf_dst/wf}")
except Exception as e:
    print("[warn] workflow download failed:", e)
# Vocile (wav + txt + reference.txt)
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

  # start.sh cu protecție la -u
  if [ ! -f "$COMFY/start.sh" ]; then
    cat > "$COMFY/start.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# relaxăm -u doar cât încărcăm mediul (PYTHONPATH poate fi unset)
set +u
source /workspace/ComfyUI/venv/bin/activate
set -u
exec python /workspace/ComfyUI/main.py --listen 0.0.0.0 --port 8188
SH
    chmod +x "$COMFY/start.sh"
  fi

  touch "$SENTINEL"
  echo "[init] First boot complete."
fi

# ---------- SUBSEQUENT BOOTS: rapid ----------
# VENV
# shellcheck disable=SC1091
source "$VENV/bin/activate" 2>/dev/null || {
  echo "[repair] venv missing — recreating"
  python3 -m venv "$VENV"
  # shellcheck disable=SC1091
  source "$VENV/bin/activate"
  python -m pip install -U pip wheel setuptools --progress-bar off
}

# Actualizări ușoare (dacă nu ceri explicit să le sari)
if [ "${SKIP_UPDATE:-0}" != "1" ]; then
  if [ -d "$COMFY/.git" ]; then (cd "$COMFY" && git pull --ff-only || true); fi
  if [ -d "$MANAGER_DIR/.git" ]; then (cd "$MANAGER_DIR" && git pull --ff-only || true); fi
  if [ -d "$IDX_NODE_DIR/.git" ]; then (cd "$IDX_NODE_DIR" && git pull --ff-only || true); fi
  if [ -d "$TTS_SUITE_DIR/.git" ]; then (cd "$TTS_SUITE_DIR" && git pull --ff-only || true); fi
fi

# Repară ComfyUI dacă lipsește main.py (ex: update corupt)
[ -f "$COMFY/main.py" ] || {
  echo "[repair] ComfyUI main.py missing — recloning"
  rm -rf "$COMFY"
  (cd "$WORKSPACE" && git clone https://github.com/comfyanonymous/ComfyUI)
}

# Asigură-te că hf.env există și are PYTHONPATH safe (în caz de reinstalare venv)
HF_ENV="$VENV/hf.env"
if [ ! -f "$HF_ENV" ]; then
  cat > "$HF_ENV" <<EOF
export HF_TOKEN="${HF_TOKEN:-}"
export HF_ENDPOINT="https://huggingface.co"
export HF_HOME="$MODEL_ROOT/.hf_cache"
export HF_HUB_ENABLE_HF_TRANSFER=1
export DS_BUILD_OPS=0
export PYTHONPATH="$TTS_SUITE_DIR:$TTS_SUITE_DIR/engines/index_tts:$IDX_NODE_DIR/indextts2/vendor\${PYTHONPATH:+:\$PYTHONPATH}"
EOF
  grep -q "hf.env" "$VENV/bin/activate" || echo 'test -f "${VIRTUAL_ENV}/hf.env" && . "${VIRTUAL_ENV}/hf.env"' >> "$VENV/bin/activate"
fi

# Launcher + start
if [ ! -f "$COMFY/start.sh" ]; then
  cat > "$COMFY/start.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
set +u
source /workspace/ComfyUI/venv/bin/activate
set -u
exec python /workspace/ComfyUI/main.py --listen 0.0.0.0 --port 8188
SH
  chmod +x "$COMFY/start.sh"
fi

echo "[run] ComfyUI on 0.0.0.0:8188"
exec "$COMFY/start.sh"
