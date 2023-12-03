#! /bin/bash

set -euo pipefail
shopt -s lastpipe

DEVICE=/dev/sda
BOOT_PARTITION="${DEVICE}1"
LVM_PARTITION="${DEVICE}2"
VOLGROUP_NAME=vg0
ROOT_FS=/dev/$VOLGROUP_NAME/lv_root
HOME_FS=/dev/$VOLGROUP_NAME/lv_home
POST_INSTALL_NAME=".run_postinstall"
LOCALE_GEN="en_US.UTF-8 UTF-8"
MOUNT_PREFIX="/mnt/newsys"
INIT_USER=kwest
TIMEZONE="America/Los_Angeles"
HOSTNAME=kwest-arch
SELF_NAME="archway.sh"

# LONG VARS
# Read will return 1 if EOF is hit, which it always is when using -d ''.
# We have to ignore failure on those cases because of -e in the shebang.

read -rd '' sfdisk_script <<'EOF' || true
label: gpt

size=+500MiB, type=uefi
type=lvm
EOF

# HELPERS

ch() {
    arch-chroot $MOUNT_PREFIX bash -c "$*"
}

# BUSINESS LOGIC

execute() {
    if [ -f $POST_INSTALL_NAME ]; then
        execute_post_boot
    else
        execute_pre_boot
    fi
}

execute_pre_boot() {
    echo executing pre-boot steps
    read -rsp "Enter the new root password:" root_passwd
    echo
    read -rsp "Enter the new password for user '$INIT_USER':" user_passwd
    echo
    do_disk_setup
    do_distro_install
    do_boot_setup
    systemctl -i reboot
}

do_disk_setup() {
    create_base_partitions
    format_boot_partition
    setup_lvm_partition
    generate_fs_table
    create_swapfile
}

do_distro_install() {
    bootstrap_pacman
    install_initial_packages
}

do_boot_setup() {
    enable_startup_services
    setup_locale
    add_boot_hooks
    generate_initrd
    user_updates
    update_sudoers
    mount_efi_volume
    install_bootloader
    install_startup_runner
}

execute_post_boot() {
    echo executing post-boot steps
    set_timezone
    set_hostname
    post_installs
    remove_autorun
    reboot
}

create_base_partitions() {
    echo "$sfdisk_script" | sfdisk $DEVICE
}

format_boot_partition() {
    mkfs.fat -F32 $BOOT_PARTITION
}

setup_lvm_partition() {
    pvcreate --dataalignment 1m $LVM_PARTITION
    vgcreate $VOLGROUP_NAME $LVM_PARTITION
    lvcreate -L 30GB $VOLGROUP_NAME -n lv_root
    lvcreate -l 100%FREE $VOLGROUP_NAME -n lv_home
    modprobe dm_mod
    vgscan
    vgchange -ay
    mkfs.ext4 $ROOT_FS
    mkfs.ext4 $HOME_FS
    mount --mkdir $ROOT_FS $MOUNT_PREFIX
    mount --mkdir $HOME_FS $MOUNT_PREFIX/home
    mkdir -p $MOUNT_PREFIX/etc
}

generate_fs_table() {
    genfstab -U -p $MOUNT_PREFIX >>$MOUNT_PREFIX/etc/fstab
}

create_swapfile() {
    dd if=/dev/zero of=$MOUNT_PREFIX/swapfile bs=1M count=2048
    chmod 600 $MOUNT_PREFIX/swapfile
    mkswap $MOUNT_PREFIX/swapfile
    echo "/swapfile none swap sw 0 0" >>$MOUNT_PREFIX/etc/fstab
}

bootstrap_pacman() {
    pacstrap $MOUNT_PREFIX base
}

install_initial_packages() {
    ch pacman -S --noconfirm \
        linux \
        linux-headers \
        linux-lts \
        linux-lts-headers \
        vim \
        nano \
        base-devel \
        sudo \
        openssh \
        networkmanager \
        wpa_supplicant \
        wireless_tools \
        netctl \
        lvm2 \
        grub \
        efibootmgr \
        dosfstools \
        mtools \
        os-prober \
        whois
}

enable_startup_services() {
    ch systemctl enable NetworkManager sshd
}

setup_locale() {
    # Ensure that we're using a valid locale
    if ! grep -q "$LOCALE_GEN" $MOUNT_PREFIX/etc/locale.gen; then
        echo "ERROR: invalid locale:" "$LOCALE_GEN"
        exit 1
    fi

    # Instead of in-place editing, we just append the known locale to the file uncommented
    echo "$LOCALE_GEN" >>$MOUNT_PREFIX/etc/locale.gen
    ch locale-gen
}

