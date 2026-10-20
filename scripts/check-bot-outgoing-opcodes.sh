#!/bin/bash
# Patch module/0007 hands a bot's packets that are sent while maps update to the world
# thread, but only the opcodes PlayerbotAI::IsHandledBotOutgoingOpcode lists; everything
# else is dropped there. That list repeats the cases PlayerbotAI::HandleBotOutgoingPacket
# switches on, so a case added upstream would silently stop working for those packets.
# Fail the build when the two lists differ.
set -euo pipefail

module="${1:?usage: check-bot-outgoing-opcodes.sh <mod-playerbots dir>}"
src="$module/src/Bot/PlayerbotAI.cpp"

# Top-level case labels (8-space indent) of one PlayerbotAI member function
cases() {
    awk -v fn="PlayerbotAI::$1(" '
        index($0, fn) && $0 ~ /^[A-Za-z]/ { inside = 1; next }
        inside && /^}/ { exit }
        inside && /^        case [A-Z_0-9]+:/ { sub(/^ +case /, ""); sub(/:.*/, ""); print }
    ' "$src" | sort
}

listed="$(cases IsHandledBotOutgoingOpcode)"
switched="$(cases HandleBotOutgoingPacket)"

if [ -z "$listed" ] || [ -z "$switched" ]; then
    echo "no case labels found in $src - did the functions move or get renamed?" >&2
    exit 1
fi

if [ "$listed" != "$switched" ]; then
    echo "IsHandledBotOutgoingOpcode (<) and HandleBotOutgoingPacket (>) disagree:" >&2
    diff <(echo "$listed") <(echo "$switched") >&2 || true
    exit 1
fi

echo "bot outgoing opcodes in step: $(echo "$listed" | wc -l | tr -d ' ') cases"
