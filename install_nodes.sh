#!/bin/bash

echo "Starting install_nodes.sh..."

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to activate ComfyUI venv. Exiting install_nodes.sh."
    exit 1
fi
echo "ComfyUI venv activated."


# Install APT packages
echo "Installing APT packages..."
# ATENTIE: Am ELIMINAT 'sudo' de aici, deoarece nu functioneaza pe RunPod
#apt-get update 
# Verificare și instalare aria2
if ! command -v aria2c &> /dev/null; then
    echo "aria2c not found, installing..."
    # ATENTIE: Am ELIMINAT 'sudo' de aici
    apt-get -y install aria2
else
    echo "aria2c is already installed."
fi

# Define PIP packages (pachete PIP globale, nu specifice nodurilor)
PIP_PACKAGES=(
    "huggingface_hub"
)

echo "Installing global PIP packages..."
for pkg in "${PIP_PACKAGES[@]}"; do
    if ! pip show "$pkg" &> /dev/null; then
        echo "Installing $pkg..."
        pip install --no-cache-dir "$pkg"
        if [ $? -ne 0 ]; then
            echo "Warning: Failed to install global PIP package: $pkg"
        fi
    else
        echo "Global PIP package $pkg is already installed."
    fi
done

# Define custom nodes (URLs-urile repository-urilor Git)
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

# --- MODIFICARE PENTRU A INSTALA REQUIREMENTS DOAR LA PRIMA CLONARE ---
TEMP_REQUIREMENTS_FILE="/tmp/all_comfyui_requirements.txt"
> "$TEMP_REQUIREMENTS_FILE"

# Clone/Update custom nodes și colectează cerințele
echo "Cloning/Updating custom nodes..."
for repo in "${NODES[@]}"; do
    dir="${repo##*/}"
    path="/workspace/ComfyUI/custom_nodes/${dir}"
    requirements="${path}/requirements.txt"

    WAS_CLONED_NOW=false # Flag pentru a verifica dacă nodul a fost clonat în această rulare

    if [[ -d "$path" ]]; then
        echo "Node '${dir}' already exists. Updating (git pull)..."
        ( cd "$path" && git pull )
        # AICI, DACĂ NODUL EXISTA DEJA, NU MAI COLECTĂM CERINȚELE LUI PENTRU INSTALARE.
        # RISC: Dacă requirements.txt se schimbă ulterior, nu se vor instala noile dependențe.
    else
        echo "Node '${dir}' not found. Cloning: ${repo} to ${path} (--recursive)..."
        git clone "${repo}" "${path}" --recursive
        WAS_CLONED_NOW=true # Nodul a fost clonat, deci colectăm cerințele
    fi

    # Colectează cerințele doar dacă nodul a fost clonat acum (instalare inițială)
    if $WAS_CLONED_NOW && [[ -e "$requirements" ]]; then
        echo "Collecting requirements from ${dir} (initial clone)..."
        cat "$requirements" >> "$TEMP_REQUIREMENTS_FILE"
    fi
done

# Instalează toate cerințele consolidate O SINGURĂ DATĂ (doar cele colectate din nodurile recent clonate)
if [[ -s "$TEMP_REQUIREMENTS_FILE" ]]; then
    echo "Installing consolidated requirements for newly cloned custom nodes..."
    pip install --no-cache-dir -r "$TEMP_REQUIREMENTS_FILE"
    if [ $? -ne 0 ]; then
        echo "Warning: Failed to install consolidated requirements for newly cloned custom nodes."
    fi
else
    echo "No new custom nodes cloned or no requirements files found for them."
fi

echo "install_nodes.sh completed."
