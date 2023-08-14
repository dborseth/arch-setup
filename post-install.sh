#!/bin/sh

antidote update

gsettings set org.gnome.desktop.interface gtk-theme "Nordic"
gsettings set org.gnome.desktop.wm.preferences theme "Nordic"

# Using the yubikey for..
# - yk unlocs the disk, autologin ?
# - yk unlocs the disk, pin login ?
# - yk+pin unlocs the disk, autologin ?
# - TPM unlocks disk, yk for login ?
# - TPM unlocks disk, pin login
# - TPM+yk unlocks disk?
aur_packages=(clickhouse-client-bin terraform-ls cmake-language-server)

packages=(
  pcsc-tools 
  yubikey-personalization 
  yubikey-personalization-gui 
  yubikey-full-disk-encryption 
  libfido2
  opensc

  xh
  rsync
  rclone
  devtools
  clickhouse-client-bin

  docker
  docker-buildx
  docker-compose
  dockerfile-language-server

  ansible
  terraform
  terraform-ls  

  rustup 
  cargo-release
  cargo-deny
  cargo-watch
  sccache

  kubectl 
  kubectx 
  k9s 

  nodejs
  npm
  yarn
  typescript-language-server
  vscode-css-language-server 

  shellcheck 
  shfmt 

  python
  python-pipx
  python-poetry
  python-virtualenv
  ruff 
  # python-lsp-server
  pyright

  yaml-language-server
  ansible-language-server
  vscode-json-languageserver 

  gdb
  gcc
  clang 
  cmake
  cmake-language-server
  meson

  firefox
  obsidian
  font-manager
)

sudo pacman -Sy "${packages[@]}"


# Install rust toolchains  
rustup default stable
rustup toolchain install nightly
rustup component add rust-src
rustup component add rust-analyzer




systemctl enable pcscd.service
