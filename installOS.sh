#!/bin/bash

if [ "$(id -u)" -ne 0 ];
then
    echo "Got root?"
    exit 1
fi

set -euo pipefail
# --- Variables ---
TARGET_DISK="/dev/sdb"
EFI_PART="${TARGET_DISK}1"
ROOT_PART="${TARGET_DISK}2"
MOUNT_DIR="/mnt/target"
LIVE_ROOT="/" # Or use something like /run/live/rootfs/filesystem.squashfs if applicable


# --- Partitioning ---
echo "Wiping disk..."
wipefs --all $TARGET_DISK
echo "Recreating disk partitions..."
echo -e "o\nn\np\n1\n2048\n+150M\nt\nef\nn\np\n2\n309248\n\nw" | fdisk $TARGET_DISK
sleep 2

echo "Formatting partitions..."
# --- Formatting ---
mkfs.fat -F32 "$EFI_PART"
mkfs.ext4 -F "$ROOT_PART"

echo "Mounting prepared disk for OS install..."
# --- Mounting ---
mkdir -p "$MOUNT_DIR"
mount "$ROOT_PART" "$MOUNT_DIR"
mkdir -p "$MOUNT_DIR/boot/efi"
mount "$EFI_PART" "$MOUNT_DIR/boot/efi"

echo "Transferring files..."
# --- Rsync rootfs ---
rsync -aAXv --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found"} "$LIVE_ROOT" "$MOUNT_DIR"

echo "Preparing to enter a chroot environment..."
# --- Bind mount and chroot ---
for d in dev proc sys run; do
    mount --bind "/$d" "$MOUNT_DIR/$d"
done

echo "Jumping into chroot!"
chroot "$MOUNT_DIR" /bin/bash <<'EOF'

# --- Inside chroot ---
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck
grub-mkconfig -o /boot/grub/grub.cfg
update-initramfs -c -k all
update-grub
EOF

echo "Exit chroot. Cleaning up..."
# --- Cleanup ---
for d in run sys proc dev; do
    umount "$MOUNT_DIR/$d"
done

echo "Unmounting fresh installed OS image disk..."
umount "$MOUNT_DIR/boot/efi"
umount "$MOUNT_DIR"

echo "OS Installation complete. You may now reboot."
