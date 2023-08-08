#!/bin/bash

set -euo pipefail

prepare_disk() {
  disk="$1"
  
  echo "* Wiping $disk and removing all GPT entries"
  shred -v -n1 $disk
  sgdisk -Z $disk

  echo "* Creating EFI and root partitions"
  # We are creating an unencrypted EFI system partition with a FAT file system, 
  # and a root partition spanning the rest of the disk. The -t flags make sure
  # that systemd will automatically discover out filesystems
  sgdisk -n 0:0:+512MiB -t 0:ef00 -c 0:EFISYSTEM $disk
  sgdisk -n 0:0:0 -t 0:8304 -c 0:linux $disk
  sgdisk -p $disk
  
  echo "* Encrypting root"
  # Then we encrypt the root partition. This prompts for an encryption password
  # which we set to a simple one since we will remove an replace it later.
  cryptsetup luksFormat --type luks2 /dev/disk/by-partlabel/linux
  cryptsetup luksOpen /dev/disk/by-partlabel/linux root

  echo "* Formatting file systems"
  root_device="/dev/mapper/root"
  mkfs.fat -F32 -n EFISYSTEM /dev/disk/by-partlabel/EFISYSTEM
  mkfs.btrfs -f -L linux "$root_device"
  
  echo "* Creating btrfs subvolumes"
  # We then mount the root to set up some btrfs subvolumes. The number of volumes
  # here is chosen to exclude var/cache var/log and var/tmp from any snapshots
  # of /, but not really necessary. 
  mount $root_device /mnt
  mount --mkdir /dev/disk/by-partlabel/EFISYSTEM /mnt/efi
  
  btrfs create subvolume /mnt/@
  btrfs create subvolume /mnt/@snapshots
  btrfs create subvolume /mnt/@home
  btrfs create subvolume /mnt/@cache
  btrfs create subvolume /mnt/@log
  btrfs create subvolume /mnt/@tmp
  
  btrfs subvolume set-default /mnt/@
}

echo -e "\n*** Installing Arch Linux"
echo -e "\n** Installing needed utilities"

timedatectl set-ntp true
reflector --latest 5 --sort rate --save /etc/pacman.d/mirrorlist

echo -e "\n** Select installation disk: "
disks=() 
while IFS= read -r line; do
  disks+=("$line")
done < <(lsblk -dnpo name,size,type | grep "disk" | awk '{print $1}')
  
if [[ "${#disks[@]}" -eq 0 ]]; then
  echo "* No disks found, exiting."
  exit 1
elif [[ "${#disks[@]}" -eq 1 ]]; then
  echo "* Only one disk found: ${disks[0]}"

  while true; do
    read -rp "* Use ${disks[0]}? [Y/n] " yn
    yn=${yn:-Y}
  
    case "$yn" in
      [yY])
       prepare_disk "$selected_disk"
        break
        ;;
      [nN])
        exit
        ;;
      *) 
        ;;
    esac
  done
else
  PS3="disk: "
  select selected_disk in "${#disks[@]}"; do
    if [[ -n $selected_disk ]]; then
      read -rp "Use $selected_disk? [Y/n] " yn
      yn=${yn:-Y}
      
      case "$yn" in
        [yY]) 
         prepare_disk $selected_disk
          break
          ;;
        [nN])
          exit
          ;;
        *) 
          ;;
      esac
    fi
  done
fi

echo -e "\n*** Bootstrapping the new system"

packages=(base base-devel linux linux-firmware btrfs-progs mkinitcpio 
          cryptsetup binutils elfutils sbctl sbsigntools fwupd sudo git)

cpu_vendor=$(grep "vendor_id" /proc/cpuinfo | head -n 1 | awk '{print $3}')
echo "* Found CPU with vendor: $cpu_vendor" 
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

echo -e "* Found the following GPU vendors: ${gpu_vendors[@]}"
if echo "${gpu_vendors[@]}" | grep -q "\bnvidia\b"; then
  packages+=("dkms" "linux-headers" "nvidia-dkms" "nvidia-utils" "nvidia-settings" "nvidia-smi")
fi
  
if echo "${gpu_vendors[@]}" | grep -q "\bamd\b"; then
  packages+=("mesa" "vulkan-radeon")
fi
 
if echo "${gpu_vendors[@]}" | grep -q "\bintel\b"; then
  packages+=("mesa" "vulkan-intel")
fi

echo "\n${packages[@]}"
pacstrap /mnt "${packages[@]}" 
# genfstab -L /mnt >> /mnt/etc/fstab
# create_swapfile

git clone https://github.com/dborseth/arch-setup /mnt/tmp/arch-setup

chmod +x /mnt/tmp/configure.sh
chmod +x /mnt/tmp/users.sh

# arch-chroot /mnt bash -c "/mnt/tmp/configure.sh '$cpu_vendor' '$gpu_vendors'""
# arch-chroot /mnt bash -c "/mnt/tmp/users.sh"

echo -e '\n*** Installation script finished'

# rm /mnt/tmp/configure.sh
# rm /mnt/tmp/users.sh

umount -R /mnt
cryptsetup luksClose root