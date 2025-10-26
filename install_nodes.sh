#!/bin/bash

echo "Starting install_nodes.sh..."

# --- Secțiune: Verificarea și Activarea Mediului Virtual ComfyUI ---
source /workspace/ComfyUI/venv/bin/activate
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to activate ComfyUI venv. Exiting install_nodes.sh."
    exit 1
fi
echo "ComfyUI venv activated."

# Install APT packages
echo "Installing APT packages..."
apt-get update

# Verificare și instalare aria2
if ! command -v aria2c &> /dev/null; then
    echo "aria2c not found, installing..."
    apt-get -y install aria2
    hash -r # Refresh command hash table
else
    echo "aria2c is already installed."
fi

# Define PIP packages (pachete PIP globale, nu specifice nodurilor)
PIP_PACKAGES=(
    "huggingface_hub"
    "gitpython"  # Useful for git operations
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
    "https://github.com/rgthree/rgthree-comfy"
    "https://github.com/kk8bit/KayTool"
    #"https://github.com/XLabs-AI/x-flux-comfyui"
    #"https://github.com/kijai/ComfyUI-WanVideoWrapper"
    #"https://github.com/Lightricks/ComfyUI-LTXVideo"
    #"https://github.com/kijai/ComfyUI-KJNodes"
    #"https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite"
    #"https://github.com/justUmen/Bjornulf_custom_nodes"
    #"https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes"
    #"https://github.com/christian-byrne/audio-separation-nodes-comfyui"
    #"https://github.com/MinorBoy/ComfyUI_essentials_mb"
)

# Create custom_nodes directory if it doesn't exist
mkdir -p "/workspace/ComfyUI/custom_nodes"

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
        cd "$path"
        
        # Get current branch name
        current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
        
        # Try to pull from current branch first, then fallback to main/master
        if [[ "$current_branch" != "HEAD" && -n "$current_branch" ]]; then
            git pull origin "$current_branch" 2>/dev/null || \
            git pull origin main 2>/dev/null || \
            git pull origin master 2>/dev/null || \
            echo "Warning: git pull failed for node '${dir}'. Branch might be detached or protected."
        else
            git pull origin main 2>/dev/null || \
            git pull origin master 2>/dev/null || \
            echo "Warning: git pull failed for node '${dir}'. Repository might be in detached HEAD state."
        fi
        
        cd - > /dev/null  # Return to previous directory silently
    else
        echo "Node '${dir}' not found. Cloning: ${repo} to ${path} (--recursive)..."
        if git clone "${repo}" "${path}" --recursive; then
            WAS_CLONED_NOW=true # Nodul a fost clonat, deci colectăm cerințele
            echo "Successfully cloned ${dir}"
        else
            echo "Warning: Failed to clone ${dir} from ${repo}"
            continue
        fi
    fi

    # Colectează cerințele doar dacă nodul a fost clonat acum (instalare inițială)
    if $WAS_CLONED_NOW && [[ -e "$requirements" ]]; then
        echo "Collecting requirements from ${dir} (initial clone)..."
        cat "$requirements" >> "$TEMP_REQUIREMENTS_FILE"
    fi
done

# Remove duplicate requirements and clean up the file
if [[ -s "$TEMP_REQUIREMENTS_FILE" ]]; then
    echo "Processing consolidated requirements..."
    # Remove duplicates, empty lines, and comments
    sort "$TEMP_REQUIREMENTS_FILE" | uniq | grep -v '^#' | grep -v '^$' > "${TEMP_REQUIREMENTS_FILE}.clean"
    mv "${TEMP_REQUIREMENTS_FILE}.clean" "$TEMP_REQUIREMENTS_FILE"
fi

# Instalează toate cerințele consolidate O SINGURĂ DATĂ (doar cele colectate din nodurile recent clonate)
if [[ -s "$TEMP_REQUIREMENTS_FILE" ]]; then
    echo "Installing consolidated requirements for newly cloned custom nodes..."
    echo "Requirements to install:"
    cat "$TEMP_REQUIREMENTS_FILE"
    
    pip install --no-cache-dir -r "$TEMP_REQUIREMENTS_FILE"
    if [ $? -eq 0 ]; then
        echo "Successfully installed all requirements."
    else
        echo "Warning: Some requirements failed to install. This might not affect functionality."
    fi
    
    # Clean up temp file
    rm -f "$TEMP_REQUIREMENTS_FILE"
else
    echo "No new custom nodes cloned or no requirements files found for them."
fi

echo "install_nodes.sh completed successfully."
