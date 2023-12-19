#!/bin/bash
set -euo pipefail


script_dir=$(dirname "$(readlink -f "$0")")
disk="$1"
cpu_vendor=$(grep "vendor_id" /proc/cpuinfo | head -n 1 | awk '{print $3}')

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

timedatectl set-ntp true
# The updated mirrorlist will be transferred over with pacstrap
reflector -l 5 -p https  --sort rate --save /etc/pacman.d/mirrorlist
# Make sure these are updated
pacman -Sy --needed --noconfirm git python reflector

# This doesn't really work on SSDs  
read -rp "Shred disk before continuing? [y/N] " yn
yn=${yn:-N}
      
case "$yn" in
  [yY]) 
    # https://wiki.archlinux.org/title/Securely_wipe_disk#shred
    shred -v -n1 "$disk"
    ;;
  *) 
    ;;
esac
  
sgdisk -Z "$disk"

echo -e "\nCreating EFI and root partitions"
# Creating an unencrypted EFI system partition with a FAT file system, and a root 
# partition spanning the rest of the disk. The -t flags make sure that systemd 
# will automatically discover our filesystems meaning we don't need fstab or crypttab:
# https://wiki.archlinux.org/title/dm-crypt/Encrypting_an_entire_system#Simple_encrypted_root_with_TPM2_and_Secure_Boot
sgdisk -n 0:0:+512MiB -t 0:ef00 -c 0:EFISYSTEM "$disk"
sgdisk -n 0:0:0 -t 0:8304 -c 0:linux "$disk"
sgdisk -p "$disk"
  
echo -e "\nEncrypting root"
# Then we encrypt the root partition. This prompts for an encryption password
# which we set to an easy one since we will remove and replace it later.
cryptsetup luksFormat --type luks2 /dev/disk/by-partlabel/linux

echo -e "\nOpening encrypted root"
cryptsetup luksOpen /dev/disk/by-partlabel/linux root

echo -e "\nUpdating root parameters"
# https://wiki.archlinux.org/title/Dm-crypt/Specialties#Discard/TRIM_support_for_solid_state_drives_(SSD)
# https://wiki.archlinux.org/title/Dm-crypt/Specialties#Disable_workqueue_for_increased_solid_state_drive_(SSD)_performance
cryptsetup refresh --allow-discards --perf-no_read_workqueue --perf-no_write_workqueue --persistent root

mkfs.fat -F32 -n EFISYSTEM /dev/disk/by-partlabel/EFISYSTEM
mkfs.btrfs -f -L linux /dev/mapper/root
  
# We then mount the root to set up some btrfs subvolumes. The number of volumes
# here is chosen to exclude var/cache var/log and var/tmp from any snapshots
# of /, but not really necessary. 
mount /dev/mapper/root /mnt
mount --mkdir /dev/disk/by-partlabel/EFISYSTEM /mnt/efi
  
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@cache
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@tmp

# I had to put systemd-ukify in here to fix some errors when running kernel-install later. 
base_packages=(base base-devel linux linux-firmware btrfs-progs mkinitcpio plymouth
  systemd-ukify cryptsetup binutils elfutils sudo fish sbctl sbsigntools fwupd git vifm pacman-contrib)

# There are more vendor strings listed here: 
# https://en.wikipedia.org/wiki/CPUID#Calling_CPUID
if [[ "$cpu_vendor" == "GenuineIntel" ]]; then
  base_packages+=(intel-ucode)
elif [[ "$cpu_vendor" == "AuthenticAMD" ]]; then
  base_packages+=(amd-ucode)
fi

if echo "${gpu_vendors[@]}" | grep -q "\bnvidia\b"; then
  base_packages+=(dkms linux-headers nvidia-dkms nvidia-utils nvidia-settings)
fi
 
if echo "${gpu_vendors[@]}" | grep -q "\bamd\b"; then
  base_packages+=(mesa vulkan-radeon)
fi

if echo "${gpu_vendors[@]}" | grep -q "\bintel\b"; then
  base_packages+=(mesa vulkan-intel)
fi

# Bootstrapping the filesystem
pacstrap /mnt "${base_packages[@]}" 

systemd-firstboot --force --root /mnt \
  --keymap=no-latin1 \
  --locale=en_US.UTF-8 \
  --timezone=Europe/Oslo \
  --prompt-root-password \
  --prompt-hostname 

sed -i "s/^#\(en_US.UTF-8\)/\1/" /mnt/etc/locale.gen
sed -i "s/^#\(no_NB.UTF-8\)/\1/" /mnt/etc/locale.gen
arch-chroot /mnt locale-gen
arch-chroot /mnt hwclock --systohc --utc

install -vm755 -d /mnt/etc/modprobe.d
install -vm644 "$script_dir/etc/modprobe-blacklist.conf" /mnt/etc/modprobe.d/blacklist.conf
install -vm644 "$script_dir/etc/modprobe-power.conf" /mnt/etc/modprobe.d/power.conf

