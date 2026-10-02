<#
.SYNOPSIS
  Bootstrap a fresh Windows 10/11 machine: WezTerm + config, JetBrainsMono Nerd Font, Neovim + LazyVim deps,
  tree-sitter-cli, nvm-windows + Node + pnpm.

.DESCRIPTION
  Run from an ELEVATED PowerShell (nvm-windows needs admin for `nvm use`):
      Set-ExecutionPolicy -Scope Process Bypass
      .\setup-windows.ps1

.PARAMETER SkipPlugins
  Don't pre-install Neovim plugins at the end.

.PARAMETER NodeVersion
  Passed to `nvm install` (default "lts"; "latest" for newest, or e.g. "24.0.0").
#>
[CmdletBinding()]
param(
    [switch]$SkipPlugins,
    [string]$NodeVersion = "lts"
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------- settings
$WeztermConfigRepo = "https://github.com/InstaFall/wezterm-config.git"
$NvimConfigRepo    = "https://github.com/InstaFall/nvim-config.git"
$TsFallbackTag     = "v0.27.0"

$BinDir          = Join-Path $HOME ".local\bin"
$WeztermRepoDir  = Join-Path $HOME ".config\wezterm-config"
$NvimConfigDir   = Join-Path $env:LOCALAPPDATA "nvim"
$Stamp           = Get-Date -Format "yyyyMMdd-HHmmss"
$Work            = Join-Path $env:TEMP "dev-setup-$Stamp"
New-Item -ItemType Directory -Force -Path $Work, $BinDir | Out-Null

# ---------------------------------------------------------------- helpers
function Log($msg)  { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Warn($msg) { Write-Host "WARN: $msg" -ForegroundColor Yellow }
function Have($cmd) { [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

function Refresh-Path {
    $m = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $u = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$m;$u"
}

function Add-UserPath($dir) {
    $cur = [Environment]::GetEnvironmentVariable("Path", "User")
    if (($cur -split ";") -notcontains $dir) {
        [Environment]::SetEnvironmentVariable("Path", ($cur.TrimEnd(";") + ";" + $dir), "User")
    }
    Refresh-Path
}

function Winget-Install($id) {
    Log "winget install $id"
    winget install --id $id -e --silent --accept-package-agreements --accept-source-agreements
    # -1978335189 = "no applicable upgrade" (already installed & current)
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
        Warn "winget exited with code $LASTEXITCODE for $id (may already be installed)"
    }
}

function Backup-IfExists($path) {
    if (Test-Path $path) {
        $bak = "$path.bak.$Stamp"
        Move-Item $path $bak
        Warn "Existing $path moved to $bak"
    }
}

function Clone-OrUpdate($url, $dest) {
    if ((Test-Path (Join-Path $dest ".git")) -and ((git -C $dest remote get-url origin 2>$null) -eq $url)) {
        Log "Updating $dest"
        git -C $dest pull --ff-only
        if ($LASTEXITCODE -ne 0) { Warn "Could not fast-forward $dest - left as is" }
    } else {
        Backup-IfExists $dest
        New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
        git clone $url $dest
    }
}

function Write-Utf8NoBom($path, $text) {
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding $false))
}

# ---------------------------------------------------------------- preflight
if (-not (Have winget)) {
    throw "winget not found. Install 'App Installer' from the Microsoft Store, then re-run."
}
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Warn "Not running as Administrator. nvm-windows needs admin for 'nvm use' - Node setup may fail."
}

# ---------------------------------------------------------------- packages (winget)
$packages = @(
    "Git.Git",
    "wez.wezterm",
    "DEVCOM.JetBrainsMonoNerdFont",   # the font family is "JetBrainsMono Nerd Font"
    "Neovim.Neovim",
    "JesseDuffield.lazygit",
    "junegunn.fzf",
    "BurntSushi.ripgrep.MSVC",
    "sharkdp.fd",
    "zig.zig",                        # C compiler for nvim-treesitter (zig cc is supported)
    "CoreyButler.NVMforWindows"
)
foreach ($p in $packages) { Winget-Install $p }
Refresh-Path
Add-UserPath $BinDir

