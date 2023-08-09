conf_dir=/tmp/arch-setup/etc

packages=(iwd networkmanager zsh bluez bluez-utils usbutils nvme-cli htop nvtop powertop util-linux apparmor snapper nvim man-db man-pages exa fzf ripgrep fd zram-generator audit plymouth greetd greetd-agreety greetd-tuigreet blueman pacman-contrib lm_sensors polkit-kde-agent xdg-desktop-portal-hyprland qt6-wayland qt5-wayland slurp grim swaybg swayidle mako pipewire wireplumber ttf-cascadia-code inter-font curl tlp)

cpu_vendor=$(grep "vendor_id" /proc/cpuinfo | head -n 1 | awk '{print $3}')
if [[ "$cpu_vendor" == "GenuineIntel" ]]; then
  packages+=("intel-ucode")
elif [[ "$cpu_vendor" == "AuthenticAMD" ]]; then
  packages+=("amd-ucode")
fi

gpus=$(lspci | grep -i "VGA compatible controller")
gpu_vendors=()
while read -r line; do
  gpu_vendor=$(echo "$line" | cut -d " " -f 5-)

  if [[ $gpu_vendor == *"NVIDIA"* ]]; then
    gpu_vendors+=("nvidia")
  elif [[ $gpu_vendor == *"Intel"* ]]; then
    gpu_vendors+=("intel")
  elif [[ $gpu_vendor == *"Advanced Micro Devices"* ]]; then
    gpu_vendors+=("amd")
  fi
done <<< "$gpus"


echo -e "\n** Configuring system"

read -p "Enter time zone: " timezone
echo "Setting time zone to $timezone"
ln -sf /usr/share/zoneinfo/$timezone /etc/localtime
hwclock --systohc --utc

read -p "Enter hostname: " hostname
echo "Setting hostname to $hostname"
echo "$hostname" >> /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1  localhost
::1        localhost
127.0.0.1  $hostname.localdomain $hostname
EOF

read -p "Enter keymap: " keymap
echo "KEYMAP=$keymap" >> /etc/vconsole.conf

read -p "Enter locale: " locale
echo 'LANG=$locale' >> /etc/locale.conf
sed -i "s/^#\($locale\)/\1/" /etc/locale.gen
locale-gen

echo -e "\n** Installing configuration files"
install -m755 -d /etc/cmdline.d
install -m644 "$conf_dir/cmdline.d/boot.conf" /etc/cmdline.d/boot.conf 
install -m644 "$conf_dir/cmdline.d/zram.conf" /etc/cmdline.d/zram.conf 
install -m644 "$conf_dir/cmdline.d/btrfs.conf" /etc/cmdline.d/btrfs.conf 
install -m644 "$conf_dir/cmdline.d/security.conf" /etc/cmdline.d/security.conf 

# https://wiki.archlinux.org/title/Unified_kernel_image#kernel-install 
# Use kernel-install to install UKI kernels to the esp, and mask the mkinitcpio
# pacman hooks. Requires a pacman hook for kernel-install that is installed later.
install -pm644 "$conf_dir/kernel/install.conf" /etc/kernel/install.conf
ln -sf /dev/null /etc/pacman.d/hooks/60-mkinitcpio-remove.hook
ln -sf /dev/null /etc/pacman.d/hooks/90-mkinitcpio-install.hook

install -m644 "$conf_dir/mkinitcpio.conf.d/base.conf" /etc/mkinitcpio.conf.d/base.conf 

if echo "${gpu_vendors[@]}" | grep -q "\bnvidia\b"; then
  # Use dkms for nvidia because it usually works
  packages+=("dkms" "linux-headers" "nvidia-dkms" "nvidia-utils" "nvidia-settings" "nvidia-smi")
  install -m644 "$conf_dir/cmdline.d/nvidia.conf" /etc/cmdline.d/nvidia.conf
  install -m644 "$conf_dir/mkinitcpio.conf.d/nvidia.conf" /etc/mkinitcpio.conf.d/nvidia.conf
fi
 
if echo "${gpu_vendors[@]}" | grep -q "\bamd\b"; then
  packages+=("mesa" "vulkan-radeon")
  install -m644 "$conf_dir/mkinitcpio.conf.d/amd.conf" /etc/mkinitcpio.conf.d/amd.conf
fi

if echo "${gpu_vendors[@]}" | grep -q "\bintel\b"; then
  packages+=("mesa" "vulkan-intel")
  install -m644 "$conf_dir/mkinitcpio.conf.d/intel.conf" /etc/mkinitcpio.conf.d/intel.conf
fi

install -pm644 "$conf_dir/loader.conf" /efi/loader/loader.conf
install -pm644 "$conf_dir/pacman.conf" /etc/pacman.conf

ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
install -Dpm644 "$conf_dir/networkmanager-wifi.conf" /etc/NetworkManager/conf.d/wifi.conf

# TODO greetd config

echo -e "\n** Installing additional packages: "
# TODO Move the repository to one of the servers, remember the mirrorlist
git clone https://aur.archlinux.org/aurutils.git && cd aurutils && makepkg -si
install -d /var/cache/pacman/aur -o $username # TODO this doesnt exist
repo-add /var/cache/pacman/aur/aur.db.tar

aur_packages=(aurutils amdctl pacman-hook-kernel-install auto-cpufreq gtklock helix-git zsh-antidote hyprland-nvidia-git hyprpicker-git)

aur sync "${aur_packages[@]}"
packages+=("${aur_packages}")

# if [[ "$cpu_vendor" == "GenuineIntel" ]]; then
  # remove amdctl
  # install throttld
# elif [[ "$cpu_vendor" == "AuthenticAMD" ]]; then 
  # remove throttld
#fi

echo -e "\n ${packages[@]}"
pacman -S --noconfirm "${packages[@]}"

echo -e "\n** Generate new initramfs"
mkinitcpio -P

echo -e '\n** Installing bootloader'
bootctl install

echo -e "\n** Setting up secure boot"
sbctl status

echo "\n* Creating keys"
sbctl create-keys

sbctl sign -s
sbctl sign -s -o /usr/lib/fwupd/efi/fwupdx64.efi.signed /usr/lib/fwupd/efi/fwupdx64.efi
sbctl sign -s -o /usr/lib/systemd/boot/efi/systemd-boot64.efi.signed /usr/lib/systemd/boot/efi/systemd-bootx64.efi

sbctl sign-all
sbctl verify

bootctl update --graceful

#sbctl enroll-keys -m

services=(
  systemd-boot-update.service
  systemd-oomd.service
  systemd-timesyncd.service
  systemd-resolved.service
  iwd.service
  NetworkManager.service
  bluetooth.service
  auditd.service
  apparmor.service
  fstrim.service
  fwupd.service
  snapper.service
  paccache.timer
  tlp.service
)

systemctl enable "${services[@]}"

