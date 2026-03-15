#!/bin/bash
set -euo pipefail

source /opt/venv/bin/activate

export WAN_DISABLE_TORCH_COMPILE="${WAN_DISABLE_TORCH_COMPILE:-1}"
export HF_HOME="/workspace/.cache/huggingface"
export HF_HUB_ENABLE_HF_TRANSFER=1
export TRITON_CACHE_DIR="/workspace/.cache/triton"
export TORCHINDUCTOR_CACHE_DIR="/workspace/.cache/torchinductor"
export CUDA_MODULE_LOADING=LAZY

WORKSPACE_DIR="/workspace"
BUILD_DIR="/comfy-build"
CACHE_DIR="/ComfyUI"
RUNTIME_DIR="${WORKSPACE_DIR}/ComfyUI"
CUSTOM_NODES_DIR="${CACHE_DIR}/custom_nodes"
MODELS_DIR="${CACHE_DIR}/models"

echo "=== Preparing workspace ==="
mkdir -p \
  "${WORKSPACE_DIR}" \
  "${WORKSPACE_DIR}/output" \
  "${WORKSPACE_DIR}/input" \
  "${WORKSPACE_DIR}/temp" \
  "${WORKSPACE_DIR}/models" \
  "${WORKSPACE_DIR}/.cache/huggingface" \
  "${WORKSPACE_DIR}/.cache/triton" \
  "${WORKSPACE_DIR}/.cache/torchinductor"
chmod -R 777 "${WORKSPACE_DIR}" || true

echo "=== Runtime environment fixes ==="
pip install --upgrade "setuptools<81" wheel packaging

echo "=== Ensuring image-side cache exists ==="
if [ ! -d "${CACHE_DIR}" ]; then
  cp -a "${BUILD_DIR}" "${CACHE_DIR}"
fi
chmod -R 777 "${CACHE_DIR}" || true

if [ "${FORCE_RESEED:-0}" = "1" ] && [ -d "${RUNTIME_DIR}" ]; then
  echo "=== FORCE_RESEED=1 -> removing existing runtime ComfyUI ==="
  rm -rf "${RUNTIME_DIR}"
fi

safe_install_requirements() {
  local req_file="$1"
  local filtered_req
  filtered_req="$(mktemp)"

  # Protect Blackwell-critical stack and skip noisy/problematic packages
  grep -viE '^[[:space:]]*(torch|torchvision|torchaudio|xformers|triton|sageattention|cupy([_-].*)?|bitsandbytes)([[:space:]=<>!~].*)?$' "${req_file}" > "${filtered_req}" || true

  if [ -s "${filtered_req}" ]; then
    pip install -r "${filtered_req}" || true
  fi

  rm -f "${filtered_req}"
}

clone_or_update_node() {
  local repo_url="$1"
  local dir_name="$2"

  local target_dir="${CUSTOM_NODES_DIR}/${dir_name}"

  if [ ! -d "${target_dir}/.git" ]; then
    echo "=== Cloning ${dir_name} ==="
    git clone --recursive "${repo_url}" "${target_dir}"
  else
    echo "=== Updating ${dir_name} ==="
    git -C "${target_dir}" reset --hard HEAD || true
    git -C "${target_dir}" clean -fd || true
    git -C "${target_dir}" fetch --all --tags --prune || true
    git -C "${target_dir}" pull --rebase || true
  fi

  if [ -f "${target_dir}/.gitmodules" ]; then
    git -C "${target_dir}" submodule update --init --recursive || true
  fi

  chmod -R 777 "${target_dir}" || true

  if [ -f "${target_dir}/requirements.txt" ]; then
    echo "=== Installing requirements for ${dir_name} ==="
    safe_install_requirements "${target_dir}/requirements.txt"
  fi
}

patch_wan_compile_runtime() {
  local file="${CUSTOM_NODES_DIR}/ComfyUI-WanVideoWrapper/nodes_model_loading.py"

  if [ ! -f "${file}" ]; then
    echo "WARNING: WanVideoWrapper file not found for compile patch: ${file}"
    return 0
  fi

  python - "${file}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="ignore")

marker = "WANVIDEO_FORCE_DISABLE_COMPILE"
if marker in text:
    print("=== WanVideo compile patch already present ===")
    raise SystemExit(0)

needle = '        compile_args = {'
if needle not in text:
    print("WARNING: compile_args marker not found in WanVideoWrapper; patch skipped")
    raise SystemExit(0)

patched = text.replace(
    needle,
    '        import os\n'
    '        if os.environ.get("WAN_DISABLE_TORCH_COMPILE", "1") == "1":\n'
    '            # WANVIDEO_FORCE_DISABLE_COMPILE\n'
    '            return (None,)\n\n'
    '        compile_args = {',
    1,
)

path.write_text(patched, encoding="utf-8")
print("=== Patched WanVideoTorchCompileSettings to return None when WAN_DISABLE_TORCH_COMPILE=1 ===")
PY
}

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
  echo "=== Downloaded: ${filename} ==="
}

echo "=== Installing workflow-derived custom nodes into cache ==="
mkdir -p "${CUSTOM_NODES_DIR}"
chmod -R 777 "${CUSTOM_NODES_DIR}" || true

clone_or_update_node "https://github.com/Comfy-Org/ComfyUI-Manager.git" "ComfyUI-Manager"
clone_or_update_node "https://github.com/kijai/ComfyUI-WanVideoWrapper.git" "ComfyUI-WanVideoWrapper"
clone_or_update_node "https://github.com/kijai/ComfyUI-KJNodes.git" "ComfyUI-KJNodes"
clone_or_update_node "https://github.com/pythongosssss/ComfyUI-Custom-Scripts.git" "ComfyUI-Custom-Scripts"
clone_or_update_node "https://github.com/yolain/ComfyUI-Easy-Use.git" "ComfyUI-Easy-Use"
clone_or_update_node "https://github.com/Fannovel16/ComfyUI-Frame-Interpolation.git" "ComfyUI-Frame-Interpolation"

echo "=== Applying WanVideo compile-safety patch ==="
patch_wan_compile_runtime

echo "=== Re-pinning Blackwell-critical stack after custom node installs ==="
pip install --upgrade "setuptools<81" wheel packaging
pip install --pre --upgrade torch torchvision torchaudio --index-url https://download.pytorch.org/whl/nightly/cu128
pip install --upgrade xformers
pip uninstall -y sageattention || true
pip install --no-cache-dir --force-reinstall sageattention || true

echo "=== Creating model directories in cache ==="
mkdir -p \
  "${MODELS_DIR}/checkpoints" \
  "${MODELS_DIR}/clip" \
  "${MODELS_DIR}/text_encoders" \
  "${MODELS_DIR}/clip_vision" \
  "${MODELS_DIR}/diffusion_models" \
  "${MODELS_DIR}/loras" \
  "${MODELS_DIR}/vae" \
  "${MODELS_DIR}/rife" \
  "${MODELS_DIR}/frame_interpolation"
chmod -R 777 "${MODELS_DIR}" || true

echo "=== Downloading workflow-required models into cache ==="
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

echo "=== Syncing cache /ComfyUI -> runtime /workspace/ComfyUI ==="
mkdir -p "${RUNTIME_DIR}"
rsync -a --delete "${CACHE_DIR}/" "${RUNTIME_DIR}/"
chmod -R 777 "${RUNTIME_DIR}" || true

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
cd "${RUNTIME_DIR}"

unset PYTORCH_CUDA_ALLOC_CONF

exec python main.py --listen 0.0.0.0 --port 3000 --highvram --disable-auto-launch
