#!/bin/bash

if [ "$(id -u)" -ne 0 ];
then
    echo "Got root?"
    exit 1
fi

ROOTFS_BASE_NAME="ubuntu-base-22.04-base-amd64.tar.gz"
ROOTFS_BASE_URL="https://cdimage.ubuntu.com/ubuntu-base/releases/jammy/release/"
ROOTFS_DOWNLOAD="$ROOTFS_BASE_URL$ROOTFS_BASE_NAME"
DISK_IMAGE_NAME="generic_amd64.img"
HARDWARE_NAME="generic_amd64"
ROOTFS_PART_MOUNTPOINT="/mnt/$HARDWARE_NAME/partroot"
ROOTFS_BINDMOUNTS="$ROOTFS_PART_MOUNTPOINT"
EFI_PART_MOUNTPOINT="$ROOTFS_PART_MOUNTPOINT/boot/efi"

loopdev=""
DEBUG_BUILD=0
ENABLE_DOCKER=0
ENABLE_SNAPD=0


function cleanup()
{
        echo "-----------------------------------------------"
        echo "Cleaning up..."
        if [ -d $EFI_PART_MOUNTPOINT ];
        then
                umount $EFI_PART_MOUNTPOINT
        fi

        if [ -d $ROOTFS_PART_MOUNTPOINT ];
        then
                umount $ROOTFS_PART_MOUNTPOINT
        fi

        #Dismount the current image if present.
        if [ -z $loopdev ];
        then
                #Find the loopdisk.
                loopdev=$(losetup -j $DISK_IMAGE_NAME | cut -d: -f1)

                if [ ! -z $loopdev ]; then
                        echo "Detaching $loopdev from $DISK_IMAGE_NAME"
                        losetup -d $loopdev
                else
                        echo "No loop device is currently using $DISK_IMAGE_NAME"
                fi

        else
                losetup -d $loopdev
        fi
        echo "-----------------------------------------------"
}

function createDisk()
{
        echo "-----------------------------------------------"
        echo "Creating raw disk image..."
        dd if=/dev/zero of=$DISK_IMAGE_NAME bs=1M count=4096
        echo "-----------------------------------------------"
        echo "Creating partitions on disk image..."
        #150mb EFI, rest is 1.7G flash (too small?)
        echo -e "o\nn\np\n1\n2048\n+150M\nt\nef\nn\np\n2\n309248\n\nw" | fdisk $DISK_IMAGE_NAME
        echo "-----------------------------------------------"
        echo "Mounting disk for setup..."
        loopdev=$(sudo losetup -fP --show $DISK_IMAGE_NAME)

        EFI_LOOPDISK=${loopdev}p1
        ROOTFS_LOOPDISK=${loopdev}p2
        echo "-----------------------------------------------"
        echo "Creating EFI filesystem for EFI partition"
        mkfs.vfat -F32 $EFI_LOOPDISK

        echo "Creating EXT4 filesystem for rootfs partition"
        mkfs.ext4 -O 64bit $ROOTFS_LOOPDISK
        echo "-----------------------------------------------"
}

function umountBindMounts(){
        echo "Unmounting bind mounts..."
        umount $ROOTFS_BINDMOUNTS/dev
        umount $ROOTFS_BINDMOUNTS/proc
        umount $ROOTFS_BINDMOUNTS/sys
}