if (-not (Have git)) { throw "git not found on PATH after install - open a new elevated PowerShell and re-run." }

# ---------------------------------------------------------------- tree-sitter CLI (GitHub release)
Log "Installing tree-sitter-cli (from tree-sitter/tree-sitter releases)"
function Install-TreeSitter($url) {
    $zip = Join-Path $Work "ts.zip"
    $out = Join-Path $Work "ts"
    if (Test-Path $out) { Remove-Item $out -Recurse -Force }
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip
        Expand-Archive -Path $zip -DestinationPath $out -Force
    } catch { return $false }
    $exe = Get-ChildItem $out -Recurse -Filter "tree-sitter*.exe" | Select-Object -First 1
    if (-not $exe) { return $false }
    Copy-Item $exe.FullName (Join-Path $BinDir "tree-sitter.exe") -Force
    return $true
}
$tsBase = "https://github.com/tree-sitter/tree-sitter/releases"
if (-not (Install-TreeSitter "$tsBase/latest/download/tree-sitter-cli-windows-x64.zip")) {
    Warn "Latest tree-sitter download failed, trying $TsFallbackTag"
    if (-not (Install-TreeSitter "$tsBase/download/$TsFallbackTag/tree-sitter-cli-windows-x64.zip")) {
        throw "Could not download tree-sitter-cli"
    }
}
& (Join-Path $BinDir "tree-sitter.exe") --version

# ---------------------------------------------------------------- Node via nvm-windows + pnpm
Log "Installing Node ($NodeVersion) via nvm-windows, then pnpm"
Refresh-Path
if (Have nvm) {
    nvm install $NodeVersion
    nvm use $NodeVersion
    Refresh-Path
    if (Have npm) {
        npm install -g pnpm
        Write-Host "node $(node --version), npm $(npm --version), pnpm $(pnpm --version)"
    } else {
        Warn "npm not on PATH yet - open a new terminal, then run: npm install -g pnpm"
    }
} else {
    Warn "nvm not on PATH yet - open a new ELEVATED terminal and run: nvm install lts; nvm use lts; npm install -g pnpm"
}

# ---------------------------------------------------------------- WezTerm config
Log "Setting up WezTerm config"
Clone-OrUpdate $WeztermConfigRepo $WeztermRepoDir

# ~/.wezterm.lua is a tiny wrapper that loads the repo config, points the background image at the repo copy
# (the repo hard-codes C:\Users\Can\...), and puts the repo's wezterm/ folder on package.path for cyberdream.
$wrapperPath = Join-Path $HOME ".wezterm.lua"
if ((Test-Path $wrapperPath) -and -not (Select-String -Path $wrapperPath -Pattern "managed by setup-windows.ps1" -Quiet)) {
    Backup-IfExists $wrapperPath
}
$wrapper = @'
-- managed by setup-windows.ps1 (wrapper around the InstaFall/wezterm-config repo)
local wezterm = require("wezterm")
local repo = wezterm.home_dir:gsub("\\", "/") .. "/.config/wezterm-config"

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
'@
Write-Utf8NoBom $wrapperPath ($wrapper -replace "`r`n", "`n")

# ---------------------------------------------------------------- Neovim (LazyVim) config
Log "Setting up Neovim config"
Clone-OrUpdate $NvimConfigRepo $NvimConfigDir

if (-not $SkipPlugins) {
    if (Have nvim) {
        Log "Pre-installing Neovim plugins (headless)"
        nvim --headless "+Lazy! sync" +qa
        if ($LASTEXITCODE -ne 0) { Warn "Plugin sync didn't finish cleanly - just open nvim and let Lazy finish" }
    } else {
        Warn "nvim not on PATH yet - open a new terminal and start nvim to install plugins"
    }
}

# ---------------------------------------------------------------- summary
Log "Done. Open a NEW terminal so PATH changes apply."
foreach ($t in "git", "nvim", "lazygit", "fzf", "rg", "fd", "zig", "tree-sitter", "node", "pnpm", "wezterm") {
    if (Have $t) { Write-Host ("  {0,-12} found" -f $t) } else { Write-Host ("  {0,-12} MISSING (new terminal needed?)" -f $t) -ForegroundColor Yellow }
}
Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue
