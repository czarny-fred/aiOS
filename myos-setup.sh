#!/usr/bin/env bash
# =============================================================================
# myos-setup.sh  -  "My OS" bootstrap for Arch Linux + Hyprland + NVIDIA
#
# Run this AFTER a base Arch install (archinstall: UEFI, GPT, LUKS, Btrfs,
# GRUB, NetworkManager, a normal user with sudo, kernel "linux").
#
#   ./myos-setup.sh                 # run all stages
#   ./myos-setup.sh nvidia desktop  # run only chosen stages
#   ./myos-setup.sh --list          # list stages
#
# Env options:  MYOS_DIR=~/myos  KB_LAYOUT=pl  QUICKSHELL=1
#
# Design rules:
#  - Idempotent: safe to run again.
#  - Never wipes disks. Never overwrites your existing configs (backs up).
#  - Missing packages are reported (missing-packages.txt), not fatal.
#  - All config lives in ~/myos (a git repo) and is symlinked into ~/.config.
#    You are the operator: edit, commit, roll back.
#  - AUR packages (wlogout, localsend-bin, jetbrains-toolbox, llama.cpp-cuda,
#    protonup-qt, optional quickshell) are built from user-submitted PKGBUILDs.
#    Review them if that matters to you.
# =============================================================================
set -Eeuo pipefail

MYOS_DIR="${MYOS_DIR:-$HOME/myos}"
KB_LAYOUT="${KB_LAYOUT:-pl}"
QUICKSHELL="${QUICKSHELL:-0}"
LOG="$MYOS_DIR/setup.log"

ALL_STAGES=(preflight base nvidia desktop dev ai gaming phone security snapshots dotfiles cli)

info() { printf '\e[1;34m==>\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m !!\e[0m %s\n' "$*"; }
die()  { printf '\e[1;31m xx\e[0m %s\n' "$*" >&2; exit 1; }
trap 'warn "Failed at line $LINENO (see $LOG). Fix and re-run - the script is idempotent."' ERR

