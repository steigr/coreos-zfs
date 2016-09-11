# ZFS on Linux for CoreOS

This project aims to make ZFS on Linux available for CoreOS.
As CoreOS protects every system folder providing kernel modules is a bit of an issue.

I can be managed by instructing modprobe to run insmod with the explicit module path.
The rest is basically extracting all relevant files after the build into on package, thus
enabling systemd to start the services properly and make the zfs tool available under $PATH.

## Building

Checkout the git repo:
`set -a; . /usr/share/coreos/lsb-release; git clone --branch $DISTRIB_RELEASE github.com/steigr/coreos-zfs`

Run the build script in fedora container:
`docker run --rm --tty --interactive --volume=$PWD:$PWD --workdir=$PWD fedora ./build.sh`

Check results:
`find $PWD/artifacts`