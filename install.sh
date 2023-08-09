#!/bin/bash

set -euo pipefail

disk="$1"

echo -e "\n*** Installing Arch Linux"
timedatectl set-ntp true

reflector -l 5 -c Norway,Sweden --sort rate --save /etc/pacman.d/mirrorlist
pacman -Sy --noconfirm git python reflector
  
read -rp "Shred disk before continuing? [y/N] " yn
yn=${yn:-N}
      
case "$yn" in
  [yY]) 
    shred -v -n1 $disk
    ;;
  *) 
    ;;
esac
  
sgdisk -Z $disk

echo -e "\nCreating EFI and root partitions"
# We are creating an unencrypted EFI system partition with a FAT file system, 
# and a root partition spanning the rest of the disk. The -t flags make sure
# that systemd will automatically discover our filesystems meaning we don't 
# need fstab or crypttab
sgdisk -n 0:0:+512MiB -t 0:ef00 -c 0:EFISYSTEM "$disk"
sgdisk -n 0:0:0 -t 0:8304 -c 0:linux "$disk"
partprobe -s "$disk"
  
echo ''
sgdisk -p "$disk"
  
echo -e "\nEncrypting root"
# Then we encrypt the root partition. This prompts for an encryption password
# which we set to a simple one since we will remove an replace it later.
cryptsetup luksFormat --type luks2 /dev/disk/by-partlabel/linux

echo -e "\nOpening encrypted root"
cryptsetup luksOpen /dev/disk/by-partlabel/linux root
cryptsetup refresh --allow-discards --perf-no_read_workqueue --perf-no_write_workqueue --persistent root

root_device="/dev/mapper/root"
mkfs.fat -F32 -n EFISYSTEM /dev/disk/by-partlabel/EFISYSTEM
mkfs.btrfs -f -L linux "/dev/mapper/root"
  
# We then mount the root to set up some btrfs subvolumes. The number of volumes
# here is chosen to exclude var/cache var/log and var/tmp from any snapshots
# of /, but not really necessary. 
mount -o 'noatime,compress=zstd:1,space_cache=v2' "/dev/mapper/root" /mnt
mount --mkdir /dev/disk/by-partlabel/EFISYSTEM /mnt/efi
  
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@cache
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@tmp
  
btrfs subvolume set-default /mnt/@

packages=(base base-devel linux linux-firmware btrfs-progs mkinitcpio systemd-ukify 
          cryptsetup binutils elfutils sudo helix git zsh networkmanager iwd)

cpu_vendor=$(grep "vendor_id" /proc/cpuinfo | head -n 1 | awk '{print $3}')
if [[ "$cpu_vendor" == "GenuineIntel" ]]; then
  packages+=("intel-ucode")
elif [[ "$cpu_vendor" == "AuthenticAMD" ]]; then
  packages+=("amd-ucode")
fi

echo -e "\n${packages[@]}"
pacstrap /mnt "${packages[@]}" 

arch-chroot /mnt git clone https://github.com/dborseth/arch-setup /mnt/root/arch-setup

# https://wiki.archlinux.org/title/NetworkManager#systemd-resolved
# https://wiki.archlinux.org/title/NetworkManager#Using_iwd_as_the_Wi-Fi_backend
ln -sf /run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf
cat > /mnt/etc/NetworkManager/conf.d/wifi.conf <<EOF
[device]
wifi.backend=iwd
EOF

sed -i "s/^#\(en_US.UTF-8\)/\1/" /mnt/etc/locale.gen
sed -i "s/^#\(no_NB.UTF-8\)/\1/" /mnt/etc/locale.gen

arch-chroot /mnt locale-gen
arch-chroot /mnt hwclock --systohc --utc

systemd-firstboot --force \
  --root /mnt \
  --keymap=no-latin1 \
  --locale=en_US.UTF-8 \
  --timezone=Europe/Oslo \
  --root-shell=/usr/bin/zsh \
  --prompt-root-password \
  --prompt-hostname 

# https://wiki.archlinux.org/title/Unified_kernel_image#kernel-install
# https://github.com/swsnr/dotfiles/blob/db42fe95fceeac68e4fbe489aed5e310f65b1ae7/arch/bootstrap-from-iso.bash#L131
cat > /etc/mkinitcpio.conf.d/base.conf <<EOF
MODULES=()
FILES=()
HOOKS=(base systemd btrfs autodetect modconf keyboard sd-vconsole sd-encrypt block filesystems fsck)
EOF

cat > /mnt/etc/kernel/install.conf <<EOF
layout=uki
initrd_generator=mkinitcpio
EOF

kernel_versions=(/mnt/usr/lib/modules/*)
kernel_version="${kernel_versions[0]##*/}"

arch-chroot /mnt kernel-install add "${kernel_version}" \
    "/usr/lib/modules/${kernel_version}/vmlinuz"

bootctl --root /mnt install

systemctl --root /mnt enable \
  systemd-resolved.service \
  NetworkManager.service

echo -e '\n*** Installation script finished, cleaning up'

umount -R /mnt
cryptsetup luksClose root