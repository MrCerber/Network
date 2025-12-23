#!/usr/bin/env bash
# MrCerber - New Server Bootstrap (Ubuntu/Debian)
# Requirements:
# - MUST be run as root
# - SSH keys already installed for root (assumed)
# - NO user creation, NO timezone changes, NO swap changes
#
# Features:
# - Interactive main menu + sub menus (UFW / Fail2ban)
# - Base packages install
# - Automatic security updates (unattended-upgrades)
# - Disable default MOTD + disable SSH "Last login"
# - Install custom MOTD from two files: 99-mrcerber and logo.txt
# - Restore default MOTD + restore "Last login"
#
# How custom MOTD works:
# Place your custom files next to this script:
# ./99-mrcerber
# ./logo.txt
# Script installs them into:
# /etc/update-motd.d/99-mrcerber
# /etc/update-motd.d/logo.txt

set -Eeuo pipefail

# ---------------------------
# Globals
# ---------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
CUSTOM_MOTD_99_SRC="${SCRIPT_DIR}/99-mrcerber"
CUSTOM_MOTD_LOGO_SRC="${SCRIPT_DIR}/logo.txt"
MOTD_BASE_URL="${MOTD_BASE_URL:-https://raw.githubusercontent.com/MrCerber/Network/refs/heads/main/v2}"

MOTD_DIR="/etc/update-motd.d"
BACKUP_DIR="/root/.mrcerber-bootstrap-backups"
SSHD_CONFIG="/etc/ssh/sshd_config"

# ---------------------------
# Oh My Posh globals
# ---------------------------
OMP_DIR="/root/.config/oh-my-posh"
OMP_THEME_QUICK="${OMP_DIR}/quick-term.omp.json"
OMP_THEME_QUICK_URL="https://raw.githubusercontent.com/JanDeDobbeleer/oh-my-posh/refs/heads/main/themes/quick-term.omp.json"
OMP_BASHRC="/root/.bashrc"

# we keep the init line consistent and easy to match/remove
OMP_INIT_LINE='eval "$(oh-my-posh init bash --config /root/.config/oh-my-posh/quick-term.omp.json)"'

# ---------------------------
# UI helpers
# ---------------------------
say()  { printf "%s\n" "$*"; }
warn() { printf "WARNING: %s\n" "$*" >&2; }
die()  { printf "ERROR: %s\n" "$*" >&2; exit 1; }

pause() {
  read -r -p "Press Enter to continue..." _
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "This script must be run as root."
  fi
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_dirs() {
  mkdir -p "${BACKUP_DIR}"
}

backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  local dest="${BACKUP_DIR}/$(echo "$f" | sed 's#/#__#g').${ts}.bak"
  cp -a "$f" "$dest"
}

backup_dir_tar() {
  local d="$1"
  [[ -d "$d" ]] || return 0
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  local dest="${BACKUP_DIR}/$(echo "$d" | sed 's#/#__#g').${ts}.tar.gz"
  tar -czf "$dest" -C "$(dirname "$d")" "$(basename "$d")"
}

confirm() {
  local prompt="${1:-Are you sure?} [y/N]: "
  read -r -p "$prompt" ans
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

# ---------------------------
# System / APT
# ---------------------------
apt_update_upgrade() {
  say "Updating package lists..."
  apt-get update -y
  say "Upgrading installed packages..."
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
}

install_base_packages() {
  say "Installing base packages..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl wget gnupg lsb-release \
    unzip zip tar \
    nano vim \
    htop btop \
    net-tools iproute2 \
    dnsutils \
    jq \
    git \
    ufw \
    fail2ban \
    unattended-upgrades \
    apt-listchanges \
    openssh-server
}

# ---------------------------
# Unattended Upgrades
# ---------------------------
enable_auto_updates() {
  say "Enabling unattended-upgrades..."
  backup_file "/etc/apt/apt.conf.d/20auto-upgrades"
  backup_file "/etc/apt/apt.conf.d/50unattended-upgrades"

  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF

  # Keep this conservative (security + important updates).
  # You can extend as needed.
  cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
        "${distro_id}:${distro_codename}";
        "${distro_id}:${distro_codename}-security";
        "${distro_id}ESMApps:${distro_codename}-apps-security";
        "${distro_id}ESM:${distro_codename}-infra-security";
};

Unattended-Upgrade::Package-Blacklist {
};

Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::SyslogEnable "true";
EOF

  if has_cmd unattended-upgrade; then
    unattended-upgrade --dry-run --debug || true
  fi

  systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
  say "Unattended upgrades enabled."
}

