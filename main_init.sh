#!/bin/bash

echo "Starting main_init.sh - Orchestrating custom setup."

# !!!IMPORTANT!!! Set your Hugging Face token here ONCE for all scripts
# Get your token from: https://huggingface.co/settings/tokens


export HF_TOKEN="hf_your_actual_token_here"  # Replace with your actual token

# Verify HF_TOKEN is set
if [[ -z "$HF_TOKEN" || "$HF_TOKEN" == "hf_your_actual_token_here" ]]; then
    echo "ERROR: HF_TOKEN is not set or still contains placeholder value!"
    echo "Please set your Hugging Face token in main_init.sh"
    echo "Get your token from: https://huggingface.co/settings/tokens"
    exit 1
fi

echo "HF_TOKEN configured - will be passed to all download scripts."

CUSTOM_SCRIPTS_DIR="/workspace/runpod-inits"

# Instalează biblioteca huggingface_hub (necesară pentru apelul Python de download)
echo "Installing huggingface_hub..."
pip install huggingface_hub

# VERIFICĂ dacă ComfyUI și venv există înainte să încerci să activezi
COMFY_VENV="/workspace/ComfyUI/venv/bin/activate"
if [ -f "$COMFY_VENV" ]; then
    echo "ComfyUI venv found, activating..."
    source "$COMFY_VENV"
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to activate ComfyUI venv."
        exit 1
    fi
    echo "ComfyUI venv activated."
else
    echo "WARNING: ComfyUI venv not found at $COMFY_VENV"
    echo "Continuing with system Python..."
fi

# Custom nodes installation (commented out)
# "${CUSTOM_SCRIPTS_DIR}"/install_nodes.sh
# if [ $? -ne 0 ]; then
#     echo "Warning: install_nodes.sh reported an error. Continuing initialization."
# fi

echo "Running download_models_fantasy_talking.sh (Model Download)..."
"${CUSTOM_SCRIPTS_DIR}"/download_models_fantasy_talking.sh
if [ $? -ne 0 ]; then
    echo "Warning: download_models_fantasy_talking.sh reported an error."
fi

#---------------------------------- FLUX DEV
echo "Running download_models_flux_dev.sh (Model Download)..."
"${CUSTOM_SCRIPTS_DIR}"/download_models_flux_dev.sh
if [ $? -ne 0 ]; then
    echo "Warning: download_models_flux_dev.sh reported an error."
fi

# -----------------------------------LTXV
echo "Running download_models_ltxv13b.sh (Model Download)..."
"${CUSTOM_SCRIPTS_DIR}"/download_models_ltxv13b.sh
if [ $? -ne 0 ]; then
    echo "Warning: download_models_ltxv13b.sh reported an error."
fi

# -----------------------------------Framepack
echo "Running download_models_framepack.sh (Model Download)..."
"${CUSTOM_SCRIPTS_DIR}"/download_models_framepack.sh
if [ $? -ne 0 ]; then
    echo "Warning: download_models_framepack.sh reported an error."
fi

# La sfârșit, verifică dacă să pornească ComfyUI
if [ -d "/workspace/ComfyUI" ] && [ -f "/workspace/ComfyUI/main.py" ]; then
    echo "Starting ComfyUI..."
    cd /workspace/ComfyUI
    
    # Activează venv dacă există
    if [ -f "venv/bin/activate" ]; then
        source venv/bin/activate
    fi
    
    nohup python main.py --listen 0.0.0.0 --port 8188 > /workspace/comfyui.log 2>&1 &
    echo "ComfyUI started in background on port 8188"
else
    echo "ComfyUI not found, cannot start it"
fi

echo "All custom initialization scripts completed."
