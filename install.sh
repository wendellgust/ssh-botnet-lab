#!/bin/bash
# =============================================================================
# SSH Botnet Lab — Full Dependency Installer
# Supports: Kali Linux, Ubuntu 22.04/24.04, Debian 11/12
# Run with: chmod +x install.sh && sudo bash install.sh
# =============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}  $1"; }
info() { echo -e "${BLUE}[--]${NC}  $1"; }
warn() { echo -e "${YELLOW}[!!]${NC}  $1"; }
fail() { echo -e "${RED}[ERR]${NC} $1"; exit 1; }
step() { echo -e "\n${CYAN}══ $1 ══${NC}"; }

# Must run as root
[ "$EUID" -ne 0 ] && fail "Run as root: sudo bash install.sh"

# Detect the real user (person who called sudo)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

echo -e "${CYAN}"
cat <<'BANNER'
  ╔═══════════════════════════════════════════════════╗
  ║   SSH Botnet Lab — Full Dependency Installer     ║
  ║   FEUP SSR · Educational Use Only               ║
  ╚═══════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"

# Detect OS
OS_ID=$(grep -oP '(?<=^ID=).+' /etc/os-release 2>/dev/null | tr -d '"' || echo "unknown")
OS_VER=$(grep -oP '(?<=^VERSION_ID=).+' /etc/os-release 2>/dev/null | tr -d '"' || echo "")
info "Detected OS: $OS_ID $OS_VER"
info "Installing for user: $REAL_USER"

# ── Step 1: system update ─────────────────────────────────────────────────────
step "Step 1 — Update package lists"
apt-get update -qq && ok "Package lists updated" || warn "apt update had warnings"

# ── Step 2: install core tools ────────────────────────────────────────────────
step "Step 2 — Install core tools"
apt-get install -y -qq \
  curl wget git ca-certificates gnupg lsb-release \
  python3 python3-pip \
  >/dev/null 2>&1 && ok "Core tools installed" || warn "Some core tools failed"

# ── Step 3: install Docker ────────────────────────────────────────────────────
step "Step 3 — Install Docker"

if command -v docker >/dev/null 2>&1; then
  ok "Docker already installed: $(docker --version)"
else
  info "Installing Docker..."

  # Remove old conflicting packages
  for pkg in docker docker-engine docker.io containerd runc docker-doc docker-compose podman-docker; do
    apt-get remove -y -qq $pkg 2>/dev/null || true
  done

  # Try direct install first (works on most Debian/Ubuntu/Kali)
  if apt-get install -y -qq docker.io 2>/dev/null; then
    ok "docker.io installed"
  else
    # Official Docker repo
    info "Adding official Docker repository..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null || true
    chmod a+r /etc/apt/keyrings/docker.gpg 2>/dev/null || true

    ARCH=$(dpkg --print-architecture)
    # Kali uses debian repos
    DIST="debian"
    [ "$OS_ID" = "ubuntu" ] && DIST="ubuntu"

    echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/$DIST \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      | tee /etc/apt/sources.list.d/docker.list >/dev/null

    apt-get update -qq 2>/dev/null || true
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io 2>/dev/null || \
      warn "Docker CE install failed — trying docker.io fallback"
    apt-get install -y -qq docker.io 2>/dev/null || true
  fi

  if command -v docker >/dev/null 2>&1; then
    ok "Docker installed: $(docker --version)"
  else
    fail "Docker installation failed. Install manually: https://docs.docker.com/engine/install/"
  fi
fi

# ── Step 4: install Docker Compose ───────────────────────────────────────────
step "Step 4 — Install Docker Compose"

if docker compose version >/dev/null 2>&1; then
  ok "docker compose (plugin) already available"
elif command -v docker-compose >/dev/null 2>&1; then
  ok "docker-compose already installed: $(docker-compose --version)"
else
  info "Installing docker-compose..."

  # Try apt first
  apt-get install -y -qq docker-compose-plugin 2>/dev/null || true
  apt-get install -y -qq docker-compose       2>/dev/null || true

  # If still not found, install binary directly
  if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
    info "Downloading docker-compose binary..."
    COMPOSE_VERSION="2.24.5"
    curl -SL "https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}/docker-compose-linux-$(uname -m)" \
      -o /usr/local/bin/docker-compose 2>/dev/null || true
    chmod +x /usr/local/bin/docker-compose 2>/dev/null || true
  fi

  if docker compose version >/dev/null 2>&1; then
    ok "docker compose plugin ready"
  elif command -v docker-compose >/dev/null 2>&1; then
    ok "docker-compose ready: $(docker-compose --version)"
  else
    warn "Compose not found — lab may not start. Try: sudo apt install docker-compose"
  fi
fi

# ── Step 5: start and enable Docker ──────────────────────────────────────────
step "Step 5 — Start Docker service"

systemctl enable docker 2>/dev/null || true
systemctl start  docker 2>/dev/null || true
sleep 2

if systemctl is-active docker >/dev/null 2>&1; then
  ok "Docker service running"
elif docker info >/dev/null 2>&1; then
  ok "Docker is responding"
else
  warn "Docker service may not be running. Try: sudo systemctl start docker"
fi

# ── Step 6: add user to docker group ─────────────────────────────────────────
step "Step 6 — Add $REAL_USER to docker group"

if getent group docker >/dev/null 2>&1; then
  usermod -aG docker "$REAL_USER" 2>/dev/null || true
  ok "$REAL_USER added to docker group"
  info "You may need to log out and back in for group changes to take effect"
  info "Or run: newgrp docker"
else
  warn "docker group not found — skipping"
fi

# ── Step 7: install Python packages ──────────────────────────────────────────
step "Step 7 — Install Python packages"

apt-get install -y -qq python3-paramiko python3-requests 2>/dev/null || \
  pip3 install paramiko requests --break-system-packages 2>/dev/null || true
ok "Python packages ready"

# ── Step 8: verify everything ─────────────────────────────────────────────────
step "Step 8 — Verify installation"

echo ""
DOCKER_OK=false
COMPOSE_OK=false

if docker --version >/dev/null 2>&1; then
  ok "docker: $(docker --version)"
  DOCKER_OK=true
else
  warn "docker: NOT FOUND"
fi

if docker compose version >/dev/null 2>&1; then
  ok "compose: $(docker compose version)"
  COMPOSE_OK=true
elif docker-compose --version >/dev/null 2>&1; then
  ok "compose: $(docker-compose --version)"
  COMPOSE_OK=true
else
  warn "compose: NOT FOUND"
fi

if python3 --version >/dev/null 2>&1; then
  ok "python3: $(python3 --version)"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}══ Done ══${NC}"
echo ""

if [ "$DOCKER_OK" = true ] && [ "$COMPOSE_OK" = true ]; then
  echo -e "${GREEN}All dependencies installed. Next steps:${NC}"
  echo ""
  echo "  1. Apply docker group (no re-login needed with this):"
  echo "     newgrp docker"
  echo ""
  echo "  2. Start the lab:"
  echo "     cd ~/Documents/ssh-botnet-lab"
  echo "     chmod +x setup.sh && ./setup.sh"
else
  echo -e "${YELLOW}Some dependencies may be missing. Check warnings above.${NC}"
  echo ""
  echo "  Manual install if needed:"
  echo "    sudo apt install docker.io docker-compose"
fi
echo ""