# ---------------------------
# SSH tweaks (Last login)
# ---------------------------
sshd_set_printlastlog() {
  local value="$1"  # "yes" or "no"
  backup_file "${SSHD_CONFIG}"

  # Ensure directive exists (idempotent).
  if grep -qiE '^\s*PrintLastLog\s+' "${SSHD_CONFIG}"; then
    sed -i -E "s/^\s*PrintLastLog\s+.*/PrintLastLog ${value}/I" "${SSHD_CONFIG}"
  else
    printf "\nPrintLastLog %s\n" "${value}" >> "${SSHD_CONFIG}"
  fi

  # Reload SSH safely
  systemctl reload ssh >/dev/null 2>&1 || systemctl reload sshd >/dev/null 2>&1 || true
}

disable_last_login() {
  say "Disabling SSH 'Last login' message..."
  sshd_set_printlastlog "no"
  say "Done."
}

restore_last_login() {
  say "Restoring SSH 'Last login' message..."
  sshd_set_printlastlog "yes"
  say "Done."
}

# ---------------------------
# MOTD management
# ---------------------------
disable_default_motd_scripts() {
  # Disable all executable scripts in update-motd.d except our custom 99-mrcerber
  # We also back up the directory as a tarball once per run.
  backup_dir_tar "${MOTD_DIR}"

  shopt -s nullglob
  for f in "${MOTD_DIR}/"*; do
    [[ -f "$f" ]] || continue
    local base
    base="$(basename "$f")"
    if [[ "$base" == "99-mrcerber" || "$base" == "logo.txt" ]]; then
      continue
    fi
    if [[ -x "$f" ]]; then
      chmod -x "$f" || true
    fi
  done
  shopt -u nullglob
}

enable_default_motd_scripts() {
  # Re-enable common Ubuntu default scripts if present
  # (Conservative: only known defaults)
  backup_dir_tar "${MOTD_DIR}"

  local defaults=(
    "00-header"
    "10-help-text"
    "50-motd-news"
    "50-landscape-sysinfo"
    "85-fwupd"
    "90-updates-available"
    "91-contract-ua-esm-status"
    "91-release-upgrade"
    "92-unattended-upgrades"
    "95-hwe-eol"
    "97-overlayroot"
    "98-fsck-at-reboot"
  )

  for base in "${defaults[@]}"; do
    if [[ -f "${MOTD_DIR}/${base}" ]]; then
      chmod +x "${MOTD_DIR}/${base}" || true
    fi
  done
}

install_custom_motd() {
  local motd_99_src="${CUSTOM_MOTD_99_SRC}"
  local motd_logo_src="${CUSTOM_MOTD_LOGO_SRC}"
  local tmp_dir=""

  if [[ ! -f "${motd_99_src}" || ! -f "${motd_logo_src}" ]]; then
    if ! has_cmd curl && ! has_cmd wget; then
      die "Missing custom files and neither curl nor wget is available."
    fi
    say "Custom MOTD files not found next to this script; downloading..."
    tmp_dir="$(mktemp -d -t mrcerber-motd-XXXXXX)"
    if [[ ! -f "${motd_99_src}" ]]; then
      if has_cmd curl; then
        curl -fsSL "${MOTD_BASE_URL}/99-mrcerber" -o "${tmp_dir}/99-mrcerber"
      else
        wget -qO "${tmp_dir}/99-mrcerber" "${MOTD_BASE_URL}/99-mrcerber"
      fi
      motd_99_src="${tmp_dir}/99-mrcerber"
    fi
    if [[ ! -f "${motd_logo_src}" ]]; then
      if has_cmd curl; then
        curl -fsSL "${MOTD_BASE_URL}/logo.txt" -o "${tmp_dir}/logo.txt"
      else
        wget -qO "${tmp_dir}/logo.txt" "${MOTD_BASE_URL}/logo.txt"
      fi
      motd_logo_src="${tmp_dir}/logo.txt"
    fi
  fi

  [[ -f "${motd_99_src}" ]] || die "Missing custom file: ${motd_99_src}"
  [[ -f "${motd_logo_src}" ]] || die "Missing custom file: ${motd_logo_src}"

  say "Installing custom MOTD..."
  ensure_dirs
  backup_dir_tar "${MOTD_DIR}"

  # Install files
  install -m 0755 "${motd_99_src}" "${MOTD_DIR}/99-mrcerber"
  install -m 0644 "${motd_logo_src}" "${MOTD_DIR}/logo.txt"

  # Disable default MOTD scripts
  disable_default_motd_scripts

  # Disable last login (requested together with custom MOTD)
  disable_last_login

  say "Custom MOTD installed."
  say "Tip: ensure /etc/update-motd.d/99-mrcerber reads logo from /etc/update-motd.d/logo.txt."

  if [[ -n "${tmp_dir}" ]]; then
    rm -rf "${tmp_dir}"
  fi
}