add_boot_hooks() {
    eval "$(cat $MOUNT_PREFIX/etc/mkinitcpio.conf | grep HOOKS)"
    needle=block
    idx=-1

    for i in "${!HOOKS[@]}"; do
        if [ "${HOOKS[$i]}" = "${needle}" ]; then
            idx=$((i + 1))
        fi
    done

    if [ "${idx}" = "-1" ]; then
        echo 'Failed to add build hook, could not find "block" hook'
        exit 1
    fi
    new_hooks=("${HOOKS[@]:0:$idx}" "lvm2" "${HOOKS[@]:idx}")
    echo "HOOKS=(" "${new_hooks[@]}" ")" >$MOUNT_PREFIX/etc/mkinitcpio.conf
}

generate_initrd() {
    ch mkinitcpio -p linux -p linux-lts
}

user_updates() {
    ch useradd -mG wheel $INIT_USER
    printf "root:%s\n%s:%s" "$root_passwd" "$INIT_USER" "$user_passwd" | chpasswd -R $MOUNT_PREFIX
    pacman -Sy --noconfirm whois
    check_password root "$root_passwd" $MOUNT_PREFIX/etc/shadow
    check_password $INIT_USER "$user_passwd" $MOUNT_PREFIX/etc/shadow
}

check_password() {
    local username="$1"
    local password="$2"
    local filename="$3"
    local crypt_alg
    local salt
    local encrypted_pw
    awk -F '[:$]' "/$username/ {print \$3, \$4, \$5}" "$filename" |
        read -r crypt_alg salt encrypted_pw
    local expected_entry
    expected_entry=$(printf '$%s$%s$%s' "$crypt_alg" "$salt" "$encrypted_pw")

    local actual_entry
    local mode
    case "$crypt_alg" in
    "6")
        mode=SHA-512
        ;;
    "5")
        mode=SHA-256
        ;;
    *)
        echo 'Unsupported crypt mode in /etc/shadow: ' "$crypt_alg"
        exit 1
        ;;
    esac
    mkpasswd -sm $mode -S "$salt" <<<"$password" | read -r actual_entry
    if [ "$expected_entry" != "$actual_entry" ]; then
        echo "Passwords don't match"
        exit 1
    else
        echo "Password is correct!"
    fi

}

update_sudoers() {
    echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' >>$MOUNT_PREFIX/etc/sudoers.d/wheel
    chmod 440 $MOUNT_PREFIX/etc/sudoers.d/wheel
    # Use visudo to check the format is correct
    if ! visudo -c; then
        echo "WARNING: Invalid sudoers file, wheel group will not have NOPASSWD tag"
        rm $MOUNT_PREFIX/etc/sudoers.d/wheel
    fi
}

mount_efi_volume() {
    ch mount --mkdir "$BOOT_PARTITION" /boot/EFI
}

install_bootloader() {
    ch grub-install --target=x86_64-efi --bootloader-id=grub_uefi --recheck
    mkdir -p $MOUNT_PREFIX/boot/grub/locale
    cp $MOUNT_PREFIX/usr/share/locale/en\@quot/LC_MESSAGES/grub.mo $MOUNT_PREFIX/boot/grub/locale/en.mo
    cp $MOUNT_PREFIX/etc/default/grub $MOUNT_PREFIX/etc/default/grub.bak
    echo 'GRUB_DEFAULT=saved' >>$MOUNT_PREFIX/etc/default/grub
    echo 'GRUB_SAVEDEFAULT=true' >>$MOUNT_PREFIX/etc/default/grub
    ch grub-mkconfig -o /boot/grub/grub.cfg
}

install_startup_runner() {
    touch "$MOUNT_PREFIX/home/$INIT_USER/$POST_INSTALL_NAME"
    cp "$0" "$MOUNT_PREFIX/home/$INIT_USER/$SELF_NAME"
    chmod a+x "$MOUNT_PREFIX/home/$INIT_USER/$SELF_NAME"
}

set_timezone() {
    sudo timedatectl set-timezone $TIMEZONE
    sudo timedatectl set-ntp true
}

set_hostname() {
    sudo hostnamectl set-hostname $HOSTNAME
    echo '127.0.0.1 localhost' | sudo tee -a /etc/hosts
    echo "127.0.1.1 $HOSTNAME" | sudo tee -a /etc/hosts
}

post_installs() {
    sudo pacman -S --noconfirm \
        amd-ucode \
        xorg-server \
        virtualbox-guest-utils \
        xf86-video-vmware \
        xfce4 \
        xfce4-goodies \
        lightdm \
        lightdm-gtk-greeter
    sudo systemctl enable vboxservice lightdm
}

remove_autorun() {
    sudo rm $POST_INSTALL_NAME $SELF_NAME
}

execute
