#!/bin/bash
# install_lab_deps.sh - Install dependencies for the SSH Brute-Force & Botnet Lab on Kali Linux
# Usage: bash install_lab_deps.sh
# Must be run with sudo for system package installation, but podman rootless setup is done for the current user.

set -e  # Exit on any error
trap 'echo "[ERROR] Script failed at line $LINENO. Check output above."' ERR

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if running as root (required for package installation)
if [ "$EUID" -ne 0 ]; then
    log_error "Please run as root (use sudo)."
    exit 1
fi

# Determine the non-root user (the one who called sudo)
if [ -n "$SUDO_USER" ]; then
    USER_HOME=$(eval echo ~$SUDO_USER)
    REAL_USER=$SUDO_USER
else
    log_error "Cannot determine original user. Run with sudo."
    exit 1
fi

log_info "Installing system packages for Kali Linux..."

# Update package lists
apt update -y

# Install core packages: podman, podman-compose, python3, pip, git, network tools, ssh client
apt install -y \
    podman \
    podman-compose \
    python3 \
    python3-pip \
    python3-venv \
    git \
    openssh-client \
    netcat-openbsd \
    tcpdump \
    iptables \
    dnsutils \
    curl \
    vim \
    htop

# Verify podman installation
if ! command -v podman &> /dev/null; then
    log_error "podman not found after installation. Check apt."
    exit 1
fi
log_info "podman version: $(podman --version)"

# Install podman-compose (may be already installed, but ensure it's available)
if ! command -v podman-compose &> /dev/null; then
    log_warn "podman-compose not in PATH, trying to install via pip"
    pip3 install podman-compose
    # Add ~/.local/bin to PATH for current user
    export PATH="$USER_HOME/.local/bin:$PATH"
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$USER_HOME/.bashrc"
fi
log_info "podman-compose version: $(podman-compose --version 2>/dev/null || echo 'unknown')"

# Install Python dependencies for the lab (paramiko)
log_info "Installing Python package: paramiko"
pip3 install --upgrade paramiko

# Optionally install additional packages that might be used in analysis
pip3 install --upgrade pandas  # not required but useful for log analysis

# Check if the lab repository already exists in the user's home directory
LAB_DIR="$USER_HOME/Documents/ssh-botnet-lab"
if [ ! -d "$LAB_DIR" ]; then
    log_info "Lab directory not found. Cloning repository from GitHub (assuming it's hosted)..."
    # Replace with actual repository URL if different
    REPO_URL="https://github.com/your-org/ssh-botnet-lab.git"
    sudo -u "$REAL_USER" mkdir -p "$USER_HOME/Documents"
    sudo -u "$REAL_USER" git clone "$REPO_URL" "$LAB_DIR" || {
        log_warn "Git clone failed. Please manually place the lab files in $LAB_DIR"
    }
else
    log_info "Lab directory already exists at $LAB_DIR"
fi

# Ensure the setup.sh script is executable
if [ -f "$LAB_DIR/setup.sh" ]; then
    chmod +x "$LAB_DIR/setup.sh"
    log_info "setup.sh is now executable"
else
    log_warn "setup.sh not found in $LAB_DIR. The lab may be incomplete."
fi

# Set up podman rootless environment for the non-root user
log_info "Configuring rootless podman for user $REAL_USER"
sudo -u "$REAL_USER" podman system migrate 2>/dev/null || true

# Create a simple alias for podman compose to podman-compose (optional)
sudo -u "$REAL_USER" bash -c "grep -q 'alias podman-compose' $USER_HOME/.bashrc || echo 'alias podman-compose=\"podman-compose\"' >> $USER_HOME/.bashrc"

# Final checks
log_info "Verifying critical components:"
python3 -c "import paramiko; print('  paramiko version:', paramiko.__version__)" || log_error "paramiko import failed"
sudo -u "$REAL_USER" podman ps &>/dev/null && log_info "  podman rootless works" || log_warn "  podman rootless may need additional setup (run 'podman system migrate')"

log_info "All dependencies installed successfully."
log_info "Next steps:"
echo "  1. Log out and back in (or source ~/.bashrc) to ensure PATH updates."
echo "  2. Navigate to the lab directory: cd $LAB_DIR"
echo "  3. Run the setup script: ./setup.sh"
echo "  4. Follow the lab guide to start containers."
exit 0
