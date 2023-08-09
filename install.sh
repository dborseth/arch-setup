#!/bin/bash

set -euo pipefail

prepare_disk() {
  disk="$1"
  
  echo "* Wiping $disk and removing all GPT entries"
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

  echo -e "\n* Creating EFI and root partitions"
  # We are creating an unencrypted EFI system partition with a FAT file system, 
  # and a root partition spanning the rest of the disk. The -t flags make sure
  # that systemd will automatically discover our filesystems meaning we don't 
  # need fstab or crypttab
  sgdisk -n 0:0:+512MiB -t 0:ef00 -c 0:EFISYSTEM "$disk"
  sgdisk -n 0:0:0 -t 0:8304 -c 0:linux "$disk"
  partprobe -s "$disk"
  
  echo ''
  sgdisk -p "$disk"
  
  echo -e "\n* Encrypting root"
  # Then we encrypt the root partition. This prompts for an encryption password
  # which we set to a simple one since we will remove an replace it later.
  cryptsetup luksFormat --type luks2 /dev/disk/by-partlabel/linux

  echo -e "\n* Opening encrypted root"
  cryptsetup luksOpen /dev/disk/by-partlabel/linux root
  cryptsetup refresh --allow-discards --perf-no_read_workqueue --perf-no_write_workqueue --persistent root

  echo "* Formatting file systems"
  root_device="/dev/mapper/root"
  mkfs.fat -F32 -n EFISYSTEM /dev/disk/by-partlabel/EFISYSTEM
  mkfs.btrfs -f -L linux "/dev/mapper/root"
  
  echo "* Creating btrfs subvolumes"
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
}

echo -e "\n*** Installing Arch Linux"
timedatectl set-ntp true

echo -e "* Updating mirrorlist.."
reflector -l 5 -c Norway,Sweden --sort rate --save /etc/pacman.d/mirrorlist
pacman -Sy --noconfirm git

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
       prepare_disk "${disks[0]}"
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
  # TODO: This behaves weird sometimes
  PS3="disk: "
  select disk in "${disks[@]}"; do
    if [[ -n $disk ]]; then
      read -rp "Use $disk? [Y/n] " yn
      yn=${yn:-Y}
      
      case "$yn" in
        [yY]) 
         prepare_disk $disk
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
          cryptsetup binutils elfutils sbctl sbsigntools fwupd sudo vim git)

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

echo -e "\n${packages[@]}"
pacstrap /mnt "${packages[@]}" 

arch-chroot /mnt git clone https://github.com/dborseth/arch-setup /mnt/tmp/arch-setup
arch-chroot /mnt chmod +x /mnt/tmp/arch-setup/configure.sh
# chmod +x /mnt/tmp/arch-setup/users.sh
arch-chroot /mnt bash -c "/mnt/tmp/arch-setup/configure.sh '$cpu_vendor' '$gpu_vendors'"
# arch-chroot /mnt bash -c "/mnt/tmp/arch-setup/users.sh"

echo -e '\n*** Installation script finished, cleaning up'
rm -rf /mnt/tmp/arch-setup
umount -R /mnt
cryptsetup luksClose root