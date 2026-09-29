#!/bin/bash
# Copy every non-system dylib the installed binaries need into <bindir>/lib and
# repoint the load commands at @executable_path/lib, so the payload runs on a
# machine that has no Homebrew boost/openssl/readline/mysql client installed.
# arm64 rejects a binary whose signature no longer matches, so everything that
# is rewritten gets re-signed ad hoc afterwards.
#
# RC4 (the client session cipher) lives in OpenSSL 3's legacy provider, a separate
# dylib that libcrypto would look for in a Homebrew Cellar path compiled into it -
# gone after the next `brew upgrade openssl@3`. It is bundled as
# <bindir>/lib/ossl-modules/legacy.dylib; the core (patch 0002) points OpenSSL's
# provider search path there at startup.
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

moddir="$(strings "$libdir/libcrypto.3.dylib" | grep -E '^/.*/ossl-modules$' | sed -n 1p)"
[ -f "$moddir/legacy.dylib" ] || { echo "no legacy.dylib in '$moddir'" >&2; exit 1; }
mkdir -p "$libdir/ossl-modules"
cp "$moddir/legacy.dylib" "$libdir/ossl-modules/legacy.dylib"
chmod u+w "$libdir/ossl-modules/legacy.dylib"
while IFS= read -r dep; do
    install_name_tool -change "$dep" "@executable_path/lib/$(basename "$dep")" "$libdir/ossl-modules/legacy.dylib"
done < <(external_deps "$libdir/ossl-modules/legacy.dylib")
codesign --force --sign - --timestamp=none "$libdir/ossl-modules/legacy.dylib" 2>/dev/null
echo "bundled the OpenSSL legacy provider"
