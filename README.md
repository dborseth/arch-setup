Before starting, make sure secure boot is disabled and in setup mode. Then do the following steps:

```
loadkeys no-latin1
iwctl station wlan0 connect ...

curl -sSO https://raw.githubusercontent.com/dborseth/arch-setup/main/install.sh
chmod +x install.sh

./install.sh /dev/nvme0n1
```

Reboot and remove the usb drive. 