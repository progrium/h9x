#!/bin/sh
# build.sh: run by h9build in the builder root. Carries out the steps of
# Railpack's plan (plan.json in the cwd) in order, as its BuildKit backend
# would, but in one machine and in place:
#
#   /mise  the runtime layer (layers/runtime/mise), where mise installs
#   /app   the app (layers/app/app), where the install and build steps run
#
# Both are binds of host directories under the cwd, so package managers can
# rename across directories in them. Afterwards the paths the plan deploys
# from under /app other than the app itself (node_modules, .venv) move to the
# deps layer, and the run environment goes to env.
#
# A step's variables and PATH entries carry on to later steps, as a BuildKit
# state's environment does. apt steps are skipped: the root is Wolfi's.
set -eu
W=/mnt/term/cwd
P=$W/plan.json
log() { echo "h9build: $*" >&2; }

# mise, at the version Railpack pins, where Railpack's builder image has it.
mise=$(ls /h9build/tools/mise-* 2>/dev/null | head -1)
[ -n "$mise" ] || { log "no mise in the tools; did plan.sh run?"; exit 1; }
mkdir -p /usr/local/bin && cp "$mise" /usr/local/bin/mise
export PATH=/usr/local/bin:/usr/bin:/bin

# Package managers' caches, kept per app under the cwd. The plan names its
# cache directories (/root/.npm, /root/.cache/uv), but a link from there to
# the cwd doesn't work: an absolute link in the guest's overlay resolves in
# the Linux tree, where /mnt/term isn't. So point the managers at it instead.
C=$W/cache
mkdir -p "$C"
export npm_config_cache=$C/npm YARN_CACHE_FOLDER=$C/yarn PNPM_STORE_DIR=$C/pnpm \
	BUN_INSTALL_CACHE_DIR=$C/bun UV_CACHE_DIR=$C/uv PIP_CACHE_DIR=$C/pip \
	POETRY_CACHE_DIR=$C/poetry GOMODCACHE=$C/go/mod GOCACHE=$C/go/build \
	BUNDLE_USER_CACHE=$C/bundle COMPOSER_CACHE_DIR=$C/composer

# The source, less what the plan excludes, as a tar stream.
excludes=$(jq -r '.exclude // [] | .[]' "$P")
source_tar() {
	set --
	for e in $excludes; do set -- "$@" --exclude "./$e"; done
	tar -C /h9build/src "$@" -cf - .
}

n=$(jq '.steps | length' "$P")
i=0
while [ "$i" -lt "$n" ]; do
	step=$(jq -c ".steps[$i]" "$P")
	i=$((i + 1))
	name=$(echo "$step" | jq -r .name)
	case $name in
	packages:apt:*)
		log "skipping $name: $(echo "$step" | jq -r '[.commands[]?.cmd // empty] | join("; ")')"
		continue
		;;
	esac
	log "step $name"
	# Its variables, then h9build's overrides for mise: downloads and
	# shims stay out of the runtime layer (shims are links to the mise
	# binary, a path only the builder has).
	vars=$(echo "$step" | jq -r '.variables // {} | to_entries[] | "\(.key)=\(.value)"')
	if [ -n "$vars" ]; then
		while IFS= read -r kv; do export "$kv"; done <<EOF
