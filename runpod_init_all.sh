#!/usr/bin/env bash
set -euo pipefail

# RunPod bootstrap — ComfyUI + TTS-Audio-Suite + HF assets (+ optional IndexTTS-2 models)
# ENV you can set in the template:
#   WORKSPACE                (default: /workspace)
#   HF_TOKEN                 (optional; required if HF dataset is private)
#   INSTALL_TTS_SUITE        (default: 1)   install/update TTS-Audio-Suite node
#   INSTALL_INDEXTTS2_MODELS (default: 0)   1 = fetch IndexTTS-2 models via HF (no .py)
#   ASSETS_REFRESH           (default: 0)   1 = re-download workflow+voices every boot
#   FORCE_REDO               (default: 0)   1 = redo heavy bootstrap (as if first boot)
#   ASSET_DATASET            (default: LucianGn/IndexTTS2)
#   HF_REV                   (default: main)
#   WF_NAME                  (default: IndexTTS2.json)

WORKSPACE="${WORKSPACE:-/workspace}"
COMFY="$WORKSPACE/ComfyUI"
CUSTOM="$COMFY/custom_nodes"
VENV="$COMFY/venv"
WF_DIR="$COMFY/user/default/workflows"
IN_DIR_VOICES="$CUSTOM/tts_audio_suite/voices_examples/indextts"

INSTALL_TTS_SUITE="${INSTALL_TTS_SUITE:-1}"
INSTALL_INDEXTTS2_MODELS="${INSTALL_INDEXTTS2_MODELS:-0}"
ASSETS_REFRESH="${ASSETS_REFRESH:-0}"
FORCE_REDO="${FORCE_REDO:-0}"

ASSET_DATASET="${ASSET_DATASET:-LucianGn/IndexTTS2}"
HF_REV="${HF_REV:-main}"
WF_NAME="${WF_NAME:-IndexTTS2.json}"

SENT_BOOTSTRAP="$WORKSPACE/.comfy_bootstrap_done"
SENT_ASSETS="$COMFY/.assets_ok"
SENT_TTS_SUITE="$CUSTOM/tts_audio_suite/.installed"

export DEBIAN_FRONTEND=noninteractive
export PIP_DISABLE_PIP_VERSION_CHECK=1

log() { echo -e ">>> $*"; }

mkdir -p "$WORKSPACE" "$WF_DIR" "$IN_DIR_VOICES"

# -------- HF token cache (persist între boot-uri) --------
if [ -z "${HF_TOKEN:-}" ] && [ -f "$WORKSPACE/HF_TOKEN" ]; then
  export HF_TOKEN="$(cat "$WORKSPACE/HF_TOKEN")"
fi
[ -n "${HF_TOKEN:-}" ] && printf "%s" "$HF_TOKEN" > "$WORKSPACE/HF_TOKEN" || true

