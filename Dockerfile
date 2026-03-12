# RTX 5090 / Blackwell / Wan 2.2 I2V minimal image
FROM nvidia/cuda:12.8.0-cudnn-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    CUDA_HOME=/usr/local/cuda \
    FORCE_CUDA=1 \
    TORCH_CUDA_ARCH_LIST="12.0" \
    HF_HOME="/workspace/.cache/huggingface" \
    PATH="/opt/venv/bin:$PATH"

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.11 python3.11-venv python3-pip \
    git git-lfs wget curl aria2 ffmpeg ca-certificates \
    build-essential ninja-build pkg-config \
    libgl1 libglib2.0-0 libsm6 libxext6 libxrender1 libgomp1 \
    && git lfs install \
    && rm -rf /var/lib/apt/lists/*

RUN python3.11 -m venv /opt/venv && \
    /opt/venv/bin/pip install --upgrade pip setuptools wheel

# Blackwell-safe torch branch
RUN pip install --pre torch torchvision torchaudio --index-url https://download.pytorch.org/whl/nightly/cu128

# Core runtime helpers
RUN pip install \
    xformers \
    sageattention \
    jupyterlab \
    notebook \
    huggingface_hub \
    hf_transfer \
    safetensors

# Pre-build ComfyUI into the image and restore it to /workspace at runtime
RUN git clone https://github.com/comfyanonymous/ComfyUI.git /comfy-build && \
    cd /comfy-build && \
    pip install -r requirements.txt

COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 3000 8888
CMD ["/bin/bash", "/start.sh"]
