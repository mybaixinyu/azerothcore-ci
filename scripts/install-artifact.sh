#!/bin/bash
# Fetch the latest successful build-macos artifact and install it into server-pb.
# Refuses to run while the server is up: replacing a running worldserver's binary
# is how you get a half-swapped install and a crash on the next map load.
#
#   install-artifact.sh              # newest successful run
#   install-artifact.sh <run-id>     # a specific run
set -euo pipefail

# A download that spans an idle-sleep window dies mid-transfer: gh reports
# "error writing zip archive: unexpected EOF", which reads like a broken
# download tool rather than a machine that went to sleep.
if [ -z "${INSTALL_ARTIFACT_AWAKE:-}" ]; then
    INSTALL_ARTIFACT_AWAKE=1 exec caffeinate -i "$0" "$@"
fi

repo="mybaixinyu/azerothcore-ci"
prefix="$HOME/WorkSpace/azerothcore/server-pb"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

if pgrep -x worldserver >/dev/null || pgrep -x authserver >/dev/null; then
    echo "worldserver/authserver is running - stop it first (SIGINT, never SIGTERM)." >&2
    exit 1
fi

run_id="${1:-}"
if [ -z "$run_id" ]; then
    run_id=$(gh run list -R "$repo" --workflow build-macos.yml \
        --status success --limit 1 --json databaseId --jq '.[0].databaseId')
    [ -n "$run_id" ] || { echo "no successful build-macos run found" >&2; exit 1; }
fi
echo "== run $run_id"

gh run download "$run_id" -R "$repo" -n server-pb-macos-arm64 -D "$staging"
cat "$staging/bin/BUILD-MANIFEST.txt"

test -x "$staging/bin/worldserver" || { echo "artifact has no worldserver" >&2; exit 1; }
"$staging/bin/worldserver" --version >/dev/null || {
    echo "downloaded worldserver will not start on this machine" >&2; exit 1; }

stamp="$(date +%Y%m%d-%H%M%S)"
for b in worldserver authserver; do
    [ -f "$prefix/bin/$b" ] && cp "$prefix/bin/$b" "$prefix/bin/$b.bak-$stamp"
done

rsync -a --delete "$staging/bin/lib/" "$prefix/bin/lib/"
rsync -a "$staging/bin/" "$prefix/bin/" --exclude 'lib/'
# .dist files only: the live *.conf in etc/ carries local settings and is never touched.
rsync -a --include '*/' --include '*.dist' --exclude '*' "$staging/etc/" "$prefix/etc/"

echo "== installed"
"$prefix/bin/worldserver" --version | head -2
echo "previous binaries kept as bin/*.bak-$stamp"