# ---------- helpers ----------------------------------------------------------
pac_install() {
  local ok=() missing=() p
  for p in "$@"; do
    if pacman -Si "$p" &>/dev/null; then ok+=("$p"); else missing+=("$p"); fi
  done
  if ((${#ok[@]})); then sudo pacman -S --needed --noconfirm "${ok[@]}"; fi
  if ((${#missing[@]})); then
    warn "Not in official repos (skipped): ${missing[*]}"
    echo "${missing[*]}" >> "$MYOS_DIR/missing-packages.txt"
  fi
  return 0
}

ensure_yay() {
  command -v yay &>/dev/null && return 0
  info "Installing yay (AUR helper)"
  local t; t="$(mktemp -d)"
  git clone --depth 1 https://aur.archlinux.org/yay-bin.git "$t/yay-bin"
  (cd "$t/yay-bin" && makepkg -si --noconfirm)
  rm -rf "$t"
}

aur_install() {
  ensure_yay
  local p
  for p in "$@"; do
    yay -S --needed --noconfirm "$p" || warn "AUR package failed: $p"
  done
}

link() { # link <source in repo> <target>
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [[ -e "$dst" && ! -L "$dst" ]]; then
    mv "$dst" "$dst.bak.$(date +%s)"; warn "Backed up existing $dst"
  fi
  ln -sfn "$src" "$dst"
}

# ---------- stages -----------------------------------------------------------
st_preflight() {
  [[ $EUID -ne 0 ]] || die "Run as a normal user with sudo, not root."
  command -v pacman &>/dev/null || die "This is for Arch Linux."
  ping -c1 -W3 archlinux.org &>/dev/null || die "No internet connection."
  sudo -v
  if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
    info "Enabling multilib (needed for Steam / lib32-*)"
    sudo sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf
  fi
  git config --global init.defaultBranch main
}

st_base() {
  info "Updating system and installing base tools"
  sudo pacman -Syu --noconfirm
  pac_install base-devel git curl wget nano vim htop btop fastfetch ripgrep fd fzf \
    unzip zip man-db pacman-contrib reflector \
    networkmanager network-manager-applet bluez bluez-utils \
    pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber pavucontrol \
    noto-fonts noto-fonts-emoji ttf-jetbrains-mono-nerd ttf-font-awesome
  sudo systemctl enable --now NetworkManager bluetooth fstrim.timer
}

st_nvidia() {
  info "Installing NVIDIA drivers (RTX 5060 Ti needs the open kernel modules)"
  local kernel pkgs=()
  kernel="$(uname -r)"
  if [[ "$kernel" == *lts* ]]; then
    pkgs=(nvidia-open-dkms linux-lts-headers dkms)
  elif [[ "$kernel" == *zen* || "$kernel" == *hardened* ]]; then
    pkgs=(nvidia-open-dkms dkms); warn "Custom kernel detected: install its -headers package too."
  else
    pkgs=(nvidia-open)
  fi
  pac_install "${pkgs[@]}" nvidia-utils lib32-nvidia-utils nvidia-settings libva-nvidia-driver egl-wayland
  sudo mkinitcpio -P
  warn "Reboot is required before the NVIDIA driver is active. Then run: nvidia-smi"
}

st_desktop() {
  info "Installing Hyprland desktop"
  pac_install hyprland uwsm hypridle hyprlock hyprpaper waybar dunst kitty thunar gvfs \
    thunar-archive-plugin brightnessctl playerctl grim slurp wl-clipboard cliphist \
    qt5-wayland qt6-wayland xdg-desktop-portal-hyprland xdg-desktop-portal-gtk polkit-gnome
  # rofi merged Wayland support in newer releases; fall back gracefully
  if pacman -Si rofi-wayland &>/dev/null; then pac_install rofi-wayland; else pac_install rofi; fi
  aur_install wlogout
  if [[ "$QUICKSHELL" == "1" ]]; then
    info "Quickshell (QML) for fully custom bars/docks/widgets"
    aur_install quickshell
  fi
}

st_dev() {
  info "Installing development tools"
  pac_install git git-lfs docker docker-compose docker-buildx \
    python python-pip python-pipx uv nodejs npm pnpm typescript \
    jdk21-openjdk maven gradle mise
  aur_install jetbrains-toolbox
  sudo systemctl enable --now docker
  if ! id -nG "$USER" | grep -qw docker; then
    sudo usermod -aG docker "$USER"
    warn "Docker group = root-equivalent. For stricter isolation consider rootless Docker or Podman."
  fi
  warn "Isolation rule: pacman for system packages; uv/venv, mise, pnpm, containers per project."
}

st_ai() {
  info "Installing local-AI stack (CUDA, Ollama, llama.cpp, PyTorch)"
  pac_install cuda ollama-cuda
  sudo systemctl enable --now ollama || warn "ollama service not started (needs NVIDIA driver after reboot)"
  aur_install llama.cpp-cuda
  info "Creating ~/ai-env with PyTorch for Blackwell (CUDA 12.8 wheels)"
  [[ -d "$HOME/ai-env" ]] || uv venv "$HOME/ai-env"
  # shellcheck disable=SC1091
  source "$HOME/ai-env/bin/activate"
  uv pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu128
  python -c "import torch; print('CUDA available:', torch.cuda.is_available())" \
    || warn "Torch check failed - normal before the first reboot with the NVIDIA driver."
  deactivate
}

st_gaming() {
  info "Installing gaming stack"
  pac_install steam gamemode lib32-gamemode mangohud lib32-mangohud gamescope
  aur_install protonup-qt
  cat <<'EOF'
Steam launch option for any game (monitoring overlay + performance mode):
    gamemoderun mangohud %command%
Enable Proton: Steam > Settings > Compatibility > Steam Play for all titles.
Check games before installing: https://www.protondb.com
EOF
}

st_phone() {
  info "Installing phone / device integration"
  pac_install kdeconnect syncthing
  aur_install localsend-bin
  systemctl --user enable syncthing.service || true
}

st_security() {
  info "Configuring firewall (deny incoming, allow only what sync tools need)"
  pac_install ufw flatpak
  sudo ufw default deny incoming
  sudo ufw default allow outgoing
  sudo ufw allow 1714:1764/tcp comment 'KDE Connect'
  sudo ufw allow 1714:1764/udp comment 'KDE Connect'
  sudo ufw allow 22000/tcp comment 'Syncthing'
  sudo ufw allow 22000/udp comment 'Syncthing'
  sudo ufw allow 21027/udp comment 'Syncthing discovery'
  sudo ufw allow 53317 comment 'LocalSend'
  sudo ufw --force enable
  sudo systemctl enable --now ufw
}

st_snapshots() {
  if [[ "$(findmnt -no FSTYPE /)" != "btrfs" ]]; then
    warn "Root is not Btrfs - snapshots skipped."; return 0
  fi
  info "Setting up Snapper snapshots"
  pac_install snapper snap-pac
  if ! sudo snapper list-configs | grep -q '^root'; then
    mountpoint -q /.snapshots && sudo umount /.snapshots
    sudo rmdir /.snapshots 2>/dev/null || true
    sudo snapper -c root create-config /
    if grep -q '/.snapshots' /etc/fstab; then
      sudo btrfs subvolume delete /.snapshots
      sudo mkdir /.snapshots
      sudo mount -a
    fi
    sudo chmod 750 /.snapshots
  fi
  sudo systemctl enable --now snapper-timeline.timer snapper-cleanup.timer
  if command -v grub-mkconfig &>/dev/null; then
    pac_install grub-btrfs inotify-tools
    sudo systemctl enable --now grub-btrfsd
    sudo grub-mkconfig -o /boot/grub/grub.cfg
  else
    warn "GRUB not found: booting into snapshots needs grub-btrfs (or equivalent)."
  fi
  if [[ "$(findmnt -no FSTYPE /boot 2>/dev/null)" != "btrfs" ]]; then
    warn "/boot is NOT on Btrfs (probably the ESP). After a rollback the kernel can mismatch"
    warn "the restored modules. Safer layout: ESP at /efi, /boot inside the @ subvolume."
  fi
  sudo snapper -c root create -d "myos-setup: baseline"
}

st_dotfiles() {
  info "Writing configs into $MYOS_DIR and linking them"
  mkdir -p "$MYOS_DIR"/{config/hypr,bin}
  [[ -d "$MYOS_DIR/.git" ]] || git -C "$MYOS_DIR" init -q

  local conf="$MYOS_DIR/config/hypr/hyprland.conf"
  if [[ ! -f "$conf" ]]; then
    cat > "$conf" <<EOF
# ~/myos/config/hypr/hyprland.conf  -  yours. Docs: https://wiki.hypr.land
monitor = , highrr, auto, 1

env = XCURSOR_SIZE,24
env = LIBVA_DRIVER_NAME,nvidia
env = __GLX_VENDOR_LIBRARY_NAME,nvidia
env = NVD_BACKEND,direct

\$mainMod = SUPER
\$terminal = kitty
\$files = thunar
\$menu = rofi -show drun

exec-once = waybar
exec-once = dunst
exec-once = hyprpaper
exec-once = wl-paste --watch cliphist store
exec-once = /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1

input {
    kb_layout = $KB_LAYOUT
    follow_mouse = 1
}

general {
    gaps_in = 6
    gaps_out = 12
    border_size = 2
    col.active_border = rgba(89b4faff)
    col.inactive_border = rgba(45475aff)
    layout = dwindle
}

decoration {
    rounding = 12
    blur {
        enabled = true
        size = 6
        passes = 3
    }
}

animations {
    enabled = true
}

misc {
    vrr = 1
}

bind = \$mainMod, RETURN, exec, \$terminal
bind = \$mainMod, E, exec, \$files
bind = \$mainMod, SPACE, exec, \$menu
bind = \$mainMod, Q, killactive
bind = \$mainMod, F, fullscreen
bind = \$mainMod, V, togglefloating
bind = \$mainMod, L, exec, hyprlock
bind = \$mainMod SHIFT, E, exec, wlogout
bind = \$mainMod SHIFT, M, exit
bind = \$mainMod, left, movefocus, l
bind = \$mainMod, right, movefocus, r
bind = \$mainMod, up, movefocus, u
bind = \$mainMod, down, movefocus, d
bind = , Print, exec, grim -g "\$(slurp)" - | wl-copy
bind = \$mainMod ALT, 1, exec, myos profile work
bind = \$mainMod ALT, 2, exec, myos profile gaming
bind = \$mainMod ALT, 3, exec, myos profile ai
bindm = \$mainMod, mouse:272, movewindow
bindm = \$mainMod, mouse:273, resizewindow
EOF
    local i
    for i in 1 2 3 4 5 6 7 8 9; do
      echo "bind = \$mainMod, $i, workspace, $i" >> "$conf"
      echo "bind = \$mainMod SHIFT, $i, movetoworkspace, $i" >> "$conf"
    done
  fi
  link "$conf" "$HOME/.config/hypr/hyprland.conf"

  # start Hyprland from TTY1 via uwsm
  if ! grep -q 'uwsm start' "$HOME/.bash_profile" 2>/dev/null; then
    cat >> "$HOME/.bash_profile" <<'EOF'

# myos: start Hyprland on login at TTY1
if uwsm check may-start && uwsm select; then
    exec uwsm start default
fi
EOF
  fi
  git -C "$MYOS_DIR" add -A && git -C "$MYOS_DIR" commit -qm "myos: initial config" || true
}

st_cli() {
  info "Installing the 'myos' operator command"
  mkdir -p "$MYOS_DIR/bin" "$HOME/.local/bin"
  cat > "$MYOS_DIR/bin/myos" <<'EOF'
#!/usr/bin/env bash
# myos - you are the operator.
set -euo pipefail
MYOS_DIR="${MYOS_DIR:-$HOME/myos}"
case "${1:-help}" in
  snapshot)  sudo snapper -c root create -d "${2:-manual}"; sudo snapper -c root list | tail -5 ;;
  check)     echo "Pending updates:"; checkupdates || true
             command -v yay &>/dev/null && yay -Qua || true
             echo "Read https://archlinux.org/news before updating." ;;
  update)    echo "Read https://archlinux.org/news first. Continue? [y/N]"; read -r a; [[ $a == y ]] || exit 0
             sudo snapper -c root create -d "pre-update $(date +%F)" || echo "(no snapshot taken!)"
             sudo pacman -Syu
             command -v yay &>/dev/null && yay -Sua
             echo "Reboot if kernel or NVIDIA driver changed." ;;
  rollback)  echo "Reboot and pick a snapshot in the GRUB 'Arch Linux snapshots' menu,"
             echo "then restore with snapper (see ArchWiki: Snapper#Restoring)."; sudo snapper -c root list ;;
  save)      git -C "$MYOS_DIR" add -A && git -C "$MYOS_DIR" commit -m "${2:-config update}" ;;
  status)    nvidia-smi --query-gpu=name,driver_version,temperature.gpu,memory.used,memory.total --format=csv
             sudo snapper -c root list | tail -3; sudo ufw status | head -3 ;;
  profile)   case "${2:-}" in
               work)   hyprctl dispatch workspace 1; hyprctl keyword decoration:blur:enabled true
                       notify-send "Profile: Work" ;;
               gaming) hyprctl dispatch workspace 2; hyprctl keyword decoration:blur:enabled false
                       notify-send "Profile: Gaming (blur off)" ;;
               ai)     hyprctl dispatch workspace 3; notify-send "Profile: AI" ;;
               *) echo "usage: myos profile work|gaming|ai"; exit 1 ;;
             esac ;;
  *) echo "usage: myos snapshot|check|update|rollback|save|status|profile <name>" ;;
esac
EOF
  chmod +x "$MYOS_DIR/bin/myos"
  ln -sfn "$MYOS_DIR/bin/myos" "$HOME/.local/bin/myos"
  git -C "$MYOS_DIR" add -A && git -C "$MYOS_DIR" commit -qm "myos: add CLI" || true
  info "Done. Reboot, log in on TTY1 and Hyprland will start. Try:  myos status"
}

# ---------- main -------------------------------------------------------------
main() {
  if [[ "${1:-}" == "--list" || "${1:-}" == "--help" ]]; then
    printf 'Stages: %s\n' "${ALL_STAGES[*]}"; exit 0
  fi
  mkdir -p "$MYOS_DIR"
  exec > >(tee -a "$LOG") 2>&1
  local stages=("$@")
  ((${#stages[@]})) || stages=("${ALL_STAGES[@]}")
  # sudo keep-alive
  sudo -v
  ( while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) &
  local s
  for s in "${stages[@]}"; do
    declare -F "st_$s" >/dev/null || die "Unknown stage: $s"
    st_"$s"
  done
  info "All requested stages finished. Log: $LOG"
}
main "$@"
