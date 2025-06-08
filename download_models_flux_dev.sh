#!/bin/bash

echo "Starting download_models_flux_dev.sh..."

# Asigură-te că venv-ul ComfyUI este activat.
# Notă: Această verificare '$?' ar trebui să fie după o comandă care setează venv-ul,
# de obicei 'source /path/to/venv/bin/activate'.
# Presupunem că venv-ul este activat anterior de main_init.sh.
# Dacă nu, poți decomenta și adăuga aici:
# source /workspace/ComfyUI/venv/bin/activate
# if [ $? -ne 0 ]; then
#     echo "ERROR: Failed to activate ComfyUI venv in download_models_flux_dev.sh. Exiting."
#     exit 1
# fi
echo "ComfyUI venv activated." # Acest mesaj se bazează pe activarea venv-ului înainte de apelul acestui script.

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

        # Verifică dacă URL-ul este de la Hugging Face
        if [[ "$model_url" == *"huggingface.co"* ]]; then
            echo "Attempting to download from Hugging Face using direct Python call..."
            local python_download_success=false # Flag pentru a urmări succesul descărcării Python
            
            local repo_id_match=$(echo "$model_url" | sed -E 's|https://huggingface.co/([^/]+/[^/]+)/.*|\1|')
            local filename_hf=$(echo "$model_url" | sed -E 's|.*/([^/]+\.[a-zA-Z0-9]+)$|\1|') # Extrage numele fișierului cu extensie

            if [[ -n "$repo_id_match" && -n "$filename_hf" ]]; then
                # Activăm mediul virtual Python al ComfyUI
                source /workspace/ComfyUI/venv/bin/activate
                
                # Apelăm funcția Python hf_hub_download direct din linia de comandă
                # Aceasta va folosi automat HF_TOKEN din variabilele de mediu
                python -c "from huggingface_hub import hf_hub_download; import os; os.makedirs('${dest_dir}', exist_ok=True); hf_hub_download(repo_id='${repo_id_match}', filename='${filename_hf}', local_dir='${dest_dir}', local_dir_use_symlinks=False, resume_download=True)"
                
                if [ $? -eq 0 ]; then
                    echo "Download complete for ${output_filename} using direct Python call."
                    python_download_success=true
                else
                    echo "Error downloading ${output_filename} using direct Python call." >&2
                    echo "Python download failed. It might be due to missing HF_TOKEN or specific model access restrictions." >&2
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

echo "Downloading Flux models..."

# # --- Apelurile funcției pentru fiecare model ---

# # UNET
# download_model_with_check "https://huggingface.co/black-forest-labs/FLUX.1-dev/resolve/main/flux1-dev.safetensors" "$UNET_DIR"

# # CLIP
# download_model_with_check "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors" "$CLIP_DIR"
# download_model_with_check "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp16.safetensors" "$CLIP_DIR"

# VAE
# download_model_with_check "https://huggingface.co/black-forest-labs/FLUX.1-schnell/resolve/main/ae.safetensors" "$VAE_DIR"

download_model_with_check "https://huggingface.co/stabilityai/stable-video-diffusion-img2vid-xt/resolve/main/svd_xt_image_decoder.safetensors" "$CHECKPOINTS_DIR"

echo "download_models_flux_dev.sh completed."
