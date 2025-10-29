# ==== HF assets only: workflow + voci Morpheus pentru TTS-Audio-Suite ====
set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
COMFY="$WORKSPACE/ComfyUI"

ASSET_DATASET="${ASSET_DATASET:-LucianGn/IndexTTS2}"
HF_REV="${HF_REV:-main}"

WF_NAME="${WF_NAME:-IndexTTS2.json}"
WF_DST="$COMFY/user/default/workflows"

VOICE_DIR_NAME="${VOICE_DIR_NAME:-indextts}"
VOICES_DST="$COMFY/custom_nodes/tts_audio_suite/voices_examples/$VOICE_DIR_NAME"

# Redownload dacă vrei să suprascrii (altfel skip dacă există)
FORCE_ASSETS="${FORCE_ASSETS:-0}"

mkdir -p "$WF_DST" "$VOICES_DST"

_auth_hdr=()
[ -n "${HF_TOKEN:-}" ] && _auth_hdr=(-H "Authorization: Bearer $HF_TOKEN")

dl() {
  # $1 = URL (HF resolve), $2 = dest file
  local url="$1" dst="$2"
  if [ "$FORCE_ASSETS" != "1" ] && [ -f "$dst" ]; then
    echo "[skip] $dst (exists)"; return 0
  fi
  echo "[get]  $dst"
  curl -fsSL "${_auth_hdr[@]}" -o "$dst" "$url"
}

base="https://huggingface.co/datasets/${ASSET_DATASET}/resolve/${HF_REV}"

# 1) Workflow
dl "${base}/${WF_NAME}" "$WF_DST/${WF_NAME}"

# 2) Voices (atenție: un nume are spațiu -> %20)
dl "${base}/Morpheus.wav"                            "$VOICES_DST/Morpheus.wav"
dl "${base}/Morpheus.txt"                            "$VOICES_DST/Morpheus.txt"
dl "${base}/Morpheus.reference.txt"                  "$VOICES_DST/Morpheus.reference.txt"

dl "${base}/Morpheus_v3_british_accent.wav"         "$VOICES_DST/Morpheus_v3_british_accent.wav"
dl "${base}/Morpheus_v3_british_accent.txt"         "$VOICES_DST/Morpheus_v3_british_accent.txt"
dl "${base}/Morpheus_v3_british_accent.reference.txt" "$VOICES_DST/Morpheus_v3_british_accent.reference.txt"

# Numele cu spațiu înainte de _v2_ → URL-encode cu %20
dl "${base}/Morpheus%20_v2_us_accent.wav"           "$VOICES_DST/Morpheus _v2_us_accent.wav"
dl "${base}/Morpheus%20_v2_us_accent.txt"           "$VOICES_DST/Morpheus _v2_us_accent.txt"
dl "${base}/Morpheus%20_v2_us_accent.reference.txt" "$VOICES_DST/Morpheus _v2_us_accent.reference.txt"

echo "[ok] HF assets ready in:"
echo " - $WF_DST/${WF_NAME}"
echo " - $VOICES_DST/ (voice refs)"
# ==== end HF assets only ====
