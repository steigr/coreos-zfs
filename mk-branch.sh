#!/usr/bin/env bash

if test -z "$TEMP_SCRIPT"; then
	[[ -z "$CI_BUILD_REF_NAME" ]] || git checkout "$CI_BUILD_REF_NAME"
	temp_script="$(mktemp)"
	trap 'rm "$temp_script"' EXIT
	cat "$0" > "$temp_script"
	chmod "+x" "$temp_script"
	TEMP_SCRIPT=true "$temp_script"
	exit "$?"
fi

set -e${TRACE:+x}o pipefail

vars() {
	export GIT_BRANCH="${GIT_BRANCH:-$CI_BUILD_REF_NAME}"
	export GIT_BRANCH="${GIT_BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"
	export ZFS_STABLE_VERSION=${ZFS_STABLE_VERSION:-0.6.5.8}
	export JSON_FEED=${JSON_FEED:-https://coreos.com/releases/releases.json}
}

load_feed() {
	test -z "$FEED_TEMP" || return 0
	echo "Loading CoreOS release feed" >&2
	FEED_TEMP=$(mktemp)
	export FEED_TEMP
	trap 'rm "$FEED_TEMP"' EXIT
}

load_releases() {
	echo "Loading CoreOS release channel mapping" >&2
	RELEASES=$(\
		curl --retry 5 -sL http://stable.release.core-os.net/amd64-usr/ | fgrep '[dir]' | cut -f2 -d'>' | cut -f1 -d'<' | grep -v 'current' | sed -e 's/$/:stable/'; \
		curl --retry 5 -sL http://beta.release.core-os.net/amd64-usr/ | fgrep '[dir]' | cut -f2 -d'>' | cut -f1 -d'<' | grep -v 'current' | sed -e 's/$/:beta/'; \
		curl --retry 5 -sL http://alpha.release.core-os.net/amd64-usr/ | fgrep '[dir]' | cut -f2 -d'>' | cut -f1 -d'<' | grep -v 'current' | sed -e 's/$/:alpha/'; \
		)
	export RELEASES
}

feed() {
	if test ! -s "$FEED_TEMP"; then
		curl --retry 5 -sLo "$FEED_TEMP" "$JSON_FEED"
	fi
	cat "$FEED_TEMP"
}

versions() {
	feed \
	| jq -r 'to_entries|.[].key' \
	| sort -n |  uniq	
}

channel_of() {
	echo "$RELEASES" | grep "^${1}:" | head -1 | cut -f2 -d:
}

zfs_version_of() {
	kver=$(feed | jq -r ".\"$1\".major_software.kernel[0]" | cut -f-3 -d.)
	kmajor=${kver%%.*}
	kminor=${kver%.*}
	kminor=${kminor#*.}
	[[ ${kmajor} -lt 4 ]] && ZFS_VERSION=$ZFS_STABLE_VERSION
	[[ ${kminor} -lt 8 ]] && ZFS_VERSION=${ZFS_VERSION:-$ZFS_STABLE_VERSION}
	echo "$ZFS_VERSION"
}

has_release() {
	git branch -v | cut -b3- | awk '{print $1}' | grep -q "^$1$"
}

has_tag() {
	git tag -l | grep -q "^$1\.$"
}

create_release() {
	git checkout -b "$1"
}

create_and_diff_ci_config() {
	local version="$1"
	local channel="$2"
	local zfs_version="$3"
	local target="$4"
	cat<<gitlab_ci_head  > "$target"
image: steigr/zfs:onbuild

stages:
- build
- release
- update

variables:
  GITHUB_USER: steigr
  GITHUB_REPO: coreos-zfs
  DEST: /artifacts/build
  COREOS_RELEASE: "$version"
  COREOS_CHANNEL: "$channel"
  GITHUB_RELEASE_URL: "${GITHUB_RELEASE_URL:-https://github.com/aktau/github-release/releases/download/v0.6.2/linux-amd64-github-release.tar.bz2}"
gitlab_ci_head
	[[ -z "$zfs_version" ]] || \
	echo "  ZFS_VERSION: \"$zfs_version\"" >> "$target"
  cat<<gitlab_ci_foot >> "$target"

build:
  only:
  - tags
  - develop
  stage: build
  artifacts:
    untracked: true
  variables:
    INSTALL_MOD_PATH: /usr/share/oem/zfs
    OEM_PATH: /usr/share/oem/zfs
    BIN_DIR: /usr/share/oem/zfs/bin
    LIB_DIR: /usr/share/oem/zfs/lib64
    SBIN_DIR: /usr/share/oem/zfs/sbin
    SYSTEMD_DIR: /etc/systemd
    UDEV_DIR: /etc/udev
    MODULES_LOAD_DIR: /etc/modules-load.d
    DEFAULT_FILE: /etc/default/zfs
    SYSTCONF_DIR: /etc/zfs
  script:
  - ./build.sh

release:
  stage: release
  only:
  - tags
  script:
  - ./upload.sh

update:
  stage: update
  only:
  - update
  script:
  - ./mk-branch.sh
gitlab_ci_foot
}

git_config() {
	git config --global user.email "GIT_USER_EMAIL"
	git config --global user.name  "GIT_USER_NAME"
}

main() {
	git_config
	load_feed
	load_releases
	for version in ${VERSIONS:-$(versions)}; do
		local channel zfs_version
		if channel="$(channel_of "$version")"; then
			zfs_version="$(zfs_version_of "$version")"
			if has_release "${version%%.*}"; then
				if has_tag "${version}"; then
					echo "reuse coreos $version" >&2
					git checkout -q "${version}"
				else
					echo "reuse coreos ${version%%.*}" >&2
					git checkout -q "${version%%.*}"
				fi
			else
				echo "adding coreos ${version%%.*}" >&2
				create_release "${version%%.*}"
			fi
			create_and_diff_ci_config "$version" "$channel" "$zfs_version" ".gitlab-ci.new.yml"
			if ! cmp -s .gitlab-ci.yml .gitlab-ci.new.yml; then
				echo "update coreos ${version} to zfs ${zfs_version:-git}" >&2
	 			mv .gitlab-ci.new.yml .gitlab-ci.yml
				git add .gitlab-ci.yml
				git commit -m "ZFS on Linux ${zfs_version:-git} on CoreOS $version/$channel"
				if git tag -l | grep -q "^${version}$"; then
					echo "update coreos ${version}" >&2
					git tag -d "$version" >/dev/null
				fi
				git tag -m "ZFS on Linux ${zfs_version:-git} on CoreOS $version/$channel" "$version"
			fi
		fi
		git reset --hard
		git checkout "$GIT_BRANCH"
		if test "$STEPS"; then
			test "$STEPS" -gt 0 || exit 0
			let STEPS-=1
		fi
	done	
}

vars
main "@"