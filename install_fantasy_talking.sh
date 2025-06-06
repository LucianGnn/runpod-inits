#!/bin/bash

echo "Starting download_models_fantasy_talking.sh..."

# Activăm mediul virtual ComfyUI, esențial pentru ca "pip" să funcționeze corect,
# deși pentru aria2c nu este strict necesar, e o bună practică în scripturile de inițializare ComfyUI.
source /workspace/ComfyUI/venv/bin/activate
if [ $? -ne 0 ]; then
    echo "Failed to activate ComfyUI venv. Exiting."
    exit 1
fi
echo "ComfyUI venv activated."

# Asigură-te că aria2c este instalat.
# Această verificare este deja în init_nodes.sh, dar o repetăm aici pentru siguranță.
if ! command -v aria2c &> /dev/null; then
    echo "aria2c not found, installing..."
    sudo apt-get update
    sudo apt-get -y install aria2
else
    echo "aria2c is already installed."
fi

# Definește modelele FLUX de descărcat sub forma: "URL_MODEL:DIRECTOR_DESTINATIE:NUME_FISIER_IESIRE"
declare -a MODELS=(
    "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1-I2V-14B-720P_fp8_e4m3fn.safetensors:/workspace/ComfyUI/models/diffusion_models:Wan2_1-I2V-14B-720P_fp8_e4m3fn.safetensors"
    "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/fantasytalking_fp16.safetensors:/workspace/ComfyUI/models/diffusion_models:fantasytalking_fp16.safetensors"
    "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors:/workspace/ComfyUI/models/clip_vision:clip_vision_h.safetensors"
    "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/umt5-xxl-enc-bf16.safetensors:/workspace/ComfyUI/models/text_encoders:umt5-xxl-enc-bf16.safetensors"
    "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1_VAE_bf16.safetensors:/workspace/ComfyUI/models/vae:Wan2_1_VAE_bf16.safetensors"
)

echo "Downloading FLUX models with aria2c..."

for model_entry in "${MODELS[@]}"; do
    IFS=':' read -r model_url dest_dir output_filename <<< "$model_entry" # Parsam intrarea

    full_path="${dest_dir}/${output_filename}"

    # Creăm directorul de destinație dacă nu există
    mkdir -p "$dest_dir"

    # Verificăm dacă fișierul modelului există deja
    if [[ -f "$full_path" ]]; then
        echo "Model '${output_filename}' already exists at '${full_path}'. Skipping download."
    else
        echo "Downloading: ${output_filename} (from ${model_url}) to ${dest_dir}"
        # Executăm comanda aria2c
        aria2c \
            --continue \
            --max-concurrent-downloads=5 \
            --max-connection-per-server=16 \
            --split=16 \
            --dir="${dest_dir}" \
            --out="${output_filename}" \
            --console-log-level=warn \
            --summary-interval=0 \
            "${model_url}"
        
        if [ $? -eq 0 ]; then
            echo "Download complete for ${output_filename}."
        else
            echo "Error downloading ${output_filename}." >&2
        fi
    fi
done

echo "download_models_flux.sh completed."
