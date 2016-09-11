#!/usr/bin/env bash

set -e${TRACE:+x}o pipefail
trap 'exit' EXIT

export CI_PROJECT_DIR="${CI_PROJECT_DIR:-$PWD}"
export DEST="${DEST:-/artifacts/build}"
export CI_BUILD_REF_NAME="${CI_BUILD_REF_NAME:-master}"

export COREOS_CHANNEL="${COREOS_CHANNEL:-alpha}"
export COREOS_RELEASE="${COREOS_RELEASE:-$CI_BUILD_TAG}"
export COREOS_RELEASE="${COREOS_RELEASE:-$(basename $CI_BUILD_REF_NAME | sed -e 's/master/current/' -e 's/develop/current/')}"
export COREOS_CPIO_URL="https://$COREOS_CHANNEL.release.core-os.net/amd64-usr/$COREOS_RELEASE/coreos_production_pxe_image.cpio.gz"

export ZFS_GIT_BRANCH="${ZFS_VERSION:-$(basename $CI_BUILD_REF_NAME | sed -e 's/develop/master/')}"
export MAKE_PARALLEL="$(grep -c processor /proc/cpuinfo)"
export DEST_DIR="$CI_PROJECT_DIR/artifacts/$COREOS_RELEASE/${ZFS_VERSION:-git}"

cd /tmp
curl -L "$COREOS_CPIO_URL" | gunzip | cpio -i
unsquashfs /tmp/usr.squashfs

cd /tmp/squashfs-root/lib64 && tar c modules | tar xC /lib
export LINUX_BASE="$(ls -d /lib/modules/*coreos | tail -1)"

cd /tmp/squashfs-root/share && tar c coreos | tar xC /usr/share

[[ -d /usr/lib64 ]] || mkdir -p /usr/lib64
cd /tmp/squashfs-root/lib64 && tar c libcrypto.so* | tar xC /usr/lib64

rm -rf $SYSTEMD_DIR $UDEV_DIR $MODULES_LOAD_DIR $DEFAULT_FILE $SYSTCONF_DIR

if [[ "$ZFS_VERSION" ]]; then
  mkdir -p /usr/src/zfs /usr/src/spl
  curl -sL https://github.com/zfsonlinux/zfs/releases/download/zfs-${ZFS_VERSION}/spl-${ZFS_VERSION}.tar.gz | tar zxvC /usr/src/spl --strip-components=1
  curl -sL https://github.com/zfsonlinux/zfs/releases/download/zfs-${ZFS_VERSION}/zfs-${ZFS_VERSION}.tar.gz | tar zxvC /usr/src/zfs --strip-components=1
else
  git clone --single-branch git://github.com/zfsonlinux/zfs.git /usr/src/zfs
  git clone --single-branch git://github.com/zfsonlinux/spl.git /usr/src/spl
fi

cd /usr/src/spl
./autogen.sh
./configure \
  --sysconfdir=/etc \
  --bindir=$BIN_DIR \
  --sbindir=$SBIN_DIR \
  --libdir=$LIB_DIR \
  --with-linux=$LINUX_BASE/source \
  --with-linux-obj=$LINUX_BASE/build \
  --runstatedir=/run
make -j$MAKE_PARALLEL
make install

cd /usr/src/zfs
./autogen.sh
./configure \
  --with-udevruledir=$UDEV_DIR/rules.d \
  --with-udevdir=$UDEV_DIR \
  --with-mounthelperdir=$SBIN_DIR \
  --sysconfdir=/etc \
  --bindir=$BIN_DIR \
  --sbindir=$SBIN_DIR \
  --libdir=$LIB_DIR \
  --with-systemdunitdir=$SYSTEMD_DIR/system \
  --with-systemdpresetdir=$SYSTEMD_DIR/system-preset \
  --with-systemdmodulesloaddir=$MODULES_LOAD_DIR \
  --libexecdir=$LIB_DIR \
  --with-linux=$LINUX_BASE/source \
  --with-linux-obj=$LINUX_BASE/build \
  --runstatedir=/run
make -j$MAKE_PARALLEL
make install

find $OEM_PATH -name '*.ko' | xargs -r -t -n1 strip --strip-unneeded --strip-debug

find $BIN_DIR $SBIN_DIR $LIB_DIR -type f -not -name '*.ko' | xargs -n1 file | grep ELF | cut -f1 -d":" | xargs -r -t -n1 strip

DEPENDENCY_zfs="zunicode zavl zcommon znvpair spl"
DEPENDENCY_icp="spl"
DEPENDENCY_zcommon="spl znvpair"
DEPENDENCY_znvpair="spl"

