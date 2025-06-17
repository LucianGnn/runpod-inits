#!/bin/bash

echo "Starting download_models_sonic.sh..."

# Check if HF_TOKEN was passed from parent script
if [[ -z "$HF_TOKEN" ]]; then
    echo "ERROR: HF_TOKEN not found in environment!"
    echo "This script should be called from main_init.sh or you need to set HF_TOKEN manually."
    echo "If running standalone, uncomment and set the token below:"
    # export HF_TOKEN="hf_your_actual_token_here"
    exit 1
fi

echo "Using HF_TOKEN from environment for authentication."

# Verifică și activează venv-ul dacă nu este deja activ
if [[ -z "$VIRTUAL_ENV" ]]; then
    echo "Activating ComfyUI venv..."
    source /workspace/ComfyUI/venv/bin/activate
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to activate ComfyUI venv. Exiting."
        exit 1
    fi
else
    echo "ComfyUI venv already activated."
fi

# Asigură-te că aria2c și gdown sunt instalate
echo "Checking/Installing required tools..."
if ! command -v aria2c &> /dev/null; then
    echo "aria2c not found, installing..."
    apt-get update
    apt-get -y install aria2
    hash -r
else
    echo "aria2c is already installed."
fi

# Install gdown for Google Drive downloads
pip install -q gdown

# --- Definirea constantelor pentru căile modelelor ComfyUI ---
COMFYUI_MODELS_BASE="/workspace/ComfyUI/models"
SONIC_DIR="${COMFYUI_MODELS_BASE}/sonic"
SONIC_RIFE_DIR="${SONIC_DIR}/RIFE"
CHECKPOINTS_DIR="${COMFYUI_MODELS_BASE}/checkpoints"

# Create directories
mkdir -p "$SONIC_DIR"
mkdir -p "$SONIC_RIFE_DIR"
mkdir -p "$CHECKPOINTS_DIR"

# --- Function for downloading from Hugging Face ---
download_hf_model() {
    local model_url="$1"
    local dest_dir="$2"
    local output_filename=$(basename "$model_url" | sed 's/\?.*//')
    local full_path="${dest_dir}/${output_filename}"

    if [[ -f "$full_path" ]]; then
        echo "Model '${output_filename}' already exists at '${full_path}'. Skipping download."
        return
    fi

    echo "Downloading HF model: ${output_filename} to ${dest_dir}"
    
    local repo_id_match=$(echo "$model_url" | sed -E 's|https://huggingface.co/([^/]+/[^/]+)/.*|\1|')
    local filename_hf=$(echo "$model_url" | sed -E 's|.*/([^/]+\.[a-zA-Z0-9]+)$|\1|')

    if [[ -n "$repo_id_match" && -n "$filename_hf" ]]; then
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
            echo "Download complete for ${output_filename}"
        else
            echo "Error downloading ${output_filename} from Hugging Face"
        fi
    fi
}

# --- Function for downloading from Google Drive folder ---
download_gdrive_folder() {
    local folder_id="$1"
    local dest_dir="$2"
    local folder_name="$3"

    echo "Downloading Google Drive folder '${folder_name}' to ${dest_dir}"
    
    # Try to download the entire folder
    gdown --folder "https://drive.google.com/drive/folders/${folder_id}" -O "${dest_dir}" --remaining-ok
    
    if [ $? -eq 0 ]; then
        echo "Successfully downloaded Google Drive folder: ${folder_name}"
    else
        echo "Warning: Failed to download Google Drive folder: ${folder_name}"
        echo "You may need to manually download from: https://drive.google.com/drive/folders/${folder_id}"
    fi
}

