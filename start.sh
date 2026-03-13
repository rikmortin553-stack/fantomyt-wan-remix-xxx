#!/bin/bash
set -euo pipefail

source /opt/venv/bin/activate

WORKSPACE_DIR="/workspace"
COMFY_IMAGE_DIR="/comfy-build"
COMFY_RUNTIME_DIR="${WORKSPACE_DIR}/ComfyUI"
CUSTOM_NODES_DIR="${COMFY_RUNTIME_DIR}/custom_nodes"
MODELS_DIR="${COMFY_RUNTIME_DIR}/models"

echo "=== Preparing workspace ==="
mkdir -p "${WORKSPACE_DIR}" \
         "${WORKSPACE_DIR}/models" \
         "${WORKSPACE_DIR}/input" \
         "${WORKSPACE_DIR}/output" \
         "${WORKSPACE_DIR}/temp" \
         "${WORKSPACE_DIR}/.cache/huggingface"
chmod -R 777 "${WORKSPACE_DIR}" || true

echo "=== Restoring ComfyUI to workspace if needed ==="
if [ ! -d "${COMFY_RUNTIME_DIR}" ]; then
  cp -a "${COMFY_IMAGE_DIR}" "${COMFY_RUNTIME_DIR}"
fi
chmod -R 777 "${COMFY_RUNTIME_DIR}" || true

cd "${COMFY_RUNTIME_DIR}"

echo "=== Runtime environment fixes ==="
pip install --upgrade "setuptools<81" wheel packaging

safe_install_requirements() {
  local req_file="$1"
  local filtered_req
  filtered_req="$(mktemp)"

  # Protect the Blackwell-critical stack and skip noisy/problematic packages
  grep -viE '^[[:space:]]*(torch|torchvision|torchaudio|xformers|triton|sageattention|cupy([_-].*)?|bitsandbytes)([[:space:]=<>!~].*)?$' "${req_file}" > "${filtered_req}" || true

  if [ -s "${filtered_req}" ]; then
    pip install -r "${filtered_req}" || true
  fi

  rm -f "${filtered_req}"
}

clone_custom_node() {
  local repo_url="$1"
  local dir_name="$2"
  local git_ref="${3:-}"
  local install_requirements="${4:-yes}"

  local target_dir="${CUSTOM_NODES_DIR}/${dir_name}"

  if [ ! -d "${target_dir}/.git" ]; then
    echo "=== Cloning ${dir_name} ==="
    git clone --recursive "${repo_url}" "${target_dir}"
  else
    echo "=== Updating ${dir_name} ==="
    git -C "${target_dir}" fetch --all --tags --prune || true
  fi

  if [ -f "${target_dir}/.gitmodules" ]; then
    git -C "${target_dir}" submodule update --init --recursive || true
  fi

  if [ -n "${git_ref}" ]; then
    git -C "${target_dir}" checkout "${git_ref}" || true
    git -C "${target_dir}" submodule update --init --recursive || true
  fi

  chmod -R 777 "${target_dir}" || true

  if [ "${install_requirements}" = "yes" ] && [ -f "${target_dir}/requirements.txt" ]; then
    echo "=== Installing requirements for ${dir_name} ==="
    safe_install_requirements "${target_dir}/requirements.txt"
  fi
}

echo "=== Installing workflow-derived custom nodes ==="
mkdir -p "${CUSTOM_NODES_DIR}"
chmod -R 777 "${CUSTOM_NODES_DIR}" || true

# Extra quality-of-life node explicitly requested by user
clone_custom_node "https://github.com/Comfy-Org/ComfyUI-Manager.git" "ComfyUI-Manager"

# Derived from workflow.json
clone_custom_node "https://github.com/kijai/ComfyUI-WanVideoWrapper.git" "ComfyUI-WanVideoWrapper" "d9b1f4d1a5aea91d101ae97a54714a5861af3f50"
clone_custom_node "https://github.com/kijai/ComfyUI-KJNodes.git" "ComfyUI-KJNodes" "a6b867b63a29ca48ddb15c589e17a9f2d8530d57"
clone_custom_node "https://github.com/Fannovel16/ComfyUI-Frame-Interpolation.git" "ComfyUI-Frame-Interpolation"
clone_custom_node "https://github.com/pythongosssss/ComfyUI-Custom-Scripts.git" "ComfyUI-Custom-Scripts"

# Easy-Use: requirements only, no install.py, to avoid cupy-wheel/pkg_resources noise
clone_custom_node "https://github.com/yolain/ComfyUI-Easy-Use.git" "ComfyUI-Easy-Use"

echo "=== Re-pinning Blackwell-critical stack after custom node installs ==="
pip install --upgrade "setuptools<81" wheel packaging
pip install --pre --upgrade torch torchvision torchaudio --index-url https://download.pytorch.org/whl/nightly/cu128
pip install --upgrade xformers
pip uninstall -y sageattention || true
pip install --no-cache-dir --force-reinstall sageattention || true