function addFilesForChroot(){
        echo "AAR-OS" > etc/hostname
        echo "127.0.0.1 localhost" > etc/hosts
        echo "127.0.1.1 AAR-OS" >> etc/hosts
        echo "nameserver 8.8.8.8" > etc/resolv.conf
        mkdir -p etc/apt/apt.conf.d/
        echo 'Acquire::ForceIPv4 "true";' > etc/apt/apt.conf.d/99settings
        echo 'Acquire::Retries "5";' > etc/apt/apt.conf.d/99settings
        echo "deb [trusted=yes] http://ubuntu.mirror.ac.za/ubuntu jammy main restricted universe multiverse" > etc/apt/sources.list
        echo "deb [trusted=yes] http://ubuntu.mirror.ac.za/ubuntu jammy-updates main restricted universe multiverse" >> etc/apt/sources.list
        echo "deb [trusted=yes] http://ubuntu.mirror.ac.za/ubuntu jammy-backports main restricted universe multiverse" >> etc/apt/sources.list
        echo "deb [trusted=yes] http://ubuntu.mirror.ac.za/ubuntu jammy-security main restricted universe multiverse" >> etc/apt/sources.list

        if [ $ENABLE_DOCKER -eq 1 ];
        then
                echo "ENABLE_DOCKER pragma is enabled."
                echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu jammy stable" >> etc/apt/sources.list
        fi

        mkdir -p tmp/
        echo "#!/bin/bash" > tmp/inside_chroot.sh
        echo "echo 'Updating apt repository cache...' " >> tmp/inside_chroot.sh
        echo "apt update" >> tmp/inside_chroot.sh
        echo "echo 'tzdata tzdata/Areas select Africa' | debconf-set-selections" >> tmp/inside_chroot.sh
        echo "echo 'tzdata tzdata/Zones/Africa select Johannesburg' | debconf-set-selections" >> tmp/inside_chroot.sh
        echo "echo 'Installing system packages...' " >> tmp/inside_chroot.sh

        echo "DEBIAN_FRONTEND=noninteractive apt install -y linux-image-generic grub-efi-amd64" >> tmp/inside_chroot.sh

        echo "DEBIAN_FRONTEND=noninteractive apt install -y ca-certificates bridge-utils curl gnupg tzdata net-tools network-manager modemmanager iputils-ping apt-utils openssh-server kmod systemd-sysv nano vim dialog sudo rauc rauc-service libubootenv-tool mmc-utils wireless-regdb iw fdisk iproute2" >> tmp/inside_chroot.sh
        if [ $DEBUG_BUILD -eq 1 ];
        then
                echo "DEBUG_BUILD pragma is enabled."
                echo "DEBIAN_FRONTEND=noninteractive apt install -y initramfs-tools device-tree-compiler u-boot-tools" >> tmp/inside_chroot.sh
        fi

        if [ $ENABLE_DOCKER -eq 1 ];
        then
                echo "echo Installing keys for use on Docker repos..." >> tmp/inside_chroot.sh
                echo "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg" >> tmp/inside_chroot.sh
                echo "apt update" >> tmp/inside_chroot.sh
                echo "DEBIAN_FRONTEND=noninteractive apt install -y docker-ce docker-ce-cli containerd.io" >> tmp/inside_chroot.sh
        fi

        if [ $ENABLE_SNAPD -eq 1 ];
        then
                echo "Installing snapd..."
                echo "DEBIAN_FRONTEND=noninteractive apt install -y snapd" >> tmp/inside_chroot.sh
        fi
        echo "echo 'Install grub...'" >> tmp/inside_chroot.sh
        echo "grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck" >> tmp/inside_chroot.sh
        echo "echo 'Ensuring GRUB_DISABLE_OS_PROBER=true is set...'" >> tmp/inside_chroot.sh
        echo "if grep -Eq '^[#]*\s*GRUB_DISABLE_OS_PROBER=' /etc/default/grub; then" >> tmp/inside_chroot.sh
        echo "    sed -i 's|^[#]*\s*GRUB_DISABLE_OS_PROBER=.*|GRUB_DISABLE_OS_PROBER=true|' /etc/default/grub" >> tmp/inside_chroot.sh
        echo "else" >> tmp/inside_chroot.sh
        echo "    echo 'GRUB_DISABLE_OS_PROBER=true' >> /etc/default/grub" >> tmp/inside_chroot.sh
        echo "fi" >> tmp/inside_chroot.sh
        echo "echo 'Updating grub...'" >> tmp/inside_chroot.sh
        echo "update-grub" >> tmp/inside_chroot.sh
        echo "echo 'Fixing NetworkManager...'" >> tmp/inside_chroot.sh
        echo "touch /etc/NetworkManager/conf.d/10-globally-managed-devices.conf" >> tmp/inside_chroot.sh
        echo "echo 'Adding admin user for login...' " >> tmp/inside_chroot.sh
        echo "useradd -m -s /bin/bash admin" >> tmp/inside_chroot.sh
        echo "echo admin:admin | chpasswd" >> tmp/inside_chroot.sh
        echo "usermod -aG sudo admin" >> tmp/inside_chroot.sh
        echo "usermod -aG adm admin" >> tmp/inside_chroot.sh
        echo "echo 'Purging unused system packages...'" >> tmp/inside_chroot.sh
        echo "apt-get purge -y man-db manpages info doc-base" >> tmp/inside_chroot.sh
        echo "echo Deleting SSHd generated keys!" >> tmp/inside_chroot.sh
        echo "rm -r /etc/machine-id" >> tmp/inside_chroot.sh
        echo "rm -r /etc/ssh/ssh_host_*" >> tmp/inside_chroot.sh
        echo "echo Deleting all cached system-packages..." >> tmp/inside_chroot.sh
        echo "apt-get clean" >> tmp/inside_chroot.sh
        echo "echo Deleting all syslogs..." >> tmp/inside_chroot.sh
        echo "rm -r /var/log/*" >> tmp/inside_chroot.sh
        echo "echo Deleting all apt-lists..." >> tmp/inside_chroot.sh
        echo "rm -r /var/lib/apt/lists/*" >> tmp/inside_chroot.sh
        echo "echo Deleting all apt cached packages..." >> tmp/inside_chroot.sh
        echo "rm -r /var/cache/apt/archives/* " >> tmp/inside_chroot.sh
        echo "exit" >> tmp/inside_chroot.sh
        chmod +x tmp/inside_chroot.sh
}

