#!/bin/bash
# Copy every non-system dylib the installed binaries need into <bindir>/lib and
# repoint the load commands at @executable_path/lib, so the payload runs on a
# machine that has no Homebrew boost/openssl/readline/mysql client installed.
# arm64 rejects a binary whose signature no longer matches, so everything that
# is rewritten gets re-signed ad hoc afterwards.
set -euo pipefail

bindir="${1:?usage: bundle-dylibs.sh <bindir>}"
libdir="$bindir/lib"
mkdir -p "$libdir"

external_deps() {
    otool -L "$1" | tail -n +2 | awk '{print $1}' \
        | grep -vE '^(/usr/lib/|/System/|@executable_path/|@rpath/|@loader_path/)' || true
}

# Breadth-first: a copied dylib pulls in its own dependencies (the boost
# libraries reference each other), so keep sweeping until nothing new appears.
queue=()
while IFS= read -r f; do
    [[ "$(file -b "$f")" == *Mach-O* ]] && queue+=("$f")
done < <(find "$bindir" -maxdepth 1 -type f)

bundled=0
while [ ${#queue[@]} -gt 0 ]; do
    current=("${queue[@]}")
    queue=()
    for f in "${current[@]}"; do
        while IFS= read -r dep; do
            [ -n "$dep" ] || continue
            base="$(basename "$dep")"
            if [ ! -f "$libdir/$base" ]; then
                # cp follows the /opt/homebrew/opt/... symlink and copies the target.
                cp "$dep" "$libdir/$base"
                chmod u+w "$libdir/$base"
                install_name_tool -id "@executable_path/lib/$base" "$libdir/$base"
                bundled=$((bundled + 1))
                queue+=("$libdir/$base")
            fi
            install_name_tool -change "$dep" "@executable_path/lib/$base" "$f"
        done < <(external_deps "$f")
        codesign --force --sign - --timestamp=none "$f" 2>/dev/null
    done
done

echo "bundled $bundled dylibs into $libdir"
ls -1 "$libdir"
