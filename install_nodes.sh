#!/bin/bash

echo "Starting init_nodes.sh..."

if [ $? -ne 0 ]; then
    echo "Failed to activate ComfyUI venv in init_nodes.sh. Exiting."
    exit 1
fi
echo "ComfyUI venv activated."

# Install APT packages
echo "Installing APT packages..."
sudo apt-get update
# Verificare și instalare aria2
if ! command -v aria2c &> /dev/null; then
    echo "aria2c not found, installing..."
    sudo apt-get -y install aria2
else
    echo "aria2c is already installed."
fi

# Define PIP packages
PIP_PACKAGES=(
    "huggingface_hub"
)

echo "Installing PIP packages..."
for pkg in "${PIP_PACKAGES[@]}"; do
    # Verifică dacă pachetul PIP este deja instalat
    if ! pip show "$pkg" &> /dev/null; then
        echo "Installing $pkg..."
        pip install --no-cache-dir "$pkg"
        if [ $? -ne 0 ]; then
            echo "Warning: Failed to install PIP package: $pkg"
        fi
    else
        echo "PIP package $pkg is already installed."
    fi
done

# Define custom nodes
NODES=(
	"https://github.com/ltdrdata/ComfyUI-Manager"
	"https://github.com/crystian/ComfyUI-Crystools"
	"https://github.com/kijai/ComfyUI-WanVideoWrapper"
	"https://github.com/Lightricks/ComfyUI-LTXVideo"
	"https://github.com/rgthree/rgthree-comfy"
	"https://github.com/XLabs-AI/x-flux-comfyui"
	"https://github.com/kijai/ComfyUI-KJNodes"
	"https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite"
	"https://github.com/justUmen/Bjornulf_custom_nodes"
	"https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes"
	"https://github.com/christian-byrne/audio-separation-nodes-comfyui"
	"https://github.com/MinorBoy/ComfyUI_essentials_mb"
)

# Clone/Update custom nodes
echo "Cloning/Updating custom nodes..."
for repo in "${NODES[@]}"; do
    dir="${repo##*/}"
    path="/workspace/ComfyUI/custom_nodes/${dir}"
    requirements="${path}/requirements.txt"

    if [[ -d "$path" ]]; then
        echo "Node '${dir}' already exists. Updating..."
        ( cd "$path" && git pull )
    else
        echo "Node '${dir}' not found. Cloning: ${repo} to ${path}..."
        git clone "${repo}" "${path}" --recursive
    fi

    if [[ -e "$requirements" ]]; then
        echo "Installing requirements for ${dir}..."
        # Verifică dacă cerințele sunt deja îndeplinite (o verificare mai simplă, dar utilă)
        # O verificare mai robustă ar implica parcurgerea fiecărei linii din requirements.txt
        # și verificarea individuală. Pentru simplitate, vom rula pip install -r oricum.
        pip install --no-cache-dir -r "$requirements"
        if [ $? -ne 0 ]; then
            echo "Warning: Failed to install requirements for ${dir}"
        fi
    fi
done

echo "init_nodes.sh completed."
