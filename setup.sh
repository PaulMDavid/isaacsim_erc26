# ==============================================================
# setup.sh — Isaac Sim 4.5.0 + ROS2 Humble venv installer
# Ubuntu 22.04 | Python 3.10 | RTX 30xx/40xx | CUDA 12.x
#
# Usage:
#   chmod +x setup.sh && ./setup.sh
#
# What this does:
#   1. Checks system prerequisites (GPU driver, CUDA, Python 3.10, ROS2 Humble)
#   2. Creates a Python 3.10 venv (skips if already exists)
#   3. Installs PyTorch (CUDA 12.1 build)
#   4. Installs Isaac Sim 4.5.0 from NVIDIA PyPI (skips if already installed)
#   5. Installs requirements.txt extras
#   6. Writes an activation helper script
# ==============================================================

set -euo pipefail

# ── Colours ────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*"; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; }

# ── Config ─────────────────────────────────────────────────────
VENV_DIR="${VENV_DIR:-$(pwd)/.venv}"
ISAACSIM_VERSION="4.5.0"
PYTHON_BIN="python3.10"
TORCH_VERSION="2.5.1"
TORCHVISION_VERSION="0.20.1"
TORCH_INDEX="https://download.pytorch.org/whl/cu121"
NVIDIA_PYPI="https://pypi.nvidia.com"
MIN_DRIVER_VERSION=525   # minimum NVIDIA driver for Isaac Sim 4.5 on RTX 30/40

# ── 1. System prerequisite checks ──────────────────────────────
header "Checking system prerequisites"

# Python 3.10
if ! command -v "$PYTHON_BIN" &>/dev/null; then
    warn "python3.10 not found. Attempting to install via apt..."
    sudo apt-get update -qq
    sudo apt-get install -y python3.10 python3.10-venv python3.10-dev || \
        error "Could not install python3.10. Install it manually: sudo apt install python3.10 python3.10-venv"
fi
PYTHON_FULL=$("$PYTHON_BIN" --version 2>&1)
ok "Found $PYTHON_FULL"

# NVIDIA GPU driver
if ! command -v nvidia-smi &>/dev/null; then
    error "nvidia-smi not found. Install NVIDIA drivers >= $MIN_DRIVER_VERSION before proceeding."
fi
DRIVER_VERSION=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1 | cut -d'.' -f1)
if [[ "$DRIVER_VERSION" -lt "$MIN_DRIVER_VERSION" ]]; then
    error "NVIDIA driver $DRIVER_VERSION is too old. Isaac Sim 4.5 requires >= $MIN_DRIVER_VERSION. Please update."
fi
GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
ok "GPU: $GPU_NAME | Driver: $DRIVER_VERSION"

# CUDA toolkit (optional but warn if missing)
if command -v nvcc &>/dev/null; then
    CUDA_VER=$(nvcc --version | grep -oP 'release \K[0-9]+\.[0-9]+')
    ok "CUDA toolkit: $CUDA_VER"
    if [[ $(echo "$CUDA_VER < 11.8" | bc -l) -eq 1 ]]; then
        warn "CUDA $CUDA_VER is old. CUDA 12.x recommended for best RTX 30/40 performance."
    fi
else
    warn "nvcc not found — CUDA toolkit may not be installed. Isaac Sim can still run via bundled CUDA, but torch install needs cu121 wheels."
fi

# ROS2 Humble check
if [[ -f /opt/ros/humble/setup.bash ]]; then
    ok "ROS2 Humble found at /opt/ros/humble"
else
    warn "ROS2 Humble NOT found at /opt/ros/humble."
    warn "Install it before using the ROS2 bridge:"
    warn "  https://docs.ros.org/en/humble/Installation/Ubuntu-Install-Debians.html"
    warn "Continuing anyway — Isaac Sim itself does not require ROS2 at install time."
fi

# ── 2. Create venv ─────────────────────────────────────────────
header "Setting up Python venv: $VENV_DIR"

if [[ -d "$VENV_DIR" && -f "$VENV_DIR/bin/activate" ]]; then
    ok "venv already exists at $VENV_DIR — skipping creation."
else
    info "Creating venv with $PYTHON_BIN..."
    "$PYTHON_BIN" -m venv "$VENV_DIR"
    ok "venv created."