# install -vm644 "$script_dir/etc/cmdline-nvidia.conf" /mnt/etc/cmdline.d/nvidia.conf 

# https://wiki.archlinux.org/title/Unified_kernel_image#kernel-install 
# Use kernel-install to install UKI kernels to the esp, and mask the mkinitcpio
# pacman hooks. Requires a pacman hook for kernel-install that is installed later.
install -vpm644 "$script_dir/etc/kernel-install.conf" /mnt/etc/kernel/install.conf
install -vpm644 "$script_dir/etc/kernel-uki.conf" /mnt/etc/kernel/uki.conf
install -vpm644 "$script_dir/etc/kernel-cmdline" /mnt/etc/kernel/cmdline

if echo "${gpu_vendors[@]}" | grep -q "\bnvidia\b"; then
  echo -n " nvidia_drm.modeset=1" >> /mnt/etc/kernel/cmdline
fi

install -m755 -d /mnt/etc/pacman.d/hooks
ln -sf /dev/null /mnt/etc/pacman.d/hooks/60-mkinitcpio-remove.hook
ln -sf /dev/null /mnt/etc/pacman.d/hooks/90-mkinitcpio-install.hook



FILES=()
MODULES=()
HOOKS=(base systemd keyboard autodetect modconf sd-vconsole sd-encrypt block filesystems fsck)

install -vm755 -d /mnt/etc/mkinitcpio.conf.d

# https://wiki.archlinux.org/title/Kernel_mode_setting#Early_KMS_start
if echo "${gpu_vendors[@]}" | grep -q "\bnvidia\b"; then
  # https://wiki.archlinux.org/title/NVIDIA#DRM_kernel_mode_setting
  install -vm644 "$script_dir/etc/modprobe-nvidia.conf" /mnt/etc/modprobe.d/nvidia.conf
  MODULES+=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)
fi
 
if echo "${gpu_vendors[@]}" | grep -q "\bamd\b"; then
  MODULES+=(amdgpu)
  HOOKS+=(kms)
fi

if echo "${gpu_vendors[@]}" | grep -q "\bintel\b"; then
  MODULES+=(i915)
  HOOKS+=(kms)
fi

cat > /mnt/etc/mkinitcpio.conf.d/base.conf <<EOF
  FILES=(${FILES[@]})
  HOOKS=(${HOOKS[@]})
  MODULES=(${MODULES[@]})
EOF

echo -e "\nInstalling bootloader"
bootctl --root /mnt install
install -vpm644 "$script_dir/etc/loader.conf" /mnt/efi/loader/loader.conf

echo -e "\nSetting up secure boot"
# https://wiki.archlinux.org/title/Unified_Extensible_Firmware_Interface/Secure_Boot#Automatic_signing_with_the_pacman_hook
arch-chroot /mnt bash -c "
  sbctl create-keys
  sbctl sign -s /efi/EFI/BOOT/BOOTX64.EFI
  sbctl sign -s /efi/EFI/systemd/systemd-bootx64.efi
  sbctl sign -s -o /usr/lib/fwupd/efi/fwupdx64.efi.signed /usr/lib/fwupd/efi/fwupdx64.efi
  sbctl sign -s -o /usr/lib/systemd/boot/efi/systemd-boot64.efi.signed /usr/lib/systemd/boot/efi/systemd-bootx64.efi
"

echo -e "\nInstalling kernel"
# https://github.com/swsnr/dotfiles/blob/db42fe95fceeac68e4fbe489aed5e310f65b1ae7/arch/bootstrap-from-iso.bash#L131
kernel_versions=(/mnt/usr/lib/modules/*)
kernel_version="${kernel_versions[0]##*/}"
arch-chroot /mnt kernel-install add "${kernel_version}" \
   "/usr/lib/modules/${kernel_version}/vmlinuz"


read -p "Enroll secure boot keys? [y/N] " enroll_keys
enroll_keys=${enroll_keys:-N}
case "$enroll_keys" in
  [yY]) 
    arch-chroot /mnt sbctl enroll-keys --microsoft
    ;;
  *) 
    ;;
esac


#bootctl --root /mnt update

echo -e "\nCreating new user"
read -p "Enter username: " username
useradd -R /mnt -m -s /usr/bin/zsh "$username"
usermod -R /mnt -aG wheel,storage,power "$username"
passwd -R /mnt "$username"

install -vdm750 /mnt/etc/sudoers.d/
install -vpm600 "$script_dir/etc/sudoers-wheel" /mnt/etc/sudoers.d/wheel

# Set up dotfiles in home as a bare repository
# https://www.atlassian.com/git/tutorials/dotfiles
git_cmd="git --git-dir=/home/$username/.dotfiles/ --work-tree=/home/$username"
arch-chroot /mnt bash -c "sudo -u $username git clone --bare https://github.com/dborseth/.dotfiles.git /home/$username/.dotfiles"
arch-chroot /mnt bash -c "sudo -u $username $git_cmd config --local status.showUntrackedFiles no"
arch-chroot /mnt bash -c "sudo -u $username $git_cmd checkout"



