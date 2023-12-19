#!/bin/bash

aur_packages=(
  clickhouse-client-bin 
  terraform-ls 
  cmake-language-server 
  nvidia-container-toolkit
  dockerfile-language-server
  sql-language-server
)

for package in "${aur_packages[@]}"; do
  aur sync --noview -n "$package"
done


packages=(
  xh
  rsync
  rclone
  devtools

  docker
  docker-buildx
  docker-compose

  ansible
  terraform
  
  rustup 
  cargo-release
  cargo-deny
  cargo-watch
  lldb
  
  kubectl 
  kubectx 
  k9s 

  nodejs
  npm
  yarn
  typescript-language-server
  vscode-css-languageserver
  vscode-html-languageserver
  vscode-json-languageserver
  vscode-markdown-languageserver 
  prettier

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
  bash-language-server
  lua-language-server
    
  gdb
  gcc
  clang
  llvm
  lld 
  cmake
  meson
  ninja
  valgrind

  obsidian
  font-manager
)

sudo pacman -Sy --needed "${packages[@]}" "${aur_packages[@]}"

echo -e "\nSetting up Rust"  
rustup default stable
rustup toolchain install nightly
rustup component add rust-src
rustup component add rust-analyzer

echo -e "\nAdding groups"
sudo usermod --append --groups docker "$USER"

echo -e "\nStarting services"
systemctl enable --now \
  docker.service