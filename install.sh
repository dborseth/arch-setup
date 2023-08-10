#!/bin/bash
set -euo pipefail


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



systemd-firstboot --force \
  --keymap=no-latin1 \
  --locale=en_US.UTF-8 \
  --timezone=Europe/Oslo \
  --prompt-root-password \
  --prompt-hostname 

timedatectl set-ntp true

# The updated mirrorlist will be transferred over with pacstrap
reflector -l 5 -p https -c no --sort rate --save /etc/pacman.d/mirrorlist

# Make sure these are updated
pacman -Sy --noconfirm git python reflector


  
read -rp "Shred disk before continuing? [y/N] " yn
yn=${yn:-N}
      
case "$yn" in
  [yY]) 
    # https://wiki.archlinux.org/title/Securely_wipe_disk#shred
    shred -v -n1 $disk
    ;;
  *) 
    ;;
esac
  
sgdisk -Z $disk

echo -e "\nCreating EFI and root partitions"
# Creating an unencrypted EFI system partition with a FAT file system, and a root 
# partition spanning the rest of the disk. The -t flags make sure that systemd 
# will automatically discover our filesystems meaning we don't need fstab or crypttab:
# https://wiki.archlinux.org/title/dm-crypt/Encrypting_an_entire_system#Simple_encrypted_root_with_TPM2_and_Secure_Boot
sgdisk -n 0:0:+512MiB -t 0:ef00 -c 0:EFISYSTEM "$disk"
sgdisk -n 0:0:0 -t 0:8304 -c 0:linux "$disk"
partprobe -s "$disk"
  
echo -e "\nEncrypting root"
# Then we encrypt the root partition. This prompts for an encryption password
# which we set to blank since we will remove and replace it later.
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
base_packages=(base base-devel linux linux-firmware btrfs-progs 
  systemd-ukify cryptsetup binutils elfutils sudo zsh sbctl sbsigntools fwupd)

# There are more vendor strings listed here: 
# https://en.wikipedia.org/wiki/CPUID#Calling_CPUID
if [[ "$cpu_vendor" == "GenuineIntel" ]]; then
  base_packages+=(intel-ucode thermald)
elif [[ "$cpu_vendor" == "AuthenticAMD" ]]; then
  base_packages+=(amd-ucode amdctl)
fi

if echo "${gpu_vendors[@]}" | grep -q "\bnvidia\b"; then
  # Use dkms for nvidia because it usually works
  base_packages+=("dkms" "linux-headers" "nvidia-dkms" "nvidia-utils" "nvidia-settings" "nvidia-smi")
fi
 
if echo "${gpu_vendors[@]}" | grep -q "\bamd\b"; then
  base_packages+=("mesa" "vulkan-radeon")
fi

if echo "${gpu_vendors[@]}" | grep -q "\bintel\b"; then
  base_packages+=("mesa" "vulkan-intel")
fi

# Bootstrapping the filesystem
pacstrap /mnt "${base_packages[@]}" 



# Copies basic system settings previously set from the host 
systemd-firstboot --force --root /mnt --copy
sed -i "s/^#\(en_US.UTF-8\)/\1/" /mnt/etc/locale.gen
sed -i "s/^#\(no_NB.UTF-8\)/\1/" /mnt/etc/locale.gen
arch-chroot /mnt locale-gen
arch-chroot /mnt hwclock --systohc --utc

install -m755 -d /etc/cmdline.d
install -m644 "$conf_dir/cmdline-boot.conf" /mnt/etc/cmdline.d/boot.conf 
install -m644 "$conf_dir/cmdline-zram.conf" /mnt/etc/cmdline.d/zram.conf 
install -m644 "$conf_dir/cmdline-btrfs.conf" /mnt/etc/cmdline.d/btrfs.conf 
install -m644 "$conf_dir/cmdline-security.conf" /mnt/etc/cmdline.d/security.conf 

# https://wiki.archlinux.org/title/Unified_kernel_image#kernel-install 
# Use kernel-install to install UKI kernels to the esp, and mask the mkinitcpio
# pacman hooks. Requires a pacman hook for kernel-install that is installed later.
install -pm644 "$conf_dir/kernel-install.conf" /mnt/etc/kernel/install.conf
install -m644 "$conf_dir/mkinitcpio-base.conf" /mnt/etc/mkinitcpio.conf.d/base.conf 
ln -sf /dev/null /mnt/etc/pacman.d/hooks/60-mkinitcpio-remove.hook
ln -sf /dev/null /mnt/etc/pacman.d/hooks/90-mkinitcpio-install.hook

