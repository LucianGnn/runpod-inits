#!/usr/bin/env bash
set -euo pipefail

# RunPod bootstrap — ComfyUI + TTS-Audio-Suite + (optional) IndexTTS-2
# Env (set in Template):
#   HF_TOKEN              (secret; necesar pt. dataset privat)
#   WORKSPACE=/workspace  (implicit)
#   ASSET_DATASET=LucianGn/IndexTTS2
#   ASSET_SUBDIR=IndexTTS2          # dacă fișierele sunt într-un subfolder
#   HF_REV=main
#   AUTO_UPDATE=true
#   BOOTSTRAP_RESET=0|1             # 1 = forțează rebuild
#   # (IndexTTS-2 rămâne opțional; nu mai folosim TTS2_download.py)

WORKSPACE="${WORKSPACE:-/workspace}"
COMFY="$WORKSPACE/ComfyUI"
CUSTOM="$COMFY/custom_nodes"
VENV="$COMFY/venv"
WF_DIR="$COMFY/user/default/workflows"
IN_DIR="$COMFY/input"
VOICE_DIR="$CUSTOM/tts_audio_suite/voices_examples/indextts"

ASSET_DATASET="${ASSET_DATASET:-LucianGn/IndexTTS2}"
ASSET_SUBDIR="${ASSET_SUBDIR:-IndexTTS2}"
HF_REV="${HF_REV:-main}"

export DEBIAN_FRONTEND=noninteractive
mkdir -p "$WORKSPACE" "$WF_DIR" "$IN_DIR" "$VOICE_DIR"

# optional: reset one-time sentinel
[ "${BOOTSTRAP_RESET:-0}" = "1" ] && rm -f "$WORKSPACE/.bootstrap_done"

# lightweight fast-path dacă e deja instalat
if [ -f "$WORKSPACE/.bootstrap_done" ] && [ -x "$COMFY/start.sh" ]; then
  echo "[SKIP] bootstrap heavy — folosesc instalarea existentă"
  exec "$COMFY/start.sh"
fi

# --- HF token persist ---
if [ -z "${HF_TOKEN:-}" ] && [ -f "$WORKSPACE/HF_TOKEN" ]; then
  export HF_TOKEN="$(cat "$WORKSPACE/HF_TOKEN")"
fi
[ -n "${HF_TOKEN:-}" ] && printf "%s" "$HF_TOKEN" > "$WORKSPACE/HF_TOKEN" || true

# --- OS deps ---
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -y || true
  apt-get install -y git git-lfs python3-venv python3-dev build-essential \
                     ffmpeg aria2 curl ca-certificates libgl1 libglib2.0-0 || true
fi

# --- ComfyUI (robust) ---
# FIX: dacă folderul există dar nu e repo git, îl resetăm ca să nu pice `git clone`
if [ -d "$COMFY" ] && [ ! -d "$COMFY/.git" ]; then
  echo "[WARN] $COMFY există dar NU este repo git. Curăț..."
  rm -rf "$COMFY"
fi
if [ ! -d "$COMFY/.git" ]; then
  git clone --depth=1 https://github.com/comfyanonymous/ComfyUI "$COMFY"
else
  (cd "$COMFY" && git pull --ff-only || true)
fi

# --- Python venv ---
if [ ! -d "$VENV" ]; then
  python3 -m venv "$VENV"
fi
# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -m pip install -U pip wheel setuptools --progress-bar off

