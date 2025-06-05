#!/bin/bash

# This file will be sourced in init.sh


# Packages are installed after nodes so we can fix them...

DEFAULT_WORKFLOW="https://raw.githubusercontent.com/LucianGnn/runpod-inits/refs/heads/main/FantasyTalking%20orig.json"

APT_PACKAGES=(
    "aria2"
    #"package-2"
)

PIP_PACKAGES=(
    "huggingface_hub
    #"package-2"
)

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

WORKFLOWS=(
	""
)

CHECKPOINT_MODELS=(
	""
)

UNET_MODELS=(
	""

)

DIFFUSION_MODELS=(
  "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1-I2V-14B-720P_fp8_e4m3fn.safetensors"
  "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/fantasytalking_fp16.safetensors"

)

CLIP_VISION=(
    "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors"
)

CLIP=(
  ""
)

TEXTENCODERS_MODELS=(
    "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/umt5-xxl-enc-bf16.safetensors"
)

LORA_MODELS=(
	""
)

VAE_MODELS=(
    "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1_VAE_bf16.safetensors"
)

ESRGAN_MODELS=(
    ""
)

CONTROLNET_MODELS=(
	""
)

### DO NOT EDIT BELOW HERE UNLESS YOU KNOW WHAT YOU ARE DOING ###

function provisioning_start() {
    if [[ ! -d /opt/environments/python ]]; then
        export MAMBA_BASE=true
    fi
    source /opt/ai-dock/etc/environment.sh
    source /opt/ai-dock/bin/venv-set.sh comfyui

    provisioning_print_header
    provisioning_get_apt_packages
    provisioning_get_nodes
    provisioning_get_pip_packages
    provisioning_get_models \
        "${WORKSPACE}/ComfyUI/models/ckpt" \
        "${CHECKPOINT_MODELS[@]}"
    provisioning_get_models \
        "${WORKSPACE}/ComfyUI/models/unet" \
        "${UNET_MODELS[@]}"
    provisioning_get_models \
        "${WORKSPACE}/ComfyUI/models/diffusion_models" \
        "${DIFFUSION_MODELS[@]}"
    provisioning_get_models \
        "${WORKSPACE}/ComfyUI/models/clip_vision" \
        "${CLIP_VISION[@]}"
    provisioning_get_models \
        "${WORKSPACE}/ComfyUI/models/clip" \
        "${CLIP[@]}"
    provisioning_get_models \
        "${WORKSPACE}/ComfyUI/models/text_encoders" \
        "${TEXTENCODERS_MODELS[@]}"
    provisioning_get_models \
        "${WORKSPACE}/ComfyUI/models/loras" \
        "${LORA_MODELS[@]}"
    provisioning_get_models \
        "${WORKSPACE}/ComfyUI/models/controlnet" \
        "${CONTROLNET_MODELS[@]}"
    provisioning_get_models \
        "${WORKSPACE}/ComfyUI/models/vae" \
        "${VAE_MODELS[@]}"
    provisioning_get_models \
        "${WORKSPACE}/ComfyUI/models/esrgan" \
        "${ESRGAN_MODELS[@]}"
    provisioning_get_workflows
    provisioning_print_end
}

function pip_install() {
    if [[ -z $MAMBA_BASE ]]; then
            "$COMFYUI_VENV_PIP" install --no-cache-dir "$@"
        else
            micromamba run -n comfyui pip install --no-cache-dir "$@"
        fi
}

function provisioning_get_apt_packages() {
    if [[ -n $APT_PACKAGES ]]; then
            sudo $APT_INSTALL ${APT_PACKAGES[@]}
    fi
}

function provisioning_get_pip_packages() {
    if [[ -n $PIP_PACKAGES ]]; then
            pip_install ${PIP_PACKAGES[@]}
    fi
}

function provisioning_get_nodes() {
    for repo in "${NODES[@]}"; do
        dir="${repo##*/}"
        path="/opt/ComfyUI/custom_nodes/${dir}"
        requirements="${path}/requirements.txt"
        if [[ -d $path ]]; then
            if [[ ${AUTO_UPDATE,,} != "false" ]]; then
                printf "Updating node: %s...\n" "${repo}"
                ( cd "$path" && git pull )
                if [[ -e $requirements ]]; then
                   pip_install -r "$requirements"
                fi
            fi
        else
            printf "Downloading node: %s...\n" "${repo}"
            git clone "${repo}" "${path}" --recursive
            if [[ -e $requirements ]]; then
                pip_install -r "${requirements}"
            fi
        fi
    done
}

function provisioning_get_workflows() {
    for repo in "${WORKFLOWS[@]}"; do
        dir=$(basename "$repo" .git)
        path="/opt/ComfyUI/user/default/workflows/${dir}"
        if [[ -d "$path" ]]; then
            if [[ ${AUTO_UPDATE,,} != "false" ]]; then
                printf "Updating workflows: %s...\n" "${repo}"
                ( cd "$path" && git pull )
            fi
        else
            printf "Cloning workflows: %s...\n" "${repo}"
            git clone "$repo" "$path"
        fi
    done
}