extra_packages=(
  networkmanager iwd openssh 
  blueman bluez bluez-utils usbutils nvme-cli 
  htop nvtop powertop tlp 
  apparmor audit snapper zram-generator lm_sensors 
  git man-db man-pages util-linux eza fzf ripgrep fd curl imv jq zellij  
  greetd greetd-agreety firefox wireguard-tools
  polkit-gnome xdg-desktop-portal-hyprland qt6-wayland qt5-wayland slurp grim 
  swaybg swayidle mako wofi foot gtk-engine-murrine wl-clipboard
  pipewire wireplumber pipewire-jack pipewire-alsa pipewire-pulse pavucontrol
  ttf-cascadia-code noto-fonts adobe-source-serif-fonts inter-font otf-font-awesome 
  tpm2-tools libfido2 pcsc-tools pam-u2f gnupg ccid gcr
)

aur_packages=(aurutils amdctl pacman-hook-kernel-install auto-cpufreq gtklock 
  helix-git hyprland-nvidia hyprpicker-git plymouth-theme-neat
  ironbar-git blueberry-wayland colloid-gtk-theme-git colloid-icon-theme-git apple_cursor)

# Sets up a local aur repository and syncs the list of aur packages to the repo.
# The packages are then installed along with the other packages in the pacman repo. 
# TODO Move the repository to one of the servers to remove this step
echo -e "\n Setting up local AUR repository"
arch-chroot /mnt install -vd /var/cache/pacman/aur -o "$username"
arch-chroot /mnt bash -c "
  sudo -u $username git clone https://aur.archlinux.org/aurutils.git /home/$username/aurutils 
  cd /home/$username/aurutils && sudo -u $username makepkg -si --noconfirm
  sudo -u rm -rf /home/$username/aurutils
  sudo -u $username repo-add /var/cache/pacman/aur/aur.db.tar
"

# Add pacman config that includes a custom repository pointing to /var/cache/pacman/aur.
# We have to do it after installing aurutils so that it doesn't try to find the 
# custom repo before it exists.
install -vpm644 "$script_dir/etc/pacman.conf" /mnt/etc/pacman.conf
arch-chroot /mnt pacman -Sy

echo -e "\nSyncing AUR packages to local repository"
for package in "${aur_packages[@]}"; do
  arch-chroot /mnt bash -c "sudo -u $username aur sync --noview -n $package"
done

echo -e "\nInstalling additional packages"
extra_packages+=("${aur_packages[@]}")
arch-chroot /mnt pacman -Sy --needed "${extra_packages[@]}"

echo -e "\nConfiguring additional packages"

arch-chroot /mnt bash -c "
  ln -sf /usr/share/fontconfig/conf.avail/70-no-bitmaps.conf /etc/fonts/conf.d
  ln -sf /usr/share/fontconfig/conf.avail/10-sub-pixel-rgb.conf /etc/fonts/conf.d
  ln -sf /usr/share/fontconfig/fonts/conf.avail/11-lcdfilter-default.conf /etc/fonts/conf.d
"
install -vpm644 "$script_dir/etc/fonts-freetype2.sh" /mnt/etc/profile.d/freetype2.sh
install -vpm644 "$script_dir/etc/fonts-local.conf" /mnt/etc/fonts/local.conf 

install -m755 -d /mnt/usr/share/backgrounds
install -vpm755 "$script_dir/usr/default.png" /mnt/usr/share/backgrounds/default.png
install -vpm644 "$script_dir/etc/plymouthd.conf" /mnt/etc/plymouth/plymouthd.conf

cat > /mnt/etc/greetd/config.toml <<EOF
[terminal]
vt = 1

[default_session]
command = "agreety --cmd Hyprland"
user = "greeter"

[initial_session]
command = "Hyprland"
user = "$username"
EOF

# https://wiki.archlinux.org/title/NetworkManager#systemd-resolved
# https://wiki.archlinux.org/title/NetworkManager#Using_iwd_as_the_Wi-Fi_backend
install -vm755 -d /mnt/etc/NetworkManager.conf.d
install -vpm644 "$script_dir/etc/networkmanager-wifi.conf" /mnt/etc/NetworkManager/conf.d/wifi.conf
ln -sf /run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf


echo -e "\nEnabling systemd services"
systemctl --root /mnt enable \
  systemd-boot-update.service \
  systemd-timesyncd.service \
  systemd-resolved.service \
  NetworkManager.service \
  bluetooth.service \
  fstrim.timer \
  greetd.service \
  apparmor.service \
  pcscd.service \
  paccache.timer


echo -e '\n*** Installation script finished, cleaning up'

umount -R /mnt
cryptsetup luksClose root