# Torch (GPU dacă e nvidia-smi)
python - <<'PY' || \
( command -v nvidia-smi >/dev/null 2>&1 && python -m pip install --index-url https://download.pytorch.org/whl/cu121 torch torchvision torchaudio --progress-bar off ) || \
python -m pip install torch torchvision torchaudio --progress-bar off
import importlib,sys; sys.exit(0 if importlib.util.find_spec("torch") else 1)
PY

# Dependențe Comfy (best-effort)
[ -f "$COMFY/requirements.txt" ] && pip install -r "$COMFY/requirements.txt" --progress-bar off || true

# --- TTS-Audio-Suite node ---
if [ ! -d "$CUSTOM/tts_audio_suite/.git" ]; then
  git clone https://github.com/diodiogod/TTS-Audio-Suite "$CUSTOM/tts_audio_suite"
else
  (cd "$CUSTOM/tts_audio_suite" && git pull --ff-only || true)
fi
if [ -f "$CUSTOM/tts_audio_suite/requirements.txt" ]; then
  pip install -r "$CUSTOM/tts_audio_suite/requirements.txt" --progress-bar off || true
else
  pip install soundfile pydub librosa ffmpeg-python numpy --progress-bar off || true
fi

# --- (opțional) ComfyUI-Index-TTS node + accelerate (pentru emo/Qwen, etc.) ---
if [ ! -d "$CUSTOM/ComfyUI-Index-TTS/.git" ]; then
  git clone https://github.com/chenpipi0807/ComfyUI-Index-TTS "$CUSTOM/ComfyUI-Index-TTS"
else
  (cd "$CUSTOM/ComfyUI-Index-TTS" && git pull --ff-only || true)
fi
[ -f "$CUSTOM/ComfyUI-Index-TTS/requirements.txt" ] && pip install -r "$CUSTOM/ComfyUI-Index-TTS/requirements.txt" --progress-bar off || true
pip install -U accelerate huggingface_hub hf_transfer --progress-bar off

# HF login non-interactiv (OK pentru privat)
python - <<'PY' || true
import os
from huggingface_hub import login
tok=os.getenv("HF_TOKEN")
print("HF login: token missing -> skip") if not tok else login(token=tok, add_to_git_credential=True)
PY

# --- Assets din HF dataset privat (workflow + voice pack în TTS-Audio-Suite) ---
python - <<'PY'
import os, shutil, pathlib
from huggingface_hub import hf_hub_download

repo  = os.getenv("ASSET_DATASET", "LucianGn/IndexTTS2")
rev   = os.getenv("HF_REV", "main")
sub   = os.getenv("ASSET_SUBDIR", "IndexTTS2").strip("/")
comfy = "/workspace/ComfyUI"
voice_dir = f"{comfy}/custom_nodes/tts_audio_suite/voices_examples/indextts"
wf_dir    = f"{comfy}/user/default/workflows"

pathlib.Path(voice_dir).mkdir(parents=True, exist_ok=True)
pathlib.Path(wf_dir).mkdir(parents=True, exist_ok=True)

# Numele EXACTE (cu spații) anunțate
files = [
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
pairs = [(f, voice_dir) for f in files]
pairs.append(("IndexTTS2.json", wf_dir))

def fetch_one(name, dst_folder):
    dst_folder = pathlib.Path(dst_folder)
    dst_folder.mkdir(parents=True, exist_ok=True)
    dest = dst_folder / name
    if dest.exists():
        print(f"[skip] {dest} deja există")
        return
    candidates = []
    if sub:
        candidates.append(f"{sub}/{name}")
    candidates.append(name)
    last_err=None
    for cand in candidates:
        try:
            p = hf_hub_download(repo_id=repo, repo_type="dataset",
                                filename=cand, revision=rev)
            shutil.copy2(p, dest)
            print(f"[ok] {name} -> {dest}")
            return
        except Exception as e:
            last_err=e
    print(f"[warn] nu am putut descărca {name}: {last_err}")

for name, folder in pairs:
    fetch_one(name, folder)
PY

# --- Launcher ---
if [ ! -f "$COMFY/start.sh" ]; then
  cat > "$COMFY/start.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source /workspace/ComfyUI/venv/bin/activate
exec python /workspace/ComfyUI/main.py --listen 0.0.0.0 --port 8188
SH
  chmod +x "$COMFY/start.sh"
fi

# Sanity check (previne „main.py missing”)
test -f "$COMFY/main.py" || { echo "FATAL: /workspace/ComfyUI/main.py lipsește (clone eșuat)."; exit 1; }

# Marchează că bootstrap-ul complet a fost rulat cu succes
touch "$WORKSPACE/.bootstrap_done"

echo "[run] ComfyUI on 0.0.0.0:8188"
exec "$COMFY/start.sh"