restore_default_motd() {
  say "Restoring default MOTD behavior..."
  ensure_dirs
  backup_dir_tar "${MOTD_DIR}"

  # Remove custom files (optional)
  if [[ -f "${MOTD_DIR}/99-mrcerber" ]]; then rm -f "${MOTD_DIR}/99-mrcerber"; fi
  if [[ -f "${MOTD_DIR}/logo.txt" ]]; then rm -f "${MOTD_DIR}/logo.txt"; fi

  # Re-enable known defaults
  enable_default_motd_scripts

  # Restore last login
  restore_last_login

  say "Default MOTD restored (as far as system scripts exist on this server)."
}

preview_motd() {
  say "Previewing dynamic MOTD output:"
  say "----------------------------------------"
  run-parts "${MOTD_DIR}" || true
  say "----------------------------------------"
}

# ---------------------------
# UFW menu
# ---------------------------
ufw_status() {
  ufw status verbose || true
}

ufw_basic_hardening() {
  say "Applying UFW defaults..."
  ufw default deny incoming
  ufw default allow outgoing
  say "Done."
}

ufw_allow_ssh() {
  say "Allowing SSH (22/tcp)..."
  ufw allow 22/tcp
}

ufw_allow_http_https() {
  say "Allowing HTTP/HTTPS (80,443)..."
  ufw allow 80/tcp
  ufw allow 443/tcp
}

ufw_allow_custom() {
  read -r -p "Enter port (e.g., 8443): " port
  if ! [[ "$port" =~ ^[0-9]{1,5}$ ]] || (( port < 1 || port > 65535 )); then
    die "Invalid port."
  fi
  read -r -p "Protocol (tcp/udp/both) [tcp]: " proto
  proto="${proto:-tcp}"
  case "${proto,,}" in
    tcp) ufw allow "${port}/tcp" ;;
    udp) ufw allow "${port}/udp" ;;
    both) ufw allow "${port}/tcp"; ufw allow "${port}/udp" ;;
    *) die "Invalid protocol." ;;
  esac
}

ufw_delete_rule() {
  say "Current rules:"
  ufw status numbered || true
  read -r -p "Enter rule number to delete: " num
  [[ "$num" =~ ^[0-9]+$ ]] || die "Invalid number."
  ufw delete "$num"
}

ufw_enable() {
  say "Enabling UFW..."
  ufw --force enable
  systemctl enable --now ufw >/dev/null 2>&1 || true
}

ufw_disable() {
  say "Disabling UFW..."
  ufw disable
}

ufw_reset() {
  confirm "This will reset UFW (remove rules). Continue? [y/N]: " || return 0
  ufw --force reset
}

