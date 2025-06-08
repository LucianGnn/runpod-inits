#!/bin/bash

echo "Starting download_models_flux_dev.sh..."

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to activate ComfyUI venv in download_models_flux_dev.sh. Exiting."
    exit 1
fi
echo "ComfyUI venv activated."

# Asigură-te că aria2c este instalat.
# Asigură-te că aria2c este instalat.
echo "Checking/Installing aria2c..."
if ! command -v aria2c &> /dev/null; then
    echo "aria2c not found, installing..."
    apt-get update
    apt-get -y install aria2
    hash -r  # Adaugă această linie AICI
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

echo "Downloading Flux models..."

# --- Apelurile funcției pentru fiecare model ---

# CHECKPOPINT
download_model_with_check "https://huggingface.co/black-forest-labs/FLUX.1-dev/resolve/main/flux1-dev.safetensors" "$CHECKPOINTS_DIR"

# CLIP 
download_model_with_check "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors" "$CLIP_DIR"
download_model_with_check "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp16.safetensors" "$CLIP_DIR"

# VAE
download_model_with_check "https://huggingface.co/black-forest-labs/FLUX.1-schnell/resolve/main/ae.safetensors" "$VAE_DIR"

echo "download_models_flux_dev.sh completed."