# -------- First boot (sau FOCE_REDO) --------
if [ ! -f "$SENT_BOOTSTRAP" ] || [ "$FORCE_REDO" = "1" ]; then
  log "Bootstrap (first run or FORCE_REDO=1)"

  # OS deps
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y || true
    apt-get install -y git git-lfs python3-venv python3-dev build-essential \
       ffmpeg aria2 curl ca-certificates libgl1 libglib2.0-0 || true
  fi

  # ComfyUI (repo curat)
  if [ -d "$COMFY" ] && [ ! -d "$COMFY/.git" ]; then
    log "ComfyUI folder exists dar nu e repo git; curat..."
    rm -rf "$COMFY"
  fi
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

  # Torch cu CUDA dacă e disponibil
  python - <<'PY' || \
  ( command -v nvidia-smi >/dev/null 2>&1 && python -m pip install --index-url https://download.pytorch.org/whl/cu121 torch torchvision torchaudio --progress-bar off ) || \
  python -m pip install torch torchvision torchaudio --progress-bar off
import importlib,sys; sys.exit(0 if importlib.util.find_spec("torch") else 1)
PY

  # ComfyUI deps (best effort)
  [ -f "$COMFY/requirements.txt" ] && python -m pip install -r "$COMFY/requirements.txt" --progress-bar off || true

  # Pin HF libs + accelerate (evită conflict <1.0 vs transformers)
  pip install -U accelerate hf_transfer --progress-bar off
  pip install "huggingface_hub>=0.34.0,<1.0" --progress-bar off

  # Persist HF env în venv (cache HF separat de restul)
  HF_ENV="$VENV/hf.env"
  mkdir -p "$COMFY/models/.hf_cache"
  cat > "$HF_ENV" <<EOF
export HF_TOKEN="${HF_TOKEN:-}"
export HF_ENDPOINT="https://huggingface.co"
export HF_HOME="$COMFY/models/.hf_cache"
export HF_HUB_ENABLE_HF_TRANSFER=1
EOF
  grep -q "hf.env" "$VENV/bin/activate" || echo 'test -f "${VIRTUAL_ENV}/hf.env" && . "${VIRTUAL_ENV}/hf.env"' >> "$VENV/bin/activate"

  touch "$SENT_BOOTSTRAP"
else
  # numai activează venv & env HF
  # shellcheck disable=SC1091
  source "$VENV/bin/activate" 2>/dev/null || true
  test -f "$VENV/hf.env" && . "$VENV/hf.env" || true
  # update ComfyUI ușor
  if [ -d "$COMFY/.git" ]; then (cd "$COMFY" && git pull --ff-only || true); fi
fi

# -------- Node: TTS-Audio-Suite --------
if [ "$INSTALL_TTS_SUITE" = "1" ]; then
  if [ ! -d "$CUSTOM/tts_audio_suite/.git" ]; then
    log "Instalez TTS-Audio-Suite..."
    git clone https://github.com/diodiogod/TTS-Audio-Suite "$CUSTOM/tts_audio_suite"
    if [ -f "$CUSTOM/tts_audio_suite/requirements.txt" ]; then
      pip install -r "$CUSTOM/tts_audio_suite/requirements.txt" --progress-bar off || true
    fi
    touch "$SENT_TTS_SUITE"
  else
    log "Actualizez TTS-Audio-Suite..."
    (cd "$CUSTOM/tts_audio_suite" && git pull --ff-only || true)
    touch "$SENT_TTS_SUITE"
  fi
fi

# -------- (OPȚIONAL) IndexTTS-2 models fără script .py --------
# Implicit OPRIT (INSTALL_INDEXTTS2_MODELS=0). Activează dacă ai nevoie de node-ul IndexTTS-2 cu modele locale.
if [ "$INSTALL_INDEXTTS2_MODELS" = "1" ]; then
  MODEL_DIR="$COMFY/models/IndexTTS-2"
  mkdir -p "$MODEL_DIR"
  python - <<'PY' || true
import os, pathlib
from huggingface_hub import snapshot_download
dst="/workspace/ComfyUI/models/IndexTTS-2"
p=pathlib.Path(dst); p.mkdir(parents=True, exist_ok=True)
# Tragem fișierele de bază (cele care îți lipseau în logu-urile trecute)
need=["bpe.model","config.yaml","feat1.pt","feat2.pt","gpt.pth","s2mel.pth","wav2vec2bert_stats.pt","campplus_cn_common.bin"]
missing=[f for f in need if not (p/f).exists()]
if missing:
    snapshot_download(repo_id="IndexTeam/IndexTTS-2", allow_patterns=need,
                      local_dir=dst, local_dir_use_symlinks=False, resume_download=True)
    print("[ok] IndexTTS-2: bazele descărcate.")
else:
    print("[skip] IndexTTS-2: bazele sunt deja prezente.")
# Dacă dorești pachetele mari, extinde aici cu allow_patterns pentru subfolderele specifice.
PY
fi

# -------- HF Assets: workflow + voices (idempotent) --------
download_assets() {
  python - <<'PY'
import os, shutil, pathlib
from huggingface_hub import hf_hub_download

repo   = os.getenv("ASSET_DATASET","LucianGn/IndexTTS2")
rev    = os.getenv("HF_REV","main")
wfname = os.getenv("WF_NAME","IndexTTS2.json")

targets = []
# workflow
targets.append( (wfname, "/workspace/ComfyUI/user/default/workflows") )
# voci (numele anunțate de tine)
voice_dir="/workspace/ComfyUI/custom_nodes/tts_audio_suite/voices_examples/indextts"
voices = [
  "Morpheus _v2_us_accent.reference.txt",
  "Morpheus _v2_us_accent.txt",
  "Morpheus _v2_us_accent.wav",
  "Morpheus.reference.txt",
  "Morpheus.txt",
  "Morpheus.wav",
  "Morpheus_v3_british_accent.reference.txt",
  "Morpheus_v3_british_accent.txt",
  "Morpheus_v3_british_accent.wav",
]
for v in voices:
    targets.append( (v, voice_dir) )

for name, folder in targets:
    d = pathlib.Path(folder); d.mkdir(parents=True, exist_ok=True)
    dest = d / name
    if dest.exists() and os.getenv("ASSETS_REFRESH","0") != "1":
        print(f"[skip] {dest} already exists")
        continue
    try:
        p = hf_hub_download(repo_id=repo, repo_type="dataset", filename=name, revision=rev)
        shutil.copy2(p, dest)
        print(f"[ok] saved {dest}")
    except Exception as e:
        print(f"[warn] failed to fetch {name} from {repo}@{rev}: {e}")
PY
}

if [ "$ASSETS_REFRESH" = "1" ] || [ ! -f "$SENT_ASSETS" ]; then
  log "Descarc workflow + voices din HF..."
  download_assets
  touch "$SENT_ASSETS"
else
  log "Assets HF deja prezente (setează ASSETS_REFRESH=1 ca să refaci)."
fi

# -------- Launcher ComfyUI --------
if [ ! -f "$COMFY/start.sh" ]; then
  cat > "$COMFY/start.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source /workspace/ComfyUI/venv/bin/activate
exec python /workspace/ComfyUI/main.py --listen 0.0.0.0 --port 8188
SH
  chmod +x "$COMFY/start.sh"
fi

log "[run] ComfyUI on 0.0.0.0:8188"
exec "$COMFY/start.sh"
