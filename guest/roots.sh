#!/bin/sh
# roots.sh ARCH REPO PACKAGES...: run by h9build in the Alpine bootstrap root.
# Installs Wolfi packages with Alpine's apk into a root in the guest's memory
# and writes it to root.tar in the cwd.
#
# The root is built in /tmp, an overlay in memory, rather than in a host
# directory: apk makes symlinks before their targets exist, which h9 can't do
# in a host tree yet. --no-scripts because apk runs scripts in a chroot.
set -eu
arch=$1 repo=$2
shift 2
r=/tmp/root
mkdir -p "$r/etc/apk/keys"
cp /mnt/term/cwd/wolfi-signing.rsa.pub "$r/etc/apk/keys/"
apk --root "$r" --initdb --no-scripts --no-cache --arch "$arch" \
	--repository "$repo" --keys-dir "$r/etc/apk/keys" add "$@" |
	grep -v '^(' || true
apk --root "$r" info -e "$@" >/dev/null || { echo "roots.sh: some packages didn't install" >&2; exit 1; }
# Alpine's apk keeps its database in /lib/apk, so /lib is a directory and
# wolfi-baselayout's lib -> usr/lib link couldn't replace it. glibc's loader
# is found through it on arm64 (/lib/ld-linux-aarch64.so.1): move the
# database where Wolfi's own apk keeps it, and make the link.
if [ -d "$r/lib" ] && [ ! -L "$r/lib" ]; then
	mkdir -p "$r/usr/lib"
	for f in "$r"/lib/* "$r"/lib/.[!.]*; do
		[ -e "$f" ] || [ -L "$f" ] || continue
		mv "$f" "$r/usr/lib/"
	done
	rmdir "$r/lib"
	ln -s usr/lib "$r/lib"
fi
# The link apk made to rename over /lib, left behind when that failed.
rm -f "$r"/.apk.*
# shadow files are 0640 root: the guest can't read them, and nothing needs them.
cd "$r" && tar --exclude ./etc/shadow --exclude ./etc/gshadow -cf /mnt/term/cwd/root.tar .