# https://wiki.archlinux.org/title/Kernel_mode_setting#Early_KMS_start
if echo "${gpu_vendors[@]}" | grep -q "\bnvidia\b"; then
  # https://wiki.archlinux.org/title/NVIDIA#DRM_kernel_mode_setting
  install -m644 "$conf_dir/cmdline.d/nvidia.conf" /etc/cmdline.d/nvidia.conf
  install -m644 "$conf_dir/mkinitcpio.conf.d/nvidia.conf" /etc/mkinitcpio.conf.d/nvidia.conf
fi
 
if echo "${gpu_vendors[@]}" | grep -q "\bamd\b"; then
  install -m644 "$conf_dir/mkinitcpio.conf.d/amd.conf" /etc/mkinitcpio.conf.d/amd.conf
fi

if echo "${gpu_vendors[@]}" | grep -q "\bintel\b"; then
  install -m644 "$conf_dir/mkinitcpio.conf.d/intel.conf" /etc/mkinitcpio.conf.d/intel.conf
fi

bootctl --root /mnt install
install -pm644 "$conf_dir/loader.conf" /efi/loader/loader.conf

# https://github.com/swsnr/dotfiles/blob/db42fe95fceeac68e4fbe489aed5e310f65b1ae7/arch/bootstrap-from-iso.bash#L131
kernel_versions=(/mnt/usr/lib/modules/*)
kernel_version="${kernel_versions[0]##*/}"
arch-chroot /mnt kernel-install add "${kernel_version}" \
   "/usr/lib/modules/${kernel_version}/vmlinuz"

sbctl create-keys

sbctl sign -s -o /usr/lib/fwupd/efi/fwupdx64.efi.signed /usr/lib/fwupd/efi/fwupdx64.efi
sbctl sign -s -o /usr/lib/systemd/boot/efi/systemd-boot64.efi.signed /usr/lib/systemd/boot/efi/systemd-bootx64.efi

sbctl verify



echo -e "\nCreating new user"

# Create user
readline -p "Enter username: " username
useradd -R /mnt -m -s /usr/bin/zsh "$username"
usermod -R /mnt -aG wheel,storage,power,audit "$username"
passwd -R /mnt "$username"

install -dm750 /etc/sudoers.d/
install -pm600 "$conf_dir/sudoers-wheel" /etc/sudoers.d/wheel

# Set up dotfiles in home as a bare repository
sudo -R /mnt -u "$username" bash -c 'git clone --bare https://github.com/dborseth/.dotfiles.git $HOME/.dotfiles'
sudo -R /mnt -u "$username" bash -c "alias dotfiles='git --git-dir=$HOME/.dotfiles/ --work-tree=$HOME\'"
sudo -R /mnt -u "$username" bash -c 'dotfiles config --local status.showUntrackedFiles no'
sudo -R /mnt -u "$username" bash -c 'dotfiles checkout'



echo -e "\nInstalling additional packages "

extra_packages=(networkmanager iwd git bluez bluez-utils usbutils nvme-cli htop 
  nvtop powertop util-linux apparmor snapper nvim man-db man-pages exa fzf 
  ripgrep fd zram-generator audit plymouth greetd greetd-agreety greetd-tuigreet 
  blueman pacman-contrib lm_sensors polkit-kde-agent xdg-desktop-portal-hyprland 
  qt6-wayland qt5-wayland slurp grim swaybg swayidle mako pipewire wireplumber 
  ttf-cascadia-code inter-font curl tlp)

aur_packages=(aurutils amdctl pacman-hook-kernel-install auto-cpufreq gtklock 
  helix-git zsh-antidote hyprland-nvidia-git hyprpicker-git)

# Sets up a local aur repository and syncs the list of aur packages to the repo.
# The packages are then installed along with the other packages in the pacman repo. 
# TODO Move the repository to one of the servers to remove this step
install -pm644 "$conf_dir/pacman.conf" /etc/pacman.conf

sudo -R /mnt -u "$username" bash -c "git clone https://aur.archlinux.org/aurutils.git && cd aurutils && makepkg -si"
install -d /mnt/var/cache/pacman/aur -o $username
sudo -R /mnt -u "$username" bash -c "repo-add /var/cache/pacman/aur/aur.db.tar"
sudo -R /mnt -u "$username" bash -c "aur sync ${aur_packages[@]}"

extra_packages+=("${aur_packages}")
pacman -S --root /mnt --noconfirm "${extra_packages[@]}"



# https://wiki.archlinux.org/title/NetworkManager#systemd-resolved
# https://wiki.archlinux.org/title/NetworkManager#Using_iwd_as_the_Wi-Fi_backend
ln -sf /run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf
install -Dpm644 "$conf_dir/networkmanager-wifi.conf" /mnt/etc/NetworkManager.conf.d/wifi.conf

# TODO greetd

systemctl --root /mnt enable \
  systemd-resolved.service \
  NetworkManager.service

# TODO thermald if intel, amctl if amd. or auto-cpufreq?

echo -e '\n*** Installation script finished, cleaning up'

#umount -R /mnt
#cryptsetup luksClose root