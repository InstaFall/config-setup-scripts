#!/usr/bin/env bash
# setup-linux.sh — bootstrap a fresh Ubuntu / Pop!_OS machine.
#
# Installs: wezterm (+ your config), JetBrainsMono Nerd Font, Neovim (latest release tarball),
# LazyVim deps (git, gcc, curl, fzf, ripgrep, fd, lazygit, tree-sitter-cli), nvm + Node + pnpm,
# and clones your nvim config.
#
# Run as your NORMAL user (it calls sudo only for apt). Everything else goes in ~/.local.
#
# Usage:  bash setup-linux.sh [--no-gui] [--skip-plugins]
#   --no-gui        skip wezterm + font (servers / WSL)
#   --skip-plugins  don't pre-install Neovim plugins at the end
# Env:    NODE_VERSION (default "lts/*"; use "node" for absolute latest, or e.g. "24")

set -euo pipefail

NO_GUI=0
SKIP_PLUGINS=0
for arg in "$@"; do
  case "$arg" in
    --no-gui) NO_GUI=1 ;;
    --skip-plugins) SKIP_PLUGINS=1 ;;
    -h | --help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------- settings
NODE_VERSION="${NODE_VERSION:-lts/*}"
WEZTERM_CONFIG_REPO="https://github.com/InstaFall/wezterm-config.git"
NVIM_CONFIG_REPO="https://github.com/InstaFall/nvim-config.git"
TS_FALLBACK_TAG="v0.27.0" # used only if "latest" download fails

BIN_DIR="$HOME/.local/bin"
OPT_DIR="$HOME/.local/opt"
FONT_DIR="$HOME/.local/share/fonts/JetBrainsMonoNerdFont"
WEZTERM_REPO_DIR="$HOME/.config/wezterm-config"
NVIM_CONFIG_DIR="$HOME/.config/nvim"
TS_STAMP="$(date +%Y%m%d-%H%M%S)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- helpers
log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# version_ge A B  -> true if A >= B
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

# latest_tag owner/repo -> e.g. v0.12.0 (follows the /releases/latest redirect, no API rate limit)
latest_tag() {
  curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest" | sed 's|.*/tag/||'
}

download() { curl -fL --retry 3 --retry-delay 2 -o "$2" "$1"; }

backup_if_exists() {
  if [ -e "$1" ] || [ -L "$1" ]; then
    mv "$1" "$1.bak.$TS_STAMP"
    warn "Existing $1 moved to $1.bak.$TS_STAMP"
  fi
}

# clone_or_update URL DEST  (keeps an existing clone of the same repo, backs up anything else)
clone_or_update() {
  local url="$1" dest="$2"
  if [ -d "$dest/.git" ] && [ "$(git -C "$dest" remote get-url origin 2>/dev/null || true)" = "$url" ]; then
    log "Updating $dest"
    git -C "$dest" pull --ff-only || warn "Could not fast-forward $dest (local changes?) — left as is"
  else
    backup_if_exists "$dest"
    mkdir -p "$(dirname "$dest")"
    git clone "$url" "$dest"
  fi
}

# ---------------------------------------------------------------- preflight
[ "$(id -u)" -ne 0 ] || die "Run this as your normal user, not root (it uses sudo for apt only)."
have sudo || die "sudo is required for the apt steps."
have apt-get || die "This script targets Debian/Ubuntu/Pop!_OS (apt)."

case "$(uname -m)" in
  x86_64 | amd64) NVIM_ARCH="x86_64"; TS_ARCH="x64";   LG_ARCH="x86_64"; FZF_ARCH="amd64" ;;
  aarch64 | arm64) NVIM_ARCH="arm64"; TS_ARCH="arm64"; LG_ARCH="arm64";  FZF_ARCH="arm64" ;;
  *) die "Unsupported CPU architecture: $(uname -m)" ;;
esac

mkdir -p "$BIN_DIR" "$OPT_DIR"
export PATH="$BIN_DIR:$PATH"

# ---------------------------------------------------------------- PATH in ~/.bashrc
log "Making sure ~/.local/bin is on PATH"
if ! grep -qF '# >>> dev-setup >>>' "$HOME/.bashrc" 2>/dev/null; then
  cat >>"$HOME/.bashrc" <<'EOF'

# >>> dev-setup >>>
export PATH="$HOME/.local/bin:$PATH"
# <<< dev-setup <<<
EOF
fi

# ---------------------------------------------------------------- apt packages
log "Installing apt packages"
sudo apt-get update
sudo apt-get install -y \
  git curl wget unzip tar xz-utils ca-certificates gpg \
  build-essential fontconfig \
  ripgrep fd-find

