#!/bin/sh
# plan.sh: run by h9build in the builder root. Railpack reads the source at
# /h9build/src and writes its build plan to plan.json in the cwd.
#
# Railpack resolves versions with the mise it pins, which it keeps in
# /tmp/railpack/mise and downloads if it isn't there. h9build keeps that
# binary in its tools between runs, so put it back first, and save it after.
set -eu
W=/mnt/term/cwd
mkdir -p /tmp/railpack/mise "$W/cache/mise-bin"
for m in /h9build/tools/mise-*; do [ -e "$m" ] && cp "$m" /tmp/railpack/mise/; done
/h9build/tools/railpack plan --out "$W/plan.json" /h9build/src
for m in /tmp/railpack/mise/mise-*; do
	[ -e "/h9build/tools/$(basename "$m")" ] || cp "$m" "$W/cache/mise-bin/"
done
# A provider that fails (a version it can't resolve, say) still writes a plan,
# with no steps: show Railpack's own account of why.
if ! jq -e '(.steps // []) | length > 0' "$W/plan.json" >/dev/null; then
	echo "h9build: Railpack made no build steps:" >&2
	/h9build/tools/railpack info --format json /h9build/src | jq -r '.logs[]? | "  \(.Level): \(.Msg)"' >&2
	exit 1
fi
jq -r '"h9build: plan: \([.steps[].name] | join(", ")); start: \(.deploy.startCommand // "none")"' "$W/plan.json" >&2
