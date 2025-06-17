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
SONIC_WHISPER_DIR="${SONIC_DIR}/whisper-tiny"
CHECKPOINTS_DIR="${COMFYUI_MODELS_BASE}/checkpoints"

# Create directories
mkdir -p "$SONIC_DIR"
mkdir -p "$SONIC_RIFE_DIR"
mkdir -p "$SONIC_WHISPER_DIR"
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

    # Check if folder already has content
    if [ -d "$dest_dir" ] && [ "$(ls -A $dest_dir 2>/dev/null)" ]; then
        echo "Folder '${folder_name}' already contains files at ${dest_dir}. Skipping download."
        return 0
    fi

    echo "Downloading Google Drive folder '${folder_name}' to ${dest_dir}"
    
    # Try to download the entire folder
    gdown --folder "https://drive.google.com/drive/folders/${folder_id}" -O "${dest_dir}" --remaining-ok
    
    if [ $? -eq 0 ]; then
        echo "Successfully downloaded Google Drive folder: ${folder_name}"
        return 0
    else
        echo "Warning: Failed to download Google Drive folder: ${folder_name}"
        echo "You may need to manually download from: https://drive.google.com/drive/folders/${folder_id}"
        return 1
    fi
}

# --- Function for downloading from ModelScope (alternative to Google Drive) ---
download_modelscope() {
    local dest_dir="$1"
    
    # Check if folder already has content
    if [ -d "$dest_dir" ] && [ "$(ls -A $dest_dir 2>/dev/null)" ]; then
        echo "ModelScope: Destination folder already contains files at ${dest_dir}. Skipping download."
        return 0
    fi
    
    echo "Downloading Sonic models from ModelScope as alternative..."
    
    # Clone the ModelScope repository
    if [ ! -d "/tmp/sonic_models" ]; then
        git clone https://www.modelscope.cn/zhuzhukeji/ComfyUI_Sonic_Models.git /tmp/sonic_models
        if [ $? -eq 0 ]; then
            echo "Copying models from ModelScope repo..."
            cp -r /tmp/sonic_models/* "${dest_dir}/"
            echo "ModelScope models copied successfully"
            return 0
        else
            echo "Failed to clone ModelScope repository"
            return 1
        fi
    else
        echo "ModelScope repository already exists, updating..."
        cd /tmp/sonic_models && git pull
        cp -r /tmp/sonic_models/* "${dest_dir}/"
        return 0
    fi
}

echo "=== Downloading Sonic Models ==="

# Check if main Sonic models already exist
sonic_main_files=("audio2bucket.pth" "audio2token.pth" "unet.pth" "yoloface_v5m.pt")
sonic_files_exist=true

for file in "${sonic_main_files[@]}"; do
    if [ ! -f "$SONIC_DIR/$file" ]; then
        sonic_files_exist=false
        break
    fi
done

if [ "$sonic_files_exist" = true ]; then
    echo "Main Sonic models already exist. Skipping download."
else
    echo "Attempting to download main Sonic models from Google Drive..."
    download_gdrive_folder "1oe8VTPUy0-MHHW2a_NJ1F8xL-0VN5G7W" "$SONIC_DIR" "Sonic Main Models"

    # Check if download was successful (folder should contain files)
    if [ "$(ls -A $SONIC_DIR 2>/dev/null)" ]; then
        echo "Google Drive download appears successful"
    else
        echo "Google Drive download failed or incomplete, trying ModelScope..."
        download_modelscope "$SONIC_DIR"
    fi
fi

# Always check for Sonic subfolder and move files if needed (even if files existed before)
if [ -d "$SONIC_DIR/Sonic" ] && [ "$(ls -A $SONIC_DIR/Sonic 2>/dev/null)" ]; then
    echo "Found Sonic subfolder with content. Moving files to main sonic directory..."
    
    # Move all files from Sonic/ to parent directory
    find "$SONIC_DIR/Sonic" -type f -exec mv {} "$SONIC_DIR/" \; 2>/dev/null
    
    # Move directories if any (except the current Sonic folder itself)
    find "$SONIC_DIR/Sonic" -mindepth 1 -maxdepth 1 -type d -exec mv {} "$SONIC_DIR/" \; 2>/dev/null
    
    # Remove empty Sonic directory
    if [ ! "$(ls -A $SONIC_DIR/Sonic 2>/dev/null)" ]; then
        rmdir "$SONIC_DIR/Sonic" 2>/dev/null
        echo "Files moved successfully and Sonic subfolder removed"
    else
        echo "Warning: Some files might remain in Sonic subfolder"
    fi
elif [ -d "$SONIC_DIR/Sonic" ]; then
    echo "Sonic subfolder exists but is empty, removing it..."
    rmdir "$SONIC_DIR/Sonic" 2>/dev/null
else
    echo "No Sonic subfolder found - files are already in correct location"
fi

echo "=== Downloading RIFE Models ==="

# Check if RIFE models already exist
if [ -f "$SONIC_RIFE_DIR/flownet.pkl" ]; then
    echo "RIFE model (flownet.pkl) already exists. Skipping download."
else
    echo "Attempting to download RIFE models from Google Drive..."
    download_gdrive_folder "1QIIDvCDU-rp1ZB8qDA6NQqVn8F9WYMhE" "$SONIC_RIFE_DIR" "RIFE Models"
fi

echo "=== Downloading Whisper-Tiny Models ==="

# Check if all Whisper-Tiny files already exist
whisper_files=("config.json" "model.safetensors" "preprocessor_config.json")
whisper_complete=true

for file in "${whisper_files[@]}"; do
    if [ ! -f "$SONIC_WHISPER_DIR/$file" ]; then
        whisper_complete=false
        break
    fi
done

if [ "$whisper_complete" = true ]; then
    echo "All Whisper-Tiny models already exist. Skipping download."
else
    echo "Downloading missing Whisper-Tiny models..."
    download_hf_model "https://huggingface.co/openai/whisper-tiny/resolve/main/config.json" "$SONIC_WHISPER_DIR"
    download_hf_model "https://huggingface.co/openai/whisper-tiny/resolve/main/model.safetensors" "$SONIC_WHISPER_DIR"
    download_hf_model "https://huggingface.co/openai/whisper-tiny/resolve/main/preprocessor_config.json" "$SONIC_WHISPER_DIR"
fi

echo "=== Downloading SVD Models ==="

# Check if SVD models already exist
svd_exists=false
if [ -f "$CHECKPOINTS_DIR/svd_xt.safetensors" ] || [ -f "$CHECKPOINTS_DIR/svd_xt_1_1.safetensors" ]; then
    echo "SVD models already exist. Skipping download."
    svd_exists=true
fi

if [ "$svd_exists" = false ]; then
    echo "Downloading Stable Video Diffusion models..."
    echo "Choose ONE of these models to download:"
    echo "1. svd_xt.safetensors (Larger, ~9.56 GB)"
    echo "2. svd_xt_1_1.safetensors (Smaller, ~4.78 GB)"
    echo "Downloading both options for flexibility..."

    # Download both SVD variants
    download_hf_model "https://huggingface.co/stabilityai/stable-video-diffusion-img2vid-xt/resolve/main/svd_xt.safetensors" "$CHECKPOINTS_DIR"
    download_hf_model "https://huggingface.co/stabilityai/stable-video-diffusion-img2vid-xt-1-1/resolve/main/svd_xt_1_1.safetensors" "$CHECKPOINTS_DIR"
fi

echo "=== Download Summary ==="
echo "Sonic models location: $SONIC_DIR"
echo "RIFE models location: $SONIC_RIFE_DIR"
echo "Whisper-Tiny models location: $SONIC_WHISPER_DIR"
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

if [ -d "$SONIC_WHISPER_DIR" ] && [ "$(ls -A $SONIC_WHISPER_DIR)" ]; then
    echo "Whisper-Tiny models found:"
    ls -la "$SONIC_WHISPER_DIR"
else
    echo "WARNING: No Whisper-Tiny models found."
fi

echo "=== Manual Download Instructions (if needed) ==="
echo "If automatic downloads failed, please manually download:"
echo ""
echo "📁 MAIN FOLDER: ComfyUI/models/sonic/"
echo "   Download these files directly to sonic folder:"
echo "   • audio2bucket.pth"
echo "   • audio2token.pth" 
echo "   • unet.pth"
echo "   • yoloface_v5m.pt"
echo "   From: https://drive.google.com/drive/folders/1oe8VTPUy0-MHHW2a_NJ1F8xL-0VN5G7W"
echo ""
echo "📁 SUBFOLDER: ComfyUI/models/sonic/RIFE/"
echo "   • flownet.pkl"
echo "   From: https://drive.google.com/drive/folders/1QIIDvCDU-rp1ZB8qDA6NQqVn8F9WYMhE"
echo ""
echo "📁 SUBFOLDER: ComfyUI/models/sonic/whisper-tiny/"
echo "   • config.json: https://huggingface.co/openai/whisper-tiny/resolve/main/config.json"
echo "   • model.safetensors: https://huggingface.co/openai/whisper-tiny/resolve/main/model.safetensors"
echo "   • preprocessor_config.json: https://huggingface.co/openai/whisper-tiny/resolve/main/preprocessor_config.json"
echo ""
echo "📁 SVD CHECKPOINT: ComfyUI/models/checkpoints/"
echo "   Choose ONE of these:"
echo "   • svd_xt.safetensors (Larger, ~9.56 GB)"
echo "   • svd_xt_1_1.safetensors (Smaller, ~4.78 GB)"
echo ""
echo "🔗 Alternative Sonic source: https://www.modelscope.cn/models/zhuzhukeji/ComfyUI_Sonic_Models/files"

echo "download_models_sonic.sh completed."