find $CI_PROJECT_DIR/systemd -type d | while read install_dir; do
  install -o root -g root -m 0755 -d ${install_dir//$CI_PROJECT_DIR\/systemd/$SYSTEMD_DIR}
done

find $CI_PROJECT_DIR/systemd -type f | while read install_file; do
  install -o root -g root -m 0644  $install_file ${install_file//$CI_PROJECT_DIR\/systemd/$SYSTEMD_DIR}
done

install -o root -g root -m 0755 -d -D $DEST/etc/modprobe.d
for module in $(find $INSTALL_MOD_PATH -name "*.ko"); do
  module_name=$(basename "$module" | sed -e 's/\.ko$//')
  module_path=$(echo "$module" | sed -e "s#\($INSTALL_MOD_PATH/lib/modules/\)[^/]*/#\1\$\(uname -r\)/#")
  module_depends=DEPENDENCY_${module_name}
  module_depends=${!module_depends}
  cat<<modprobe_conf_for_module | install -m 0644 -o root -g root /dev/stdin "$DEST/etc/modprobe.d/$module_name.conf"
install $module_name sh -c '${module_depends:+echo $module_depends | xargs -n1 modprobe; }exec insmod $module_path \$CMDLINE_OPTS'
remove  $module_name sh -c 'rmmod \$MODPROBE_MODULE${module_depends:+; echo $module_depends | xargs -n1 modprobe -r}'
modprobe_conf_for_module
done

install -o root -g root -m 0755 -d -D $DEST/etc/bash/bashrc.d
install -o root -g root -m 0755    $CI_PROJECT_DIR/bash/zfs $DEST/etc/bash/bashrc.d/zfs

install -o root -g root -m 0755 -d $MODULES_LOAD_DIR
install -o root -g root -m 0755    $CI_PROJECT_DIR/modules-load.d/zfs.conf $MODULES_LOAD_DIR/zfs.conf

tar -c $SYSTCONF_DIR $SYSTEMD_DIR $UDEV_DIR $MODULES_LOAD_DIR $LIB_DIR $SBIN_DIR $INSTALL_MOD_PATH/lib/modules | tar -x -C "$DEST"

mkdir -p "$DEST_DIR"

cd "$DEST"

tar c * | xz -9ez > "$DEST_DIR/zfs.tar.xz"

rm -rf $DEST

installer() {
  cat<<installer
#cloud-config
coreos:
  units:
  - name: install-zfs.service
    runtime: yes
    command: start
    content: |
      [Unit]
      After=network-online.target
      [Service]
      Type=oneshot
      EnvironmentFile=/usr/share/coreos/lsb-release
      ExecStart=/usr/bin/env bash -c 'curl -L https://github.com/$GITHUB_USER/$GITHUB_REPO/releases/download/$( echo $COREOS_RELEASE| sed -e '/current/! s/.*/\${DISTRIB_RELEASE}/' )/zfs.tar.xz | tar -J -x -o -m -C /'
      ExecStart=/usr/sbin/ldconfig
      ExecStart=/usr/bin/systemctl preset-all
      ExecStart=/usr/bin/systemctl enable zfs-modules-load.service zfs-release-update.service
      ExecStart=/usr/bin/systemctl start zfs.target
      ExecStartPost=/usr/bin/rm /run/systemd/system/install-zfs.service
      ExecStartPost=/usr/bin/systemctl daemon-reload
installer
}

offline_installer() {
  cat<<offline_installer
#cloud-config
coreos:
  units:
  - name: install-zfs.service
    runtime: yes
    command: start
    content: |
      [Unit]
      After=network-online.target
      [Service]
      Type=oneshot
      ExecStart=/usr/bin/tar -J -x -o -m -C / -f /tmp/$os_release/zfs.tar.xz
      ExecStart=/usr/sbin/ldconfig
      ExecStart=/usr/bin/systemctl preset-all
      ExecStart=/usr/bin/systemctl enable zfs-modules-load.service zfs-release-update.service
      ExecStart=/usr/bin/systemctl start zfs.target     
      ExecStartPost=/usr/bin/rm /run/systemd/system/install-zfs.service /tmp/$os_release/zfs.tar.xz
      ExecStartPost=/usr/bin/systemctl daemon-reload
write_files:
- path: "/tmp/$os_release/zfs.tar.xz"
  permissions: "0600"
  owner: "root:root"
  encoding: "base64"
  content: |
offline_installer
}


payload() {
  printf '    '
  base64 -w0 -i $os_release/$zfs_release/zfs.tar.xz
}

save() {
  cat > $os_release/$zfs_release/zfs${1:+-$1}.yml
}

append() {
  cat >> $os_release/$zfs_release/zfs${1:+-$1}.yml
}

mk_installer() {
  export os_release=$1
  export zfs_release=$2
  installer | save
}

mk_offline_installer() {
  export os_release=$1
  export zfs_release=$2
  offline_installer | save   offline
          payload | append offline
}

cd "$CI_PROJECT_DIR/artifacts"
mk_installer $COREOS_RELEASE ${ZFS_VERSION:-git}
mk_offline_installer $COREOS_RELEASE ${ZFS_VERSION:-git}
