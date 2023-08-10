Before starting, make sure secure boot is disabled and in setup mode. Then do the following steps:

```
loadkeys no-latin1
iwctl station wlan0 connect ...

pacman -Sy git

git clone https://github.com/dborseth/arch-setup.git
./arch-setup/install.sh /dev/nvme0n1
```

Reboot and remove the usb drive. Turn on secure boot in bios. 