$vars
EOF
	fi
	case $name in
	packages:mise)
		export MISE_CACHE_DIR=$W/cache/mise MISE_SHIMS_DIR=/tmp/mise-shims MISE_YES=1
		;;
	esac
	# A venv's python is a link to the runtime by absolute path, and h9
	# can't follow an absolute link in a host directory such as /app,
	# so uv can't start the venv's interpreter to compile bytecode. The
	# app still runs: in the run's #L stack, absolute links resolve.
	[ -n "${UV_COMPILE_BYTECODE:-}" ] && export UV_COMPILE_BYTECODE=0
	# A step that takes the local source gets all of it, less the excludes.
	if echo "$step" | jq -e '[.inputs[]? | select(.local == true)] | length > 0' >/dev/null; then
		source_tar | tar -C /app -xf -
	fi
	cmds=$(echo "$step" | jq -c '.commands // [] | .[]')
	[ -n "$cmds" ] || continue
	while IFS= read -r c; do
		if echo "$c" | jq -e 'has("cmd")' >/dev/null; then
			cmd=$(echo "$c" | jq -r .cmd)
			log "  $(echo "$c" | jq -r '.customName // .cmd')"
			(cd /app && sh -c "$cmd") </dev/null
		elif echo "$c" | jq -e 'has("src")' >/dev/null; then
			s=$(echo "$c" | jq -r .src) d=$(echo "$c" | jq -r .dest)
			case $d in /*) ;; *) d=/app/$d ;; esac
			mkdir -p "$(dirname "$d")"
			cp -a "/h9build/src/$s" "$d"
		elif echo "$c" | jq -e 'has("name")' >/dev/null; then
			f=$(echo "$c" | jq -r .path)
			mkdir -p "$(dirname "$f")"
			echo "$step" | jq -r --arg a "$(echo "$c" | jq -r .name)" '.assets[$a]' >"$f"
		elif echo "$c" | jq -e 'has("path")' >/dev/null; then
			d=$(echo "$c" | jq -r .path)
			# mise's shims don't run under h9; the runtimes' own bin
			# directories go on PATH after the mise step instead.
			[ "$d" = /mise/shims ] && continue
			export PATH="$d:$PATH"
		fi
	done <<EOF
$cmds
EOF
	if [ "$name" = packages:mise ]; then
		# Each installed version's bin, read from the layer: mise's own
		# bin-paths re-resolves versions under the plan's settings and
		# can miss what it just installed. -type d skips the alias links
		# (node/24 -> 24.22.2). Tools from aqua (uv) unpack as released,
		# and mise lists their binaries in .mise-bins as links with
		# absolute targets. h9 doesn't follow those in a host tree (it
		# resolves them inside the tree, and readdir leaves them out), so
		# take the directories that hold executables instead.
		bins=
		for v in $(find /mise/installs -mindepth 2 -maxdepth 2 -type d | sort); do
			if [ -d "$v/bin" ]; then
				bins=$bins$v/bin:
				continue
			fi
			for d in $(find "$v" -maxdepth 2 -type f -perm -u+x ! -path '*/.mise-bins/*' -exec dirname {} \; | sort -u); do
				bins=$bins$d:
			done
		done
		export PATH="$bins$PATH"
		log "  PATH=$PATH"
	fi
done

# The deps layer: what the plan deploys from under /app besides the app.
mkdir -p "$W/layers/deps/app"
for d in $(jq -r '[.deploy.inputs[]?.include // [] | .[] | select(startswith("/app/"))] | unique | .[]' "$P"); do
	[ -e "$d" ] || continue
	log "deps: $d"
	mkdir -p "$W/layers/deps$(dirname "$d")"
	mv "$d" "$W/layers/deps$d"
done

# The layers the run needs, in stacking order: the runtime only when the plan
# deploys from the mise step (a Go binary doesn't need its toolchain), deps
# only when there are any.
{
	jq -e '[.deploy.inputs[]? | select(.step == "packages:mise")] | length > 0' "$P" >/dev/null && echo runtime
	[ -n "$(ls -A "$W/layers/deps/app")" ] && echo deps
	echo app
} >"$W/layers.txt"

# The run environment: the deploy variables, the start command, and a PATH
# with the runtimes' own bin directories in place of mise's shims.
{
	jq -r '.deploy.variables // {} | to_entries[] | "\(.key)=\(.value)"' "$P"
	echo "H9BUILD_START=$(jq -r '.deploy.startCommand // "sh"' "$P")"
	keep=
	IFS=:
	for d in $PATH; do
		case $d in /tmp/* | /usr/local/bin | /usr/bin | /bin) ;; *) keep=$keep$d: ;; esac
	done
	unset IFS
	echo "PATH=${keep}/usr/bin:/bin"
} >"$W/env"
