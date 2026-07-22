#!/bin/bash

set -euo pipefail

APP_PATH="/Applications/SuperDictate.app"
AGENT_LABEL="com.local.superdictate.agent"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"

/bin/launchctl bootout "gui/$UID/$AGENT_LABEL" >/dev/null 2>&1 || true
/usr/bin/pkill -x SuperDictate >/dev/null 2>&1 || true
rm -f "$AGENT_PLIST"

if [[ -w /Applications ]]; then
    rm -rf "$APP_PATH"
else
    sudo rm -rf "$APP_PATH"
fi

printf 'SuperDictate удалён. История и локальная модель сохранены.\n'