# Ubuntu ships fd as "fdfind"; LazyVim/fzf-lua look for "fd"
if ! have fd && have fdfind; then
  ln -sf "$(command -v fdfind)" "$BIN_DIR/fd"
fi

# ---------------------------------------------------------------- fzf (GitHub release; the apt one is too old)
log "Installing fzf (latest release)"
FZF_TAG="$(latest_tag junegunn/fzf)"
FZF_VER="${FZF_TAG#v}"
mkdir -p "$WORK/fzf"
download "https://github.com/junegunn/fzf/releases/download/${FZF_TAG}/fzf-${FZF_VER}-linux_${FZF_ARCH}.tar.gz" "$WORK/fzf.tar.gz"
tar -xzf "$WORK/fzf.tar.gz" -C "$WORK/fzf" fzf
install -m 0755 "$WORK/fzf/fzf" "$BIN_DIR/fzf"
# ~/.local/bin is first on PATH, so this wins over any older /usr/bin/fzf already on the machine
hash -r
echo "fzf $("$BIN_DIR/fzf" --version | awk '{print $1}')"
version_ge "$("$BIN_DIR/fzf" --version | awk '{print $1}')" "0.25.1" || warn "fzf is older than 0.25.1 — fzf-lua wants >= 0.25.1"

# ---------------------------------------------------------------- Neovim (release tarball)
log "Installing Neovim (latest release)"
download "https://github.com/neovim/neovim/releases/latest/download/nvim-linux-${NVIM_ARCH}.tar.gz" "$WORK/nvim.tar.gz"
mkdir -p "$WORK/nvim"
tar -xzf "$WORK/nvim.tar.gz" -C "$WORK/nvim" --strip-components=1
rm -rf "$OPT_DIR/nvim"
mv "$WORK/nvim" "$OPT_DIR/nvim"
ln -sf "$OPT_DIR/nvim/bin/nvim" "$BIN_DIR/nvim"
NVIM_VER="$(nvim --version | head -n1 | sed 's/^NVIM v//')"
echo "Neovim $NVIM_VER"
version_ge "${NVIM_VER%%-*}" "0.12.0" || warn "Neovim is older than 0.12 — check the release page"

# ---------------------------------------------------------------- tree-sitter CLI (GitHub release)
log "Installing tree-sitter-cli (from tree-sitter/tree-sitter releases)"
install_tree_sitter() {
  local url="$1"
  rm -rf "$WORK/ts" && mkdir -p "$WORK/ts"
  download "$url" "$WORK/ts/ts.zip" || return 1
  unzip -oq "$WORK/ts/ts.zip" -d "$WORK/ts/out" || return 1
  local bin
  bin="$(find "$WORK/ts/out" -type f -name 'tree-sitter*' | head -n1)"
  [ -n "$bin" ] || return 1
  install -m 0755 "$bin" "$BIN_DIR/tree-sitter"
}
TS_BASE="https://github.com/tree-sitter/tree-sitter/releases"
if ! install_tree_sitter "$TS_BASE/latest/download/tree-sitter-cli-linux-${TS_ARCH}.zip"; then
  warn "Latest tree-sitter download failed, trying $TS_FALLBACK_TAG"
  install_tree_sitter "$TS_BASE/download/${TS_FALLBACK_TAG}/tree-sitter-cli-linux-${TS_ARCH}.zip" \
    || die "Could not download tree-sitter-cli"
fi
if ! "$BIN_DIR/tree-sitter" --version; then
  warn "tree-sitter won't run (probably needs a newer glibc than this distro has)."
  warn "Workaround: install Rust (rustup) and run: cargo install tree-sitter-cli"
fi

# ---------------------------------------------------------------- lazygit
log "Installing lazygit"
LG_TAG="$(latest_tag jesseduffield/lazygit)"
LG_VER="${LG_TAG#v}"
mkdir -p "$WORK/lg"
download "https://github.com/jesseduffield/lazygit/releases/download/${LG_TAG}/lazygit_${LG_VER}_Linux_${LG_ARCH}.tar.gz" "$WORK/lg.tar.gz"
tar -xzf "$WORK/lg.tar.gz" -C "$WORK/lg" lazygit
install -m 0755 "$WORK/lg/lazygit" "$BIN_DIR/lazygit"

# ---------------------------------------------------------------- nvm + Node + pnpm
log "Installing nvm, Node ($NODE_VERSION) and pnpm"
export NVM_DIR="$HOME/.nvm"
if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  NVM_TAG="$(latest_tag nvm-sh/nvm)"
  curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_TAG}/install.sh" | PROFILE="$HOME/.bashrc" bash
