#!/bin/bash

aur_packages=(
  clickhouse-client-bin 
  cmake-language-server 
  dockerfile-language-server
  nvidia-container-toolkit
  sql-language-server
  terraform-ls 
)

for package in "${aur_packages[@]}"; do
  aur sync --noview -n "$package"
done

packages=(
  ansible
  ansible-language-server
  bash-language-server
  cargo-deny
  cargo-release
  cargo-watch
  cilium-cli
  clang
  cmake
  devtools
  docker
  docker-buildx
  docker-compose
  dprint
  elixir
  elixir-ls
  eslint
  eslint-language-server
  fluxcd
  font-manager
  gcc
  gdb
  gitu
  k9s 
  kubectl 
  kubectx 
  lld 
  lldb
  llvm
  lua-language-server
  meson
  nodejs
  ninja
  npm
  prettier
  python
  python-pipx
  python-poetry
  python-virtualenv
  # python-lsp-server
  pyright
  rsync
  rclone
  ruff 
  rustup 
  shellcheck 
  shfmt 
  sql-language-server
  terraform
  typescript-language-server
  valgrind
  vscode-css-languageserver
  vscode-html-languageserver
  vscode-json-languageserver
  vscode-markdown-languageserver 
  xh
  yaml-language-server
  yarn
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
