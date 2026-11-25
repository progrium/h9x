#!/bin/sh
# capture.sh RAILPACK EXAMPLES: remakes plan.zig's fixtures from the POC.
#
# For each example plan.zig is tested on, runs guest/plan.sh on the host,
# as the POC runs it in the builder root, with RAILPACK (Railpack's static
# binary, at the version h9x pins) and Railpack's examples at the same
# version (EXAMPLES, its examples/ directory). Each example's directory here
# gets:
#
#   plan.json, steps.txt, keys.txt, shared.txt, deploy.txt, apt-build.txt,
#   apt-runtime.txt   what plan.sh wrote
#   info.json         `railpack info --format json`: the provider and versions
#   src.tar           the source, which the keys hash
#
# It needs jq, bash, and GNU coreutils. plan.sh runs under bash rather than
# sh: the builder root's sh is busybox's, whose echo leaves backslashes
# alone, as bash's does and dash's doesn't. Busybox sorts bytewise, so
# everything runs in the C locale.
set -eu
[ $# -eq 2 ] || { echo "usage: capture.sh RAILPACK EXAMPLES" >&2; exit 2; }
railpack=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
examples=$(cd "$2" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
export LC_ALL=C
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sed "s|^W=/mnt/term/cwd\$|W=\$H9X_OUT|" "$repo/guest/plan.sh" >"$work/plan.sh"
for name in $(cat "$here/examples.txt"); do
	echo "capture.sh: $name" >&2
	rm -rf "$work/src" "$work/out"
	mkdir -p "$work/src" "$work/out"
	cp -R "$examples/$name" "$work/src/$name"
	H9X_OUT=$work/out H9X_SRC=$work/src/$name H9X_RAILPACK=$railpack bash "$work/plan.sh" 2>/dev/null
	"$railpack" info --format json --out "$work/out/info.json" "$work/src/$name" 2>/dev/null
	d=$here/$name
	rm -rf "$d"
	mkdir -p "$d"
	for f in plan.json info.json steps.txt keys.txt shared.txt deploy.txt apt-build.txt apt-runtime.txt; do
		cp "$work/out/$f" "$d/"
	done
	(cd "$work/src/$name" && tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner --format=ustar -cf "$d/src.tar" .)
done
