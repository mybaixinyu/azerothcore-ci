#!/bin/bash
# Patch 0045 keeps a set of the event types in SmartScript::mEvents, updated by its only writer AppendEvent.
# Fails if any other code mutates mEvents or retypes events, so a new upstream writer cannot silently bypass it.
# Usage: check0045.sh <core source root>
d="$1/src/server/game/AI/SmartScripts"; f=("$d"/*.cpp "$d"/*.h)
[ -f "$d/SmartScript.h" ] || { echo "0045 check: $d/SmartScript.h missing"; exit 1; }
/usr/bin/grep -q '0045-sole-writer' "$d/SmartScript.h" || { echo "0045 check: AppendEvent marker missing"; exit 1; }
bad=$(/usr/bin/grep -nE 'mEvents *(\.|->) *(push_back|emplace_back|emplace|insert|assign|swap|resize|erase|clear|pop_back)|mEvents *=[^=]|[(,] *mEvents *[,)]' "${f[@]}" | /usr/bin/grep -v '0045-sole-writer' | /usr/bin/grep -v 'SortEvents(mEvents)')
[ -z "$bad" ] || { echo "0045 check: mEvents written outside AppendEvent:"; echo "$bad"; exit 1; }
n=$(cat "$d/SmartScript.cpp" "$d/SmartScript.h" | /usr/bin/grep -cE '\bevent\.type *=[^=]')
[ "$n" = 4 ] || { echo "0045 check: expected 4 event.type assignments (CreateSmartEvent, 3 on mTimedActionList), found $n; re-audit 0045"; /usr/bin/grep -nE "\bevent\.type *=[^=]" "$d/SmartScript.cpp" "$d/SmartScript.h"; exit 1; }
echo "0045 check: ok"
