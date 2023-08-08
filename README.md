# Arch setup

Before starting, make sure secure boot is disabled and in setup mode. Then do the following steps:

```
loadkeys no-latin1
iwctl station wlan0 connect ...
curl -sS https://raw.githubusercontent.com/dborseth/arch-setup/main/install.sh | bash
```