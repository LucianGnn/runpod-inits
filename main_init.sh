#!/bin/bash

echo "Starting main_init.sh - Orchestrating custom setup."

# Defineste calea catre directorul cu scripturile tale custom
# Acesta ar trebui să fie '/workspace/runpod-inits', conform modificării Container Start Command
CUSTOM_SCRIPTS_DIR="/workspace/runpod-inits"

# --- Secțiune: Verificarea și Activarea Mediului Virtual ComfyUI ---
source /workspace/ComfyUI/venv/bin/activate
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to activate ComfyUI venv. Exiting main_init.sh."
    exit 1
fi
echo "ComfyUI venv activated."

echo "Running install_nodes.sh (Custom Nodes & Dependencies)..."
# Folosim calea corectă către scriptul install_nodes.sh
"${CUSTOM_SCRIPTS_DIR}"/install_nodes.sh
if [ $? -ne 0 ]; then
    echo "Warning: install_nodes.sh reported an error. Continuing initialization."
fi


echo "Running download_models_fantasy_talking.sh (Model Download)..."
# Folosim calea corectă către scriptul download_models_fantasy_talking.sh
"${CUSTOM_SCRIPTS_DIR}"/download_models_fantasy_talking.sh
if [ $? -ne 0 ]; then
    echo "Warning: download_models_fantasy_talking.sh reported an error."
fi

# --- Secțiune: Pornirea ComfyUI ---
# Asigură-te că te afli în directorul ComfyUI înainte de a rula run_gpu.sh
echo "All custom initialization scripts completed. Starting ComfyUI..."

/workspace/ComfyUI/run_gpu.sh
# Notă: Comanda de mai sus va bloca execuția scriptului main_init.sh.
# Orice 'echo' după ea NU va fi afișat în log-uri decât dacă ComfyUI se oprește.
