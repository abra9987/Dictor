#!/bin/bash

# Проверки репозитория. Всё, что касалось апстримовой раздачи (install.sh,
# uninstall.sh, update.json, ссылки на чужой GitHub), удалено вместе с
# апдейтером: этих файлов в проекте нет, и проверки по ним падали.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

bash -n scripts/build-app.sh scripts/check.sh
plutil -lint swift/Info.plist entitlements.plist

app_version="$(plutil -extract CFBundleShortVersionString raw -o - swift/Info.plist)"
bundle_id="$(plutil -extract CFBundleIdentifier raw -o - swift/Info.plist)"

[[ "$bundle_id" == "com.raul.dictor" ]] || {
    printf 'Unexpected bundle id: %s\n' "$bundle_id" >&2
    exit 1
}

grep -q 'com.apple.security.device.audio-input' entitlements.plist
grep -q 'com.apple.security.device.microphone' entitlements.plist

grep -q 'Restarting the build natively for Apple Silicon' scripts/build-app.sh
grep -q 'validate_output_app_path "$OUTPUT_APP"' scripts/build-app.sh

# Апстримовое имя допустимо только в файлах атрибуции — этого требует MIT.
# Иголка склеивается из кусков, иначе grep находит сам этот файл.
needle="super""dictate"
if grep -rniI "$needle" --exclude-dir=.git --exclude-dir=.build \
        --exclude-dir=dist --exclude=NOTICE.md --exclude=LICENSE . >/dev/null; then
    printf 'Upstream name leaked outside LICENSE/NOTICE.md:\n' >&2
    grep -rniI "$needle" --exclude-dir=.git --exclude-dir=.build \
        --exclude-dir=dist --exclude=NOTICE.md --exclude=LICENSE . >&2
    exit 1
fi

git diff --check
printf 'Dictor checks passed (v%s).\n' "$app_version"