# --- Function for downloading from ModelScope (alternative to Google Drive) ---
download_modelscope() {
    local dest_dir="$1"
    
    echo "Downloading Sonic models from ModelScope as alternative..."
    
    # Clone the ModelScope repository
    if [ ! -d "/tmp/sonic_models" ]; then
        git clone https://www.modelscope.cn/zhuzhukeji/ComfyUI_Sonic_Models.git /tmp/sonic_models
        if [ $? -eq 0 ]; then
            echo "Copying models from ModelScope repo..."
            cp -r /tmp/sonic_models/* "${dest_dir}/"
            echo "ModelScope models copied successfully"
        else
            echo "Failed to clone ModelScope repository"
        fi
    else
        echo "ModelScope repository already exists, updating..."
        cd /tmp/sonic_models && git pull
        cp -r /tmp/sonic_models/* "${dest_dir}/"
    fi
}

echo "=== Downloading Sonic Models ==="

# Try Google Drive first, fallback to ModelScope
echo "Attempting to download main Sonic models from Google Drive..."
download_gdrive_folder "1oe8VTPUy0-MHHW2a_NJ1F8xL-0VN5G7W" "$SONIC_DIR" "Sonic Main Models"

# Check if download was successful (folder should contain files)
if [ "$(ls -A $SONIC_DIR 2>/dev/null)" ]; then
    echo "Google Drive download appears successful"
else
    echo "Google Drive download failed or incomplete, trying ModelScope..."
    download_modelscope "$SONIC_DIR"
fi

echo "=== Downloading RIFE Models ==="

# Download RIFE models to RIFE subfolder
echo "Attempting to download RIFE models from Google Drive..."
download_gdrive_folder "1QIIDvCDU-rp1ZB8qDA6NQqVn8F9WYMhE" "$SONIC_RIFE_DIR" "RIFE Models"

echo "=== Downloading SVD Models ==="

# Download Stable Video Diffusion models from Hugging Face
echo "Downloading Stable Video Diffusion models..."

# Main SVD model files
download_hf_model "https://huggingface.co/stabilityai/stable-video-diffusion-img2vid-xt/resolve/main/svd_xt.safetensors" "$CHECKPOINTS_DIR"
download_hf_model "https://huggingface.co/stabilityai/stable-video-diffusion-img2vid-xt/resolve/main/svd_xt_image_decoder.safetensors" "$CHECKPOINTS_DIR"

# Alternative: try to download the full model if individual files don't work
if [ ! -f "$CHECKPOINTS_DIR/svd_xt.safetensors" ]; then
    echo "Trying alternative SVD download method..."
    python -c "
from huggingface_hub import snapshot_download
import os
try:
    snapshot_download(
        repo_id='stabilityai/stable-video-diffusion-img2vid-xt',
        local_dir='${CHECKPOINTS_DIR}/svd_xt_full',
        token='${HF_TOKEN}',
        ignore_patterns=['*.md', '*.txt', '.git*']
    )
    print('SVD full repo downloaded successfully')
except Exception as e:
    print(f'SVD download failed: {e}')
"
fi

echo "=== Download Summary ==="
echo "Sonic models location: $SONIC_DIR"
echo "RIFE models location: $SONIC_RIFE_DIR"
echo "Checkpoints location: $CHECKPOINTS_DIR"

# List what was downloaded
if [ -d "$SONIC_DIR" ] && [ "$(ls -A $SONIC_DIR)" ]; then
    echo "Sonic models found:"
    ls -la "$SONIC_DIR"
else
    echo "WARNING: No Sonic models found. Manual download may be required."
fi

if [ -d "$SONIC_RIFE_DIR" ] && [ "$(ls -A $SONIC_RIFE_DIR)" ]; then
    echo "RIFE models found:"
    ls -la "$SONIC_RIFE_DIR"
else
    echo "WARNING: No RIFE models found. Manual download may be required."
fi

echo "=== Manual Download Instructions (if needed) ==="
echo "If automatic downloads failed, please manually download:"
echo "1. Sonic models: https://drive.google.com/drive/folders/1oe8VTPUy0-MHHW2a_NJ1F8xL-0VN5G7W"
echo "   Extract to: $SONIC_DIR"
echo "2. RIFE models: https://drive.google.com/drive/folders/1QIIDvCDU-rp1ZB8qDA6NQqVn8F9WYMhE"
echo "   Extract to: $SONIC_RIFE_DIR"
echo "3. Alternative Sonic: https://www.modelscope.cn/models/zhuzhukeji/ComfyUI_Sonic_Models/files"

echo "download_models_sonic.sh completed."
