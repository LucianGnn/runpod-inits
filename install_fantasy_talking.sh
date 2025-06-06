#!/bin/bash

echo "Starting download_models_fantasy_talking.sh..."

# Activăm mediul virtual ComfyUI
source /workspace/ComfyUI/venv/bin/activate
if [ $? -ne 0 ]; then
    echo "Failed to activate ComfyUI venv. Exiting."
    exit 1
fi
echo "ComfyUI venv activated."

# Asigură-te că aria2c este instalat.
if ! command -v aria2c &> /dev/null; then
    echo "aria2c not found, installing..."
    sudo apt-get update
    sudo apt-get -y install aria2
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


# Poți adăuga aici și alte căi dacă ai nevoie (ex: LORA_DIR, CONTROLNET_DIR, etc.)

# --- Funcție pentru descărcarea modelelor cu verificare și extragere nume fișier ---
# Parametri: $1 = URL-ul modelului, $2 = Directorul de destinație complet (ex: $DIFFUSION_MODELS_DIR)
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
        aria2c \
            -c \
            -x 16 \
            -s 16 \
            -d "${dest_dir}" \
            -o "${output_filename}" \
            --console-log-level=warn \
            --summary-interval=0 \
            "${model_url}"

        if [ $? -eq 0 ]; then
            echo "Download complete for ${output_filename}."
        else
            echo "Error downloading ${output_filename}." >&2
        fi
    fi
}

echo "Downloading Fantasy Talking models..."

# --- Apelurile funcției pentru fiecare model ---

# Diffusion Models
download_model_with_check "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1-I2V-14B-720P_fp8_e4m3fn.safetensors" "$DIFFUSION_MODELS_DIR"
download_model_with_check "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/fantasytalking_fp16.safetensors" "$DIFFUSION_MODELS_DIR"

# CLIP Vision
download_model_with_check "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors" "$CLIP_VISION_DIR"

# Text Encoders
download_model_with_check "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/umt5-xxl-enc-bf16.safetensors" "$TEXT_ENCODERS_DIR"

# VAE
download_model_with_check "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1_VAE_bf16.safetensors" "$VAE_DIR"

echo "download_models_fantasy_talking.sh completed."