ufw_menu() {
  while true; do
    clear
    say "UFW Menu"
    say "================================"
    say "1) Status (verbose)"
    say "2) Apply defaults (deny incoming / allow outgoing)"
    say "3) Allow SSH (22/tcp)"
    say "4) Allow HTTP+HTTPS (80/443)"
    say "5) Allow custom port"
    say "6) Delete rule (by number)"
    say "7) Enable UFW"
    say "8) Disable UFW"
    say "9) Reset UFW (danger)"
    say "0) Back"
    say ""
    read -r -p "Select: " c
    case "$c" in
      1) ufw_status; pause ;;
      2) ufw_basic_hardening; pause ;;
      3) ufw_allow_ssh; pause ;;
      4) ufw_allow_http_https; pause ;;
      5) ufw_allow_custom; pause ;;
      6) ufw_delete_rule; pause ;;
      7) ufw_enable; pause ;;
      8) ufw_disable; pause ;;
      9) ufw_reset; pause ;;
      0) break ;;
      *) warn "Invalid choice."; pause ;;
    esac
  done
}

# ---------------------------
# Fail2ban menu
# ---------------------------
fail2ban_install_enable() {
  say "Installing/ensuring Fail2ban..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban
  systemctl enable --now fail2ban
  say "Fail2ban enabled."
}

fail2ban_write_jail_local() {
  say "Writing /etc/fail2ban/jail.local (SSH protection)..."
  if [[ ! -d /etc/fail2ban ]]; then
    warn "Fail2ban not installed. Use 'Install + enable Fail2ban' first."
    return 0
  fi
  backup_file "/etc/fail2ban/jail.local"

  cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
# Adjust as desired:
bantime  = 1h
findtime = 10m
maxretry = 5

# Backend selection (systemd is typical on Ubuntu):
backend = systemd

# Use UFW if available:
banaction = ufw

# Optional notifications:
# destemail = root@localhost
# sender = fail2ban@localhost
# mta = sendmail
# action = %(action_mwl)s

[sshd]
enabled  = true
mode     = normal
port     = ssh
logpath  = %(sshd_log)s
EOF

  if ! systemctl restart fail2ban >/dev/null 2>&1; then
    warn "Fail2ban restart failed. Ensure it is installed and enabled."
  fi
  say "jail.local written."
}

fail2ban_status() {
  systemctl status fail2ban --no-pager || true
  say ""
  fail2ban-client status || true
  say ""
  fail2ban-client status sshd || true
}

fail2ban_unban_ip() {
  read -r -p "Enter IP to unban: " ip
  [[ -n "$ip" ]] || die "IP cannot be empty."
  fail2ban-client set sshd unbanip "$ip" || true
}

fail2ban_menu() {
  while true; do
    clear
    say "Fail2ban Menu"
    say "================================"
    say "1) Install + enable Fail2ban"
    say "2) Configure SSH jail (write jail.local)"
    say "3) Status"
    say "4) Unban IP (sshd)"
    say "0) Back"
    say ""
    read -r -p "Select: " c
    case "$c" in
      1) fail2ban_install_enable; pause ;;
      2) fail2ban_write_jail_local; pause ;;
      3) fail2ban_status; pause ;;
      4) fail2ban_unban_ip; pause ;;
      0) break ;;
      *) warn "Invalid choice."; pause ;;
    esac
  done
}

# ---------------------------
# Oh My Posh menu (NEW)
# ---------------------------

omp_is_installed() {
  has_cmd oh-my-posh
}

omp_install() {
  say "Installing Oh My Posh..."
  if ! omp_is_installed; then
    curl -s https://ohmyposh.dev/install.sh | bash -s -- -d /usr/local/bin
  fi
  mkdir -p "${OMP_DIR}"
  say "Downloading theme: quick-term..."
  curl -fsSL "${OMP_THEME_QUICK_URL}" -o "${OMP_THEME_QUICK}"
  say "Oh My Posh installed."
}

omp_font_install_meslo() {
  if ! omp_is_installed; then
    die "Oh My Posh is not installed."
  fi
  say "Installing Meslo font using Oh My Posh..."
  oh-my-posh font install meslo
}

omp_enable_bash() {
  if ! omp_is_installed; then
    die "Oh My Posh is not installed."
  fi
  mkdir -p "${OMP_DIR}"
  [[ -f "${OMP_THEME_QUICK}" ]] || curl -fsSL "${OMP_THEME_QUICK_URL}" -o "${OMP_THEME_QUICK}"

  backup_file "${OMP_BASHRC}"
  [[ -f "${OMP_BASHRC}" ]] || touch "${OMP_BASHRC}"

  # remove any previous oh-my-posh init lines (keeps file clean)
  sed -i '/oh-my-posh init bash/d' "${OMP_BASHRC}"

  cat >> "${OMP_BASHRC}" <<EOF

# Oh My Posh
${OMP_INIT_LINE}
EOF

  say "Oh My Posh enabled for bash. Re-login to apply."
}

