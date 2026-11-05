#!/bin/bash
# Patch 0043 sends every allocation its pool does not serve to malloc from the one call in SystemNew, so xzone malloc,
# which types an untyped allocation by its caller's return address, sees one type per size. Fails if the compiler
# inlined, cloned or tail-called SystemNew, which brings back one bucket per call site. An instrumented build
# (-fprofile-generate) rotates SystemNew's retry loop and so calls malloc twice, the second time only after a new
# handler has run; --instrumented accepts exactly that. Usage: check-0043.sh [--instrumented] <worldserver>
want=1
[ "$1" = --instrumented ] && { want=2; shift; }
b="$1"
[ -f "$b" ] || { echo "0043 check: $b missing"; exit 1; }
syms=$(nm "$b" | awk '$3 ~ /SystemNew/ {print $3}')
[ "$(printf '%s\n' "$syms" | /usr/bin/grep -c .)" = 1 ] || { echo "0043 check: expected exactly one SystemNew symbol, found:"; echo "$syms"; exit 1; }
dis=$(mktemp); trap 'rm -f "$dis"' EXIT
otool -tvV "$b" >"$dis" || { echo "0043 check: otool failed"; exit 1; }
body=$(awk -v f="$syms:" '$0 == f {p = 1; next} p && /^[^0-9 \t].*:$/ {exit} p' "$dis")
[ -n "$body" ] || { echo "0043 check: no code for $syms"; exit 1; }
calls=$(printf '%s\n' "$body" | /usr/bin/grep -cE $'\t''bl'$'\t''.*_malloc$')
tails=$(printf '%s\n' "$body" | /usr/bin/grep -cE $'\t''b'$'\t''.*_malloc$')
[ "$calls" = "$want" ] && [ "$tails" = 0 ] || { echo "0043 check: SystemNew should call malloc $want time(s) and not as a tail call (bl $calls, b $tails):"; printf '%s\n' "$body"; exit 1; }
# The new-handler loop exists only in SystemNew, so a call to get_new_handler anywhere else is an inlined copy.
all=$(/usr/bin/grep -cE 'get_new_handler' "$dis")
own=$(printf '%s\n' "$body" | /usr/bin/grep -cE 'get_new_handler')
[ "$all" = "$own" ] || { echo "0043 check: get_new_handler called outside SystemNew ($all sites, $own in SystemNew):"; /usr/bin/grep -nE 'get_new_handler' "$dis" | head; exit 1; }
echo "0043 check: ok ($syms calls malloc $want time(s))"
