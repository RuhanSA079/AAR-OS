Please use this scripts at your own discretion and responsibility.

These scripts are HIGHLY experimental, and SHOULD NOT BE USED in any sort of production environment(s), unless you have an idea to harden the userspace yourself.


# Note  
When booted into the live OS image, please modify the `installOS.sh` script in /usr/bin/ folder to suit your target disk. Nano and vim is available.  
You may have to remount the OS disk as r/w: `sudo mount -o remount rw /`  

Post-install:  
It seems like that the installed OS complains of a missing `/etc/machine-id`  
Mount OS disk as R/W: `sudo mount -o remount rw /`  
Generate machine-id with: `cat /proc/sys/kernel/random/uuid | tr -d '-' | cut -c1-32 > /etc/machine-id`  

SSH install:  
`sudo apt install ssh`  
`sudo ssh-keygen -A`  
`sudo systemctl enable ssh && sudo systemctl start ssh`  