function provisioning_get_default_workflow() {
    if [[ -n $DEFAULT_WORKFLOW ]]; then
        workflow_json=$(curl -s "$DEFAULT_WORKFLOW")
        if [[ -n $workflow_json ]]; then
            echo "export const defaultGraph = $workflow_json;" > /opt/ComfyUI/web/scripts/defaultGraph.js
        fi
    fi
}

function provisioning_get_models() {
    if [[ -z $2 ]]; then return 1; fi

    dir="$1"
    mkdir -p "$dir"
    shift
    arr=("$@")
    printf "Downloading %s model(s) to %s...\n" "${#arr[@]}" "$dir"
    for url in "${arr[@]}"; do
        printf "Downloading: %s\n" "${url}"
        provisioning_download "${url}" "${dir}"
        printf "\n"
    done
}

function provisioning_print_header() {
    printf "\n##############################################\n#                                            #\n#          Provisioning container            #\n#                                            #\n#         This will take some time           #\n#                                            #\n# Your container will be ready on completion #\n#                                            #\n##############################################\n\n"
    if [[ $DISK_GB_ALLOCATED -lt $DISK_GB_REQUIRED ]]; then
        printf "WARNING: Your allocated disk size (%sGB) is below the recommended %sGB - Some models will not be downloaded\n" "$DISK_GB_ALLOCATED" "$DISK_GB_REQUIRED"
    fi
}

function provisioning_print_end() {
    printf "\nProvisioning complete:  Web UI will start now\n\n"
}

function provisioning_has_valid_hf_token() {
    [[ -n "$HF_TOKEN" ]] || return 1
    url="https://huggingface.co/api/whoami-v2"

    response=$(curl -o /dev/null -s -w "%{http_code}" -X GET "$url" \
        -H "Authorization: Bearer $HF_TOKEN" \
        -H "Content-Type: application/json")

    # Check if the token is valid
    if [ "$response" -eq 200 ]; then
        return 0
    else
        return 1
    fi
}

function provisioning_has_valid_civitai_token() {
    [[ -n "$CIVITAI_TOKEN" ]] || return 1
    url="https://civitai.com/api/v1/models?hidden=1&limit=1"

    response=$(curl -o /dev/null -s -w "%{http_code}" -X GET "$url" \
        -H "Authorization: Bearer $CIVITAI_TOKEN" \
        -H "Content-Type: application/json")

    # Check if the token is valid
    if [ "$response" -eq 200 ]; then
        return 0
    else
        return 1
    fi
}

# Download from $1 URL to $2 file path
function provisioning_download() {
    if [[ -z $2 ]]; then return 1; fi # Asigură-te că directorul de destinație este specificat

    local url="$1"
    local dest_dir="$2"
    local filename=$(basename "$url" | sed 's/\?.*//') # Extrage numele fisierului din URL, elimina parametrii de query
                                                        # Ex: url.com/file.safetensors?token=... -> file.safetensors
    local auth_header="" # Variabilă pentru antetul de autorizare

    # Verifică dacă URL-ul necesită un token și construiește antetul de autorizare
    if [[ -n "$HF_TOKEN" && "$url" =~ ^https://([a-zA-Z0-9_-]+\.)?huggingface\.co(/|$|\?) ]]; then
        auth_header="Authorization: Bearer $HF_TOKEN"
    elif [[ -n "$CIVITAI_TOKEN" && "$url" =~ ^https://([a-zA-Z0-9_-]+\.)?civitai\.com(/|$|\?) ]]; then
        auth_header="Authorization: Bearer $CIVITAI_TOKEN"
    fi

    echo "Descarc: ${filename} (de la ${url}) în ${dest_dir}"

    # Construiește comanda aria2c
    local aria2c_cmd=(
        aria2c
        --continue                     # -c, continuă descărcarea fișierelor existente
        --max-concurrent-downloads=5   # Câte descărcări simultane, ajustați după nevoie
        --max-connection-per-server=16 # -x, numărul maxim de conexiuni la un server
        --split=16                     # -s, numărul de părți în care să împartă fișierul
        --dir="${dest_dir}"            # -d, directorul de destinație
        --out="${filename}"            # -o, numele fișierului de ieșire
        --console-log-level=warn       # Reduce zgomotul din log, afișează doar avertismente
        --summary-interval=0           # Afișează sumarul descărcării la final
    )

    # Adaugă antetul de autorizare dacă este necesar
    if [[ -n "$auth_header" ]]; then
        aria2c_cmd+=( --header="$auth_header" )
    fi

    # Adaugă URL-ul final la comandă
    aria2c_cmd+=("$url")

    # Execută comanda
    "${aria2c_cmd[@]}"

    # Verifică dacă descărcarea a fost un succes
    if [ $? -eq 0 ]; then
        echo "Descărcare completă pentru ${filename}."
    else
        echo "Eroare la descărcarea ${filename}." >&2
        return 1 # Returnează cod de eroare
    fi
}

provisioning_start
