#!/bin/sh

aur_packages=(clickhouse-client-bin terraform-ls cmake-language-server nvidia-container-toolkit)

packages=(
  yubikey-personalization 
  yubikey-personalization-gui 

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
  ninja
  valgrind

  obsidian
  font-manager
)

sudo pacman -Sy "${packages[@]}"

echo -e "\nSetting up Rust"  
rustup default stable
rustup toolchain install nightly
rustup component add rust-src
rustup component add rust-analyzer

echo -e "\nAdding groups"
usermod --append --groups docker $USER

echo -e "\nStarting services"
systemctl enable --now \
  docker.service