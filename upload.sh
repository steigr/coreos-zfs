#!/usr/bin/env bash

set -e${TRACE:+x}o pipefail
trap 'exit' EXIT

export COREOS_RELEASE="$(basename $CI_BUILD_REF_NAME | sed -e 's/master/current/' -e 's/develop/current/')"
export COREOS_CHANNEL="${COREOS_CHANNEL:-alpha}"
export ARTIFACT_DIRECTORY="$CI_PROJECT_DIR/artifacts/$COREOS_RELEASE/${ZFS_VERSION:-git}"

export RELEASE_TAG="$COREOS_RELEASE"
export RELEASE_NAME="ZFS ${ZFS_VERSION:-git} on Linux for CoreOS $COREOS_CHANNEL/$COREOS_RELEASE"
[[ "$ZFS_VERSION" ]] || export RELEASE_IS_PRERELEASE="--pre-release"

curl -L $GITHUB_RELEASE_URL | bunzip2 | tar xC /usr/local/bin --strip-components=3

# Remove IPv4 connectiviy as build system is IPv6 only
# Requires docker run --privileged ...
ip route del default
ip -o -4 a s eth0 | while read line; do echo $line | awk '{print "ip addr del " $4 " dev " $2 }' | sh -x; done

# Add NAT64 entries as
# - github-release prefer ipv4
# - and github.com has no ipv6 connectivity jet (https://twitter.com/steigr/status/763143066446393344)
echo "64:ff9b::c01e:fd74 api.github.com" >> /etc/hosts
echo "64:ff9b::c01e:fd60 uploads.github.com" >> /etc/hosts

# delete release before uploading new artifacts
github-release delete --user $GITHUB_USER --repo $GITHUB_REPO --tag $RELEASE_TAG || true

# create the new release, maybe it's not pre-release anymore (zfs version is set!)
github-release release --user $GITHUB_USER --repo $GITHUB_REPO --tag $RELEASE_TAG --name "$RELEASE_NAME" --description "$RELEASE_NAME" $RELEASE_IS_PRERELEASE 

# ... and attach built artifacts
find "$ARTIFACT_DIRECTORY" -type f | while read artifact; do
	github-release upload --user $GITHUB_USER --repo $GITHUB_REPO --tag $RELEASE_TAG --name "$(basename $artifact)" --file "$artifact"
done
