#!/bin/bash

echo "Starting download_models_flux_dev.sh..."

# Check if HF_TOKEN was passed from parent script
if [[ -z "$HF_TOKEN" ]]; then
    echo "ERROR: HF_TOKEN not found in environment!"
    echo "This script should be called from main_init.sh or you need to set HF_TOKEN manually."
    echo "If running standalone, uncomment and set the token below:"
    # export HF_TOKEN="hf_your_actual_token_here"
    exit 1
fi

echo "Using HF_TOKEN from environment for authentication."

# Asigură-te că venv-ul ComfyUI este activat.
echo "ComfyUI venv activated."

# Asigură-te că aria2c este instalat.
echo "Checking/Installing aria2c..."
if ! command -v aria2c &> /dev/null; then
    echo "aria2c not found, installing..."
    apt-get update
    apt-get -y install aria2
    hash -r
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

    # Extrage numele fișierului din URL
    local output_filename=$(basename "$model_url" | sed 's/\?.*//')
    local full_path="${dest_dir}/${output_filename}"

    mkdir -p "$dest_dir"

    if [[ -f "$full_path" ]]; then
        echo "Model '${output_filename}' already exists at '${full_path}'. Skipping download."
    else
        echo "Downloading: ${output_filename} (from ${model_url}) to ${dest_dir}"

        # Verifică dacă URL-ul este de la Hugging Face
        if [[ "$model_url" == *"huggingface.co"* ]]; then
            echo "Attempting to download from Hugging Face using direct Python call..."
            local python_download_success=false
            
            local repo_id_match=$(echo "$model_url" | sed -E 's|https://huggingface.co/([^/]+/[^/]+)/.*|\1|')
            local filename_hf=$(echo "$model_url" | sed -E 's|.*/([^/]+\.[a-zA-Z0-9]+)$|\1|')

            if [[ -n "$repo_id_match" && -n "$filename_hf" ]]; then
                # Activăm mediul virtual Python al ComfyUI
                source /workspace/ComfyUI/venv/bin/activate
                
                # Install huggingface_hub if not present
                pip install -q huggingface_hub
                
                # Download using huggingface_hub with token
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

            # Fallback to aria2c with Authorization header
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
        else
            # Non-Hugging Face URL
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

echo "Downloading Flux models..."

# --- Model downloads ---
# UNET
download_model_with_check "https://huggingface.co/black-forest-labs/FLUX.1-dev/resolve/main/flux1-dev.safetensors" "$UNET_DIR"

# CLIP
download_model_with_check "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors" "$CLIP_DIR"
download_model_with_check "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp16.safetensors" "$CLIP_DIR"

# VAE
download_model_with_check "https://huggingface.co/black-forest-labs/FLUX.1-schnell/resolve/main/ae.safetensors" "$VAE_DIR"

echo "download_models_flux_dev.sh completed."
