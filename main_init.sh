#!/bin/bash

echo "Starting main_init.sh - Orchestrating custom setup."

# --- Secțiune: Verificarea și Activarea Mediului Virtual ComfyUI ---
# Acest pas este crucial pentru toate scripturile Python/PIP.
source /workspace/ComfyUI/venv/bin/activate

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to activate ComfyUI venv. Exiting main_init.sh."
    exit 1
fi
echo "ComfyUI venv activated."

echo "Running install_nodes.sh (Custom Nodes & Dependencies)..."
/workspace/install_nodes.sh
if [ $? -ne 0 ]; then
    echo "Warning: install_nodes.sh reported an error. Continuing initialization."
fi


echo "Running download_models_fantasy_talking.sh (Model Download)..."
/workspace/download_models_fantasy_talking.sh
if [ $? -ne 0 ]; then
    echo "Warning: download_models_fantasy_talking.sh reported an error."
fi



echo "main_init.sh completed. ComfyUI will now be started by /start.sh."