echo "=== Creating model directories ==="
mkdir -p "${MODELS_DIR}/checkpoints" \
         "${MODELS_DIR}/clip" \
         "${MODELS_DIR}/clip_vision" \
         "${MODELS_DIR}/diffusion_models" \
         "${MODELS_DIR}/loras" \
         "${MODELS_DIR}/rife" \
         "${MODELS_DIR}/frame_interpolation" \
         "${MODELS_DIR}/text_encoders" \
         "${MODELS_DIR}/vae"
chmod -R 777 "${MODELS_DIR}" || true

download_file() {
  local url="$1"
  local dest_dir="$2"
  local filename="$3"
  local output_file="${dest_dir}/${filename}"

  mkdir -p "${dest_dir}"

  if [ -s "${output_file}" ]; then
    echo "=== Skipping existing file: ${output_file} ==="
    return 0
  fi

  echo "=== Downloading ${filename} ==="

  local -a extra_args=()
  if [[ "${url}" == *"huggingface.co"* ]] && [ -n "${HF_TOKEN:-}" ]; then
    extra_args+=(--header="Authorization: Bearer ${HF_TOKEN}")
  fi

  aria2c \
    --allow-overwrite=true \
    --auto-file-renaming=false \
    --continue=true \
    --max-connection-per-server=16 \
    --split=16 \
    --min-split-size=1M \
    --file-allocation=none \
    "${extra_args[@]}" \
    -d "${dest_dir}" \
    -o "${filename}" \
    "${url}"

  if [ ! -s "${output_file}" ]; then
    echo "ERROR: download failed or produced an empty file: ${output_file}" >&2
    exit 1
  fi

  chmod 666 "${output_file}" || true
}

echo "=== Downloading workflow-required models ==="
download_file "https://huggingface.co/FX-FeiHou/wan2.2-Remix/resolve/main/NSFW/Wan2.2_Remix_NSFW_i2v_14b_high_lighting_v2.0.safetensors?download=true" \
  "${MODELS_DIR}/diffusion_models" \
  "Wan2.2_Remix_NSFW_i2v_14b_high_lighting_v2.0.safetensors"

download_file "https://huggingface.co/FX-FeiHou/wan2.2-Remix/resolve/main/NSFW/Wan2.2_Remix_NSFW_i2v_14b_low_lighting_v2.0.safetensors?download=true" \
  "${MODELS_DIR}/diffusion_models" \
  "Wan2.2_Remix_NSFW_i2v_14b_low_lighting_v2.0.safetensors"

download_file "https://huggingface.co/NSFW-API/NSFW-Wan-UMT5-XXL/resolve/main/nsfw_wan_umt5-xxl_fp8_scaled.safetensors?download=true" \
  "${MODELS_DIR}/clip" \
  "nsfw_wan_umt5-xxl_fp8_scaled.safetensors"

download_file "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors?download=true" \
  "${MODELS_DIR}/vae" \
  "wan_2.1_vae.safetensors"

download_file "https://huggingface.co/Kijai/WanVideo_comfy/resolve/d4c3006fda29c47a51d07b7ea77495642cf9359f/Wan22-Lightning/Wan2.2-Lightning_I2V-A14B-4steps-lora_HIGH_fp16.safetensors?download=true" \
  "${MODELS_DIR}/loras" \
  "Wan2.2-Lightning_I2V-A14B-4steps-lora_HIGH_fp16.safetensors"

download_file "https://huggingface.co/Kijai/WanVideo_comfy/resolve/d45e290d88d212a8e78f8f45584a21a0f0e2457b/Wan22-Lightning/Wan2.2-Lightning_I2V-A14B-4steps-lora_LOW_fp16.safetensors?download=true" \
  "${MODELS_DIR}/loras" \
  "Wan2.2-Lightning_I2V-A14B-4steps-lora_LOW_fp16.safetensors"

download_file "https://huggingface.co/wavespeed/misc/resolve/main/rife/rife47.pth?download=true" \
  "${MODELS_DIR}/rife" \
  "rife47.pth"

ln -sf "${MODELS_DIR}/rife/rife47.pth" "${MODELS_DIR}/frame_interpolation/rife47.pth" || true

if [ ! -f "${WORKSPACE_DIR}/input/elaradreamcore_0008.jpeg" ]; then
  echo "WARNING: ${WORKSPACE_DIR}/input/elaradreamcore_0008.jpeg is not present."
  echo "Update the LoadImage node in the workflow, or place the file there before queueing the workflow."
fi

echo "=== Starting JupyterLab ==="
jupyter lab \
  --ip=0.0.0.0 \
  --port=8888 \
  --no-browser \
  --allow-root \
  --ServerApp.token='' \
  --ServerApp.password='' \
  --ServerApp.allow_origin='*' \
  --ServerApp.disable_check_xsrf=True \
  --ServerApp.root_dir="${WORKSPACE_DIR}" \
  > "${WORKSPACE_DIR}/jupyter.log" 2>&1 &

sleep 5
if pgrep -f "jupyter-lab.*8888" >/dev/null; then
  echo "=== JupyterLab is running on port 8888 ==="
else
  echo "WARNING: JupyterLab did not confirm startup. Last log lines:"
  tail -n 50 "${WORKSPACE_DIR}/jupyter.log" || true
fi

echo "=== Starting ComfyUI ==="
python main.py --listen 0.0.0.0 --port 3000 --disable-auto-launch