fi

# Activate
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
ok "venv activated."

# Upgrade pip
info "Upgrading pip..."
pip install --quiet --upgrade pip

# ── 3. PyTorch ─────────────────────────────────────────────────
header "Installing PyTorch $TORCH_VERSION (CUDA 12.1 build)"

if python -c "import torch; assert torch.__version__.startswith('${TORCH_VERSION}')" 2>/dev/null; then
    ok "PyTorch $TORCH_VERSION already installed — skipping."
else
    info "Installing torch==$TORCH_VERSION torchvision==$TORCHVISION_VERSION from $TORCH_INDEX ..."
    pip install --quiet \
        "torch==$TORCH_VERSION" \
        "torchvision==$TORCHVISION_VERSION" \
        --index-url "$TORCH_INDEX"
    ok "PyTorch installed."
fi

# ── 4. Isaac Sim 4.5.0 ─────────────────────────────────────────
header "Installing Isaac Sim $ISAACSIM_VERSION"

if python -c "import isaacsim; print(isaacsim.__version__)" 2>/dev/null | grep -q "$ISAACSIM_VERSION"; then
    ok "Isaac Sim $ISAACSIM_VERSION already installed — skipping."
else
    info "Installing isaacsim[all,extscache]==$ISAACSIM_VERSION from $NVIDIA_PYPI ..."
    info "(This is large — ~10 GB download. Go make a coffee.)"
    pip install --quiet \
        "isaacsim[all,extscache]==$ISAACSIM_VERSION" \
        --extra-index-url "$NVIDIA_PYPI"
    ok "Isaac Sim installed."
fi

# ── 5. requirements.txt ────────────────────────────────────────
header "Installing requirements.txt"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQUIREMENTS="$SCRIPT_DIR/requirements.txt"

if [[ ! -f "$REQUIREMENTS" ]]; then
    warn "requirements.txt not found at $REQUIREMENTS — skipping extra packages."
else
    info "Installing from $REQUIREMENTS ..."
    # Skip lines that are comments or the isaacsim entry (handled above)
    grep -v '^\s*#' "$REQUIREMENTS" \
        | grep -v '^\s*$' \
        | grep -v '^isaacsim' \
        | grep -v '^torch' \
        | grep -v '^torchvision' \
        | xargs -r pip install --quiet
    ok "requirements.txt packages installed."
fi

# ── 6. Activation helper ───────────────────────────────────────
header "Writing activation helper"

ACTIVATE_SCRIPT="$SCRIPT_DIR/activate_env.sh"
cat > "$ACTIVATE_SCRIPT" << EOF
#!/usr/bin/env bash
# Activate the Isaac Sim venv and optionally source ROS2 Humble.
# Usage: source activate_env.sh

VENV_DIR="\${VENV_DIR:-$(pwd)/.venv}"

# Source venv
source "\$VENV_DIR/bin/activate"

# Source ROS2 Humble if available (needed for ros2 bridge at runtime)
if [[ -f /opt/ros/humble/setup.bash ]]; then
    source /opt/ros/humble/setup.bash
    echo "[OK] ROS2 Humble sourced."
else
    echo "[WARN] ROS2 Humble not found — bridge won't work without it."
fi

echo "[OK] Isaac Sim venv active. Python: \$(python --version)"
echo "     Run: isaacsim isaacsim.exp.full.kit"
EOF
chmod +x "$ACTIVATE_SCRIPT"
ok "Activation helper written to $ACTIVATE_SCRIPT"

# ── Done ───────────────────────────────────────────────────────
echo -e "\n${GREEN}${BOLD}✓ Setup complete!${RESET}"
echo ""
echo -e "  Activate environment:   ${CYAN}source activate_env.sh${RESET}"
echo -e "  Run Isaac Sim headless: ${CYAN}isaacsim isaacsim.exp.full.kit${RESET}"
echo -e "  Run with GUI:           ${CYAN}isaacsim isaacsim.exp.full.kit --no-window false${RESET}"
echo ""
echo -e "  ${YELLOW}NOTE: First launch downloads Omniverse extensions (~10 min). Normal.${RESET}"
echo ""
