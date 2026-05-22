#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}==>${NC} $*"; }
info() { echo -e "${BLUE}  -${NC} $*"; }
warn() { echo -e "${YELLOW}WARN:${NC} $*"; }
die()  { echo -e "${RED}ERROR:${NC} $*" >&2; exit 1; }

detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_LIKE="${ID_LIKE:-}"
  else
    die "Cannot detect OS: /etc/os-release not found."
  fi

  if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" || "$OS_LIKE" == *"debian"* ]]; then
    PKG_MANAGER="apt"
  elif [[ "$OS_ID" == "fedora" || "$OS_ID" == "rhel" || "$OS_ID" == "centos" || "$OS_LIKE" == *"rhel"* ]]; then
    PKG_MANAGER="dnf"
  elif [[ "$OS_ID" == "arch" || "$OS_LIKE" == *"arch"* ]]; then
    PKG_MANAGER="pacman"
  else
    PKG_MANAGER="unknown"
  fi
}

need_sudo() {
  [[ "$EUID" -ne 0 ]] && echo "sudo" || echo ""
}

# docker
install_docker() {
  log "Installing Docker..."
  local SUDO
  SUDO=$(need_sudo)

  if [[ "$PKG_MANAGER" == "apt" ]]; then
    $SUDO apt-get update -qq
    $SUDO apt-get install -y ca-certificates curl gnupg lsb-release
    $SUDO install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    $SUDO chmod a+r /etc/apt/keyrings/docker.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
      | $SUDO tee /etc/apt/sources.list.d/docker.list > /dev/null
    $SUDO apt-get update -qq
    $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    $SUDO systemctl enable --now docker
    # Allow current user to run docker without sudo
    $SUDO usermod -aG docker "$USER" || true
    warn "Docker group added — you may need to log out and back in for it to take effect."
  elif [[ "$PKG_MANAGER" == "dnf" ]]; then
    $SUDO dnf -y install dnf-plugins-core
    $SUDO dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
    $SUDO dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    $SUDO systemctl enable --now docker
    $SUDO usermod -aG docker "$USER" || true
    warn "Docker group added — you may need to log out and back in for it to take effect."
  elif [[ "$PKG_MANAGER" == "pacman" ]]; then
    $SUDO pacman -S --noconfirm docker
    $SUDO systemctl enable --now docker
    $SUDO usermod -aG docker "$USER" || true
    warn "Docker group added — you may need to log out and back in for it to take effect."
  else
    die "Cannot install Docker automatically on this OS. Install it manually: https://docs.docker.com/engine/install/"
  fi
}

# kubectl
install_kubectl() {
  log "Installing kubectl..."
  local SUDO
  SUDO=$(need_sudo)
  local VERSION
  VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt)

  curl -fsSL "https://dl.k8s.io/release/${VERSION}/bin/linux/amd64/kubectl" -o /tmp/kubectl
  curl -fsSL "https://dl.k8s.io/release/${VERSION}/bin/linux/amd64/kubectl.sha256" -o /tmp/kubectl.sha256
  echo "$(cat /tmp/kubectl.sha256) /tmp/kubectl" | sha256sum --check --quiet \
    || die "kubectl checksum verification failed."

  $SUDO install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl
  rm -f /tmp/kubectl /tmp/kubectl.sha256
  info "kubectl $(kubectl version --client --short 2>/dev/null || kubectl version --client) installed."
}

# Helm
install_helm() {
  log "Installing Helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  info "Helm $(helm version --short) installed."
}

# k3d
install_k3d() {
  log "Installing k3d..."
  curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
  info "k3d $(k3d version | head -1) installed."
}

# Main
main() {
  detect_os
  info "Detected OS: $OS_ID (package manager: $PKG_MANAGER)"
  echo ""

  local installed=0
  local skipped=0

  # Docker (required by k3d)
  if command -v docker &>/dev/null; then
    info "docker already installed — skipping."
    ((skipped++)) || true
  else
    install_docker
    ((installed++)) || true
  fi

  # kubectl
  if command -v kubectl &>/dev/null; then
    info "kubectl already installed ($(kubectl version --client --short 2>/dev/null | head -1)) — skipping."
    ((skipped++)) || true
  else
    install_kubectl
    ((installed++)) || true
  fi

  # Helm
  if command -v helm &>/dev/null; then
    info "helm already installed ($(helm version --short)) — skipping."
    ((skipped++)) || true
  else
    install_helm
    ((installed++)) || true
  fi

  # k3d
  if command -v k3d &>/dev/null; then
    info "k3d already installed ($(k3d version | head -1)) — skipping."
    ((skipped++)) || true
  else
    install_k3d
    ((installed++)) || true
  fi

  echo ""
  echo -e "${GREEN}Done.${NC} Installed: $installed tool(s), skipped: $skipped already present."
}

main "$@"
