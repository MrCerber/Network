#!/usr/bin/env bash
# MrCerber - New Server Bootstrap (Ubuntu/Debian)
# Requirements:
#   - MUST be run as root
#   - SSH keys already installed for root (assumed)
#   - NO user creation, NO timezone changes, NO swap changes
#
# Features:
#   - Interactive main menu + sub menus (UFW / Fail2ban)
#   - Base packages install
#   - Automatic security updates (unattended-upgrades)
#   - Disable default MOTD + disable SSH "Last login"
#   - Install custom MOTD from two files: 99-mrcerber and logo.txt
#   - Restore default MOTD + restore "Last login"
#
# How custom MOTD works:
#   Place your custom files next to this script:
#     ./99-mrcerber
#     ./logo.txt
#   Script installs them into:
#     /etc/update-motd.d/99-mrcerber
#     /etc/update-motd.d/logo.txt
#
set -Eeuo pipefail

# ---------------------------
# Globals
# ---------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
CUSTOM_MOTD_99_SRC="${SCRIPT_DIR}/99-mrcerber"
CUSTOM_MOTD_LOGO_SRC="${SCRIPT_DIR}/logo.txt"

MOTD_DIR="/etc/update-motd.d"
BACKUP_DIR="/root/.mrcerber-bootstrap-backups"
SSHD_CONFIG="/etc/ssh/sshd_config"

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
  local dest="${BACKUP_DIR}$(echo "$f" | sed 's#/#__#g').${ts}.bak"
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

  # Keep this conservative (security + important updates). You can extend as needed.
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
  [[ -f "${CUSTOM_MOTD_99_SRC}" ]] || die "Missing custom file: ${CUSTOM_MOTD_99_SRC}"
  [[ -f "${CUSTOM_MOTD_LOGO_SRC}" ]] || die "Missing custom file: ${CUSTOM_MOTD_LOGO_SRC}"

  say "Installing custom MOTD..."
  ensure_dirs
  backup_dir_tar "${MOTD_DIR}"

  # Install files
  install -m 0755 "${CUSTOM_MOTD_99_SRC}" "${MOTD_DIR}/99-mrcerber"
  install -m 0644 "${CUSTOM_MOTD_LOGO_SRC}" "${MOTD_DIR}/logo.txt"

  # Disable default MOTD scripts
  disable_default_motd_scripts

  # Disable last login (requested together with custom MOTD)
  disable_last_login

  say "Custom MOTD installed."
  say "Tip: ensure /etc/update-motd.d/99-mrcerber reads logo from /etc/update-motd.d/logo.txt."
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
  [[ "$port" =~ ^[0-9]{1,5}$ ]] || die "Invalid port."
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

  systemctl restart fail2ban
  say "jail.local written and Fail2ban restarted."
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
