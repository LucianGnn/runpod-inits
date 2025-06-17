#!/bin/bash

echo "Starting download_models_framepack.sh..."

# !!!IMPORTANT!!! Set your Hugging Face token here
# Get your token from: https://huggingface.co/settings/tokens
export HF_TOKEN="hf_your_actual_token_here"  # Replace with your actual token

# Verify HF_TOKEN is set
if [[ -z "$HF_TOKEN" || "$HF_TOKEN" == "hf_your_actual_token_here" ]]; then
    echo "ERROR: HF_TOKEN is not set or still contains placeholder value!"
    echo "Please set your Hugging Face token in the script or as an environment variable."
    echo "Get your token from: https://huggingface.co/settings/tokens"
    exit 1
fi

# Asigură-te că venv-ul ComfyUI este activat.
echo "ComfyUI venv activated."

# Asigură-te că aria2c este instalat.
echo "Checking/Installing aria2c..."
if ! command -v aria2c &> /dev/null; then
    echo "aria2c not found, installing..."
    apt-get update
    apt-get -y install aria2
    hash -r # Reconstruiește hash-ul comenzilor shell-ului
else
    echo "aria2c is already installed."
fi

# --- Definirea constantelor pentru căile modelelor ComfyUI ---
COMFYUI_MODELS_BASE="/workspace/ComfyUI/models"
CHECKPOINTS_DIR="${COMFYUI_MODELS_BASE}/checkpoints"
CLIP_DIR="${COMFYUI_MODELS_BASE}/clip"
CLIP_VISION_DIR="${COMFYUI_MODELS_BASE}/clip_vision"
DIFFUSION_MODELS_DIR="${COMFYUI_MODELS_BASE}/diffusion_models"
TEXT_ENCODERS_DIR="${COMFYUI_MODELS_BASE}/text_encoders"
LORAS_DIR="${COMFYUI_MODELS_BASE}/loras"
UNET_DIR="${COMFYUI_MODELS_BASE}/unet"
VAE_DIR="${COMFYUI_MODELS_BASE}/vae"

# --- Funcție pentru descărcarea modelelor cu verificare și extragere nume fișier ---
download_model_with_check() {
    local model_url="$1"
    local dest_dir="$2"

    # Extrage numele fișierului din URL (eliminând parametrii de query)
    local output_filename=$(basename "$model_url" | sed 's/\?.*//')
    local full_path="${dest_dir}/${output_filename}"

    mkdir -p "$dest_dir" # Creăm directorul de destinație dacă nu există

    if [[ -f "$full_path" ]]; then
        echo "Model '${output_filename}' already exists at '${full_path}'. Skipping download."
    else
        echo "Downloading: ${output_filename} (from ${model_url}) to ${dest_dir}"

        # Verifică dacă URL-ul este de la Hugging Face
        if [[ "$model_url" == *"huggingface.co"* ]]; then
            echo "Attempting to download from Hugging Face using direct Python call..."
            local python_download_success=false # Flag pentru a urmări succesul descărcării Python
            
            local repo_id_match=$(echo "$model_url" | sed -E 's|https://huggingface.co/([^/]+/[^/]+)/.*|\1|')
            local filename_hf=$(echo "$model_url" | sed -E 's|.*/([^/]+\.[a-zA-Z0-9]+)$|\1|') # Extrage numele fișierului cu extensie

            if [[ -n "$repo_id_match" && -n "$filename_hf" ]]; then
                # Activăm mediul virtual Python al ComfyUI
                source /workspace/ComfyUI/venv/bin/activate
                
                # Install huggingface_hub if not present
                pip install -q huggingface_hub
                
                # Apelăm funcția Python hf_hub_download direct din linia de comandă
                # Cu token explicit pentru autentificare
                python -c "
import os
from huggingface_hub import hf_hub_download
try:
    os.makedirs('${dest_dir}', exist_ok=True)
    hf_hub_download(
        repo_id='${repo_id_match}', 
        filename='${filename_hf}', 
        local_dir='${dest_dir}', 
        local_dir_use_symlinks=False, 
        resume_download=True,
        token='${HF_TOKEN}'
    )
    print('SUCCESS: Download completed')
except Exception as e:
    print(f'ERROR: {e}')
    exit(1)
"
                
                if [ $? -eq 0 ]; then
                    echo "Download complete for ${output_filename} using direct Python call."
                    python_download_success=true
                else
                    echo "Error downloading ${output_filename} using direct Python call." >&2
                    echo "Make sure you have access to the model and your HF_TOKEN is valid." >&2
                fi
            else
                echo "ERROR: Could not parse Hugging Face URL for repo_id and filename for ${output_filename}." >&2
            fi

            # Încercăm aria2c ca fallback doar dacă descărcarea Python nu a avut succes
            if ! $python_download_success; then
                echo "Attempting aria2c fallback for ${output_filename} (Hugging Face URL)."
                aria2c \
                    -c -x 16 -s 16 \
                    -d "${dest_dir}" -o "${output_filename}" \
                    --console-log-level=warn --summary-interval=0 \
                    --header="Authorization: Bearer ${HF_TOKEN}" \
                    "${model_url}"
                if [ $? -eq 0 ]; then
                    echo "Download complete for ${output_filename} using aria2c fallback."
                else
                    echo "Error downloading ${output_filename} using aria2c fallback. Both methods failed." >&2
                fi
            fi
        else # Nu este un URL Hugging Face, folosim direct aria2c
            echo "Downloading using aria2c (non-Hugging Face URL)..."
            aria2c \
                -c -x 16 -s 16 \
                -d "${dest_dir}" -o "${output_filename}" \
                --console-log-level=warn --summary-interval=0 \
                "${model_url}"
            if [ $? -eq 0 ]; then
                echo "Download complete for ${output_filename}."
            else
                echo "Error downloading ${output_filename}." >&2
            fi
        fi
    fi
}

echo "Downloading framepack models..."

# --- Apelurile funcției pentru fiecare model ---

# DIFFUSION_MODELS_DIR
download_model_with_check "https://huggingface.co/Kijai/HunyuanVideo_comfy/resolve/main/FramePackI2V_HY_fp8_e4m3fn.safetensors" "$DIFFUSION_MODELS_DIR"  #16 gb

# CLIP Vision
download_model_with_check "https://huggingface.co/Comfy-Org/sigclip_vision_384/resolve/main/sigclip_vision_patch14_384.safetensors" "$CLIP_VISION_DIR"

# VAE
download_model_with_check "https://huggingface.co/Comfy-Org/HunyuanVideo_repackaged/resolve/main/split_files/vae/hunyuan_video_vae_bf16.safetensors" "$VAE_DIR"

# TEXT_ENCODERS
download_model_with_check "https://huggingface.co/Comfy-Org/HunyuanVideo_repackaged/resolve/main/split_files/text_encoders/llava_llama3_fp16.safetensors" "$TEXT_ENCODERS_DIR"
download_model_with_check "https://huggingface.co/Comfy-Org/HunyuanVideo_repackaged/resolve/main/split_files/text_encoders/clip_l.safetensors" "$TEXT_ENCODERS_DIR"

echo "download_models_framepack.sh completed."