omp_disable_bash() {
  backup_file "${OMP_BASHRC}"
  [[ -f "${OMP_BASHRC}" ]] || return 0
  sed -i '/oh-my-posh init bash/d' "${OMP_BASHRC}"
  say "Oh My Posh disabled for bash. Re-login to apply."
}

omp_remove() {
  confirm "This will remove Oh My Posh and its config. Continue? [y/N]: " || return 0
  omp_disable_bash
  rm -f /usr/local/bin/oh-my-posh
  rm -rf "${OMP_DIR}"
  say "Oh My Posh removed."
}

omp_status() {
  if omp_is_installed; then
    say "Oh My Posh: INSTALLED"
    oh-my-posh version || true
  else
    say "Oh My Posh: NOT installed"
  fi

  if [[ -f "${OMP_THEME_QUICK}" ]]; then
    say "Theme: quick-term (present)"
  else
    say "Theme: quick-term (missing)"
  fi

  if grep -q "oh-my-posh init bash" "${OMP_BASHRC}" 2>/dev/null; then
    say "Bash integration: ENABLED"
  else
    say "Bash integration: DISABLED"
  fi
}

oh_my_posh_menu() {
  while true; do
    clear
    say "Oh My Posh Menu"
    say "================================"
    say "1) Status"
    say "2) Install Oh My Posh"
    say "3) Download quick-term theme"
    say "4) Enable in bash (.bashrc)"
    say "5) Disable in bash (.bashrc)"
    say "6) Font install: Meslo (oh-my-posh font install meslo)"
    say "7) Remove Oh My Posh (clean)"
    say "0) Back"
    say ""
    read -r -p "Select: " c
    case "$c" in
      1) omp_status; pause ;;
      2) omp_install; pause ;;
      3) mkdir -p "${OMP_DIR}"; curl -fsSL "${OMP_THEME_QUICK_URL}" -o "${OMP_THEME_QUICK}"; say "Theme downloaded."; pause ;;
      4) omp_enable_bash; pause ;;
      5) omp_disable_bash; pause ;;
      6) omp_font_install_meslo; pause ;;
      7) omp_remove; pause ;;
      0) break ;;
      *) warn "Invalid choice."; pause ;;
    esac
  done
}

# ---------------------------
# Main menu actions
# ---------------------------
full_base_setup() {
  apt_update_upgrade
  install_base_packages
  enable_auto_updates
  say "Base setup completed."
}

# ---------------------------
# Main menu
# ---------------------------
main_menu() {
  while true; do
    clear
    say "MrCerber - New Server Bootstrap"
    say "================================"
    say "1) Full base setup (update/upgrade + packages + auto-updates)"
    say "2) Update/upgrade only"
    say "3) Install base packages only"
    say "4) Enable automatic updates (unattended-upgrades)"
    say "5) Install custom MOTD + disable Last login"
    say "6) Restore default MOTD + restore Last login"
    say "7) Preview MOTD output"
    say "8) UFW submenu"
    say "9) Fail2ban submenu"
    say "10) Oh My Posh submenu"
    say "0) Exit"
    say ""
    read -r -p "Select: " choice
    case "$choice" in
      1) full_base_setup; pause ;;
      2) apt_update_upgrade; pause ;;
      3) install_base_packages; pause ;;
      4) enable_auto_updates; pause ;;
      5) install_custom_motd; pause ;;
      6) restore_default_motd; pause ;;
      7) preview_motd; pause ;;
      8) ufw_menu ;;
      9) fail2ban_menu ;;
      10) oh_my_posh_menu ;;
      0) exit 0 ;;
      *) warn "Invalid choice."; pause ;;
    esac
  done
}

# ---------------------------
# Entrypoint
# ---------------------------
require_root
ensure_dirs
main_menu
