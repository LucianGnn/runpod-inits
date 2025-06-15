#!/bin/bash

echo "Starting main_init.sh - Orchestrating custom setup."
CUSTOM_SCRIPTS_DIR="/workspace/runpod-inits"

# Instalează biblioteca huggingface_hub (necesară pentru apelul Python de download)
echo "Installing huggingface_hub..."
pip install huggingface_hub

# Activează mediul virtual ComfyUI
source /workspace/ComfyUI/venv/bin/activate
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to activate ComfyUI venv. Exiting main_init.sh."
    exit 1
fi
echo "ComfyUI venv activated."

# "${CUSTOM_SCRIPTS_DIR}"/install_nodes.sh
# if [ $? -ne 0 ]; then
#     echo "Warning: install_nodes.sh reported an error. Continuing initialization."
# fi


echo "Running download_models_fantasy_talking.sh (Model Download)..."
# Folosim calea corectă către scriptul download_models_fantasy_talking.sh
"${CUSTOM_SCRIPTS_DIR}"/download_models_fantasy_talking.sh
if [ $? -ne 0 ]; then
    echo "Warning: download_models_fantasy_talking.sh reported an error."
fi

#---------------------------------- FLUX DEV
# echo "Running download_models_flux_dex.sh (Model Download)..."
# # Folosim calea corectă către scriptul download_models_flux_dex.sh
# "${CUSTOM_SCRIPTS_DIR}"/download_models_flux_dev.sh
# if [ $? -ne 0 ]; then
#     echo "Warning: download_models_flux_dex.sh reported an error."
# fi

# -----------------------------------LTXV
# echo "Running download_models_ltxv13b.sh (Model Download)..."
# # Folosim calea corectă către scriptul download_models_flux_dex.sh
# "${CUSTOM_SCRIPTS_DIR}"/download_models_ltxv13b.sh
# if [ $? -ne 0 ]; then
#     echo "Warning: download_models_flux_dex.sh reported an error."
# fi


# -----------------------------------Framepack
# echo "Running download_models_framepack.sh (Model Download)..."
# # Folosim calea corectă către scriptul download_models_flux_dex.sh
# "${CUSTOM_SCRIPTS_DIR}"/download_models_framepack.sh
# if [ $? -ne 0 ]; then
#     echo "Warning: download_models_framepack.sh reported an error."
# fi


./start.sh

echo "All custom initialization scripts completed."