fi
# nvm.sh isn't compatible with `set -u`
set +u
# shellcheck disable=SC1091
. "$NVM_DIR/nvm.sh"
nvm install "$NODE_VERSION"
nvm alias default "$NODE_VERSION"
nvm use default
set -u
npm install -g pnpm
echo "node $(node --version), npm $(npm --version), pnpm $(pnpm --version)"

# ---------------------------------------------------------------- WezTerm + font + config
if [ "$NO_GUI" -eq 0 ]; then
  log "Installing JetBrainsMono Nerd Font"
  mkdir -p "$FONT_DIR"
  download "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip" "$WORK/font.zip"
  unzip -oq "$WORK/font.zip" -d "$FONT_DIR"
  fc-cache -f "$HOME/.local/share/fonts"

  if [ "$(uname -m)" = "x86_64" ]; then
    if ! have wezterm; then
      log "Installing WezTerm (official apt repo)"
      curl -fsSL https://apt.fury.io/wez/gpg.key | sudo gpg --yes --dearmor -o /usr/share/keyrings/wezterm-fury.gpg
      echo 'deb [signed-by=/usr/share/keyrings/wezterm-fury.gpg] https://apt.fury.io/wez/ * *' \
        | sudo tee /etc/apt/sources.list.d/wezterm.list >/dev/null
      sudo chmod 644 /usr/share/keyrings/wezterm-fury.gpg
      sudo apt-get update
      sudo apt-get install -y wezterm
    else
      log "WezTerm already installed ($(wezterm --version))"
    fi
  else
    warn "No WezTerm apt package for $(uname -m) — skipping WezTerm itself"
  fi

  log "Setting up WezTerm config"
  clone_or_update "$WEZTERM_CONFIG_REPO" "$WEZTERM_REPO_DIR"

  # Your .wezterm.lua has Windows-only bits (C:\Users\Can\..., powershell.exe). Instead of editing the repo,
  # ~/.wezterm.lua is a tiny wrapper that loads the repo config, fixes those paths for this machine,
  # and puts the repo's wezterm/ folder on package.path so require("cyberdream") can find it.
  WRAPPER="$HOME/.wezterm.lua"
  if [ -e "$WRAPPER" ] && ! grep -qF 'managed by setup-linux.sh' "$WRAPPER"; then
    backup_if_exists "$WRAPPER"
  fi
  if [ -e "$HOME/.config/wezterm/wezterm.lua" ]; then
    warn "~/.config/wezterm/wezterm.lua exists and takes priority over ~/.wezterm.lua — remove it to use your config"
  fi
  cat >"$WRAPPER" <<'EOF'
-- managed by setup-linux.sh (wrapper around the InstaFall/wezterm-config repo)
local wezterm = require("wezterm")
local repo = wezterm.home_dir .. "/.config/wezterm-config"

package.path = repo .. "/wezterm/?.lua;" .. package.path
local config = dofile(repo .. "/.wezterm.lua")

-- background image: repo copy instead of C:\Users\Can\...
config.background = {
	{
		source = { File = repo .. "/stars-galaxy.jpg" },
		attachment = { Parallax = 0.1 },
	},
}

-- Windows-only settings: use the user's default shell on Linux/macOS
if not wezterm.target_triple:find("windows") then
	config.default_prog = nil
	config.win32_system_backdrop = nil
end

return config
EOF
fi

# ---------------------------------------------------------------- Neovim (LazyVim) config
log "Setting up Neovim config"
clone_or_update "$NVIM_CONFIG_REPO" "$NVIM_CONFIG_DIR"

if [ "$SKIP_PLUGINS" -eq 0 ]; then
  log "Pre-installing Neovim plugins (headless)"
  timeout 900 nvim --headless "+Lazy! sync" +qa || warn "Plugin sync didn't finish cleanly — just open nvim and let Lazy finish"
fi

# ---------------------------------------------------------------- summary
log "Done. Installed versions:"
for t in git gcc curl fzf rg fd lazygit tree-sitter nvim; do
  if have "$t"; then
    printf '  %-12s %s\n' "$t" "$("$t" --version 2>&1 | head -n1)"
  else
    printf '  %-12s MISSING\n' "$t"
  fi
done
have wezterm && printf '  %-12s %s\n' wezterm "$(wezterm --version)"
echo
echo "Open a new terminal (or run: source ~/.bashrc) so PATH and nvm are picked up."
echo "On first launch nvim may spend a minute installing treesitter parsers."