function mountBindMounts(){
        echo "Making bind mounts into the system"
        mount --bind /dev $ROOTFS_BINDMOUNTS/dev
        mount --bind /proc $ROOTFS_BINDMOUNTS/proc
        mount --bind /sys $ROOTFS_BINDMOUNTS/sys
}

########################################################## MAIN SCRIPT EXECUTION
echo "-----------------------------------------------"
echo "AAR-OS image builder v0.1"
echo "-----------------------------------------------"
echo "Building image..."
echo "-----------------------------------------------"
umountBindMounts
cleanup

if [ -f "$DISK_IMAGE_NAME" ];
then
        echo "Nuking disk image and starting over..."
        rm -r $DISK_IMAGE_NAME
else
        echo "Disk image $DISK_IMAGE_NAME does not exist! Recreating..."
fi

createDisk

#Mount the RootFS first and then make a /boot/efi folder for the EFI partition.
echo "Mounting disks for OS image creation..."
mkdir -p $ROOTFS_PART_MOUNTPOINT

mount $ROOTFS_LOOPDISK $ROOTFS_PART_MOUNTPOINT
mkdir -p $EFI_PART_MOUNTPOINT
mount $EFI_LOOPDISK $EFI_PART_MOUNTPOINT

echo "-----------------------------------------------"

echo "Building Ubuntu 22 (Jammy) base image..."
echo "Going to take a moment to complete..."

WORKING_DIR=$(pwd)

if [ -f "/mnt/$HARDWARE_NAME/$ROOTFS_BASE_NAME" ]
then
        echo "$ROOTFS_BASE_NAME found, not downloading..."
else
        echo "$ROOTFS_BASE_NAME missing, downloading..."
        wget -O "/mnt/$HARDWARE_NAME/$ROOTFS_BASE_NAME" "$ROOTFS_DOWNLOAD"
        if [ -f "/mnt/$HARDWARE_NAME/$ROOTFS_BASE_NAME" ];
        then
                echo "File downloaded."
        else
                echo "File not found!"
                cleanup
        fi
fi


cd $ROOTFS_PART_MOUNTPOINT
ROOTFS_BINDMOUNTS=$(pwd)
echo "Extracting rootfs..."
tar -xf ../$ROOTFS_BASE_NAME
echo "-----------------------------------------------"

echo "Setting up auto-install script in chroot jail"
addFilesForChroot
cd ../
echo "-----------------------------------------------"
echo "Bind mounts before chrooting into the system..."
mountBindMounts
echo "-----------------------------------------------"
echo "Jumping into chroot jail..."
chroot $ROOTFS_PART_MOUNTPOINT /tmp/inside_chroot.sh
echo "-----------------------------------------------"
echo "Chroot jail setup is done..."
umountBindMounts
echo "-----------------------------------------------"
echo "Unmounting disk image..."

cleanup

echo "Done."
