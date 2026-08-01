#!/bin/bash

# Проверки репозитория. Всё, что касалось апстримовой раздачи (install.sh,
# uninstall.sh, update.json, ссылки на чужой GitHub), удалено вместе с
# апдейтером: этих файлов в проекте нет, и проверки по ним падали.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

bash -n scripts/build-app.sh scripts/check.sh scripts/make-dmg.sh scripts/make-release.sh
plutil -lint swift/Info.plist entitlements.plist

app_version="$(plutil -extract CFBundleShortVersionString raw -o - swift/Info.plist)"
bundle_id="$(plutil -extract CFBundleIdentifier raw -o - swift/Info.plist)"

[[ "$bundle_id" == "com.raul.dictor" ]] || {
    printf 'Unexpected bundle id: %s\n' "$bundle_id" >&2
    exit 1
}

grep -q 'com.apple.security.device.audio-input' entitlements.plist
grep -q 'com.apple.security.device.microphone' entitlements.plist

# Апдейтер ставит только сборки, подписанные этим сертификатом. Разъедется
# отпечаток со связкой ключей — обновления молча перестанут ставиться.
pinned="$(sed -n 's/^let UPDATE_SIGNING_CERT_SHA1 = "\([0-9A-F]*\)"$/\1/p' \
    swift/Sources/Dictor/CoreTypes.swift)"
[[ -n "$pinned" ]] || {
    printf 'UPDATE_SIGNING_CERT_SHA1 not found in CoreTypes.swift\n' >&2
    exit 1
}
if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Dictor Dev"'; then
    actual="$(security find-identity -v -p codesigning \
        | awk -F' ' '/"Dictor Dev"/ {print $2; exit}')"
    [[ "$actual" == "$pinned" ]] || {
        printf 'Pinned signing cert %s does not match keychain identity %s\n' \
            "$pinned" "$actual" >&2
        exit 1
    }
fi

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

# Апдейтер не должен уводить человека в чужой репозиторий. Кнопка «Update
# now…» вместо установки показывала совет скормить bash установочный скрипт
# с апстримового GitHub, и заметить это было нельзя: цикл проверки стоял за
# мёртвым `return`, до кнопки не доходило. Стережём имя апстримового
# владельца в исходниках — документация про историю проекта писать о нём
# вправе.
upstream_owner="shl""gd"
if grep -rniI "$upstream_owner" swift/Sources scripts >/dev/null; then
    printf 'Upstream repository reference leaked back into the sources:\n' >&2
    grep -rniI "$upstream_owner" swift/Sources scripts >&2
    exit 1
fi

# Установку обновления зовёт и меню-бар, и окно. Пока она была написана
# внутри ControlPanel, из агента до неё было не дотянуться.
grep -q 'func launchPreparedDictorUpdate' swift/Sources/Dictor/UpdateCheck.swift
grep -q 'launchPreparedDictorUpdate(prepared' swift/Sources/Dictor/App.swift

# Страница канала. Ломается она тихо: битая ссылка на картинку видна только
# на выложенном сайте, а незаполненная подстановка — только человеку, который
# пришёл скачивать.
python3 - <<'PY'
import pathlib, re, sys

root = pathlib.Path("web")
pages = [root / "index.html", root / "en" / "index.html"]
problems = []

for page in pages:
    if not page.exists():
        problems.append(f"{page}: страницы нет")
        continue
    text = page.read_text(encoding="utf-8")
    for token in ("{{VERSION}}", "{{SHA256}}", "{{DMG_SIZE}}"):
        if token not in text:
            problems.append(f"{page}: нет подстановки {token} — "
                            "версия на странице замёрзнет")
    for leftover in set(re.findall(r"\{\{[A-Z_]+\}\}", text)) - {
            "{{VERSION}}", "{{SHA256}}", "{{DMG_SIZE}}"}:
        problems.append(f"{page}: неизвестная подстановка {leftover}")
    for asset in re.findall(r'(?:src|href)="((?:\.\./)?(?:assets/[^"]+|favicon\.ico))"',
                            text):
        target = (page.parent / asset).resolve()
        if not target.exists():
            problems.append(f"{page}: нет файла {asset}")

    # Карточка превью указывается полным адресом — соцсети относительных не
    # понимают. Проверяем, что за адресом лежит наш файл: битую карточку
    # видно только там, где ссылку уже отправили.
    for absolute in re.findall(r'content="https://[^"]+/(assets/[^"]+)"', text):
        if not (root / absolute).exists():
            problems.append(f"{page}: og:image ссылается на {absolute}, которого нет")
    if "og:image" not in text:
        problems.append(f"{page}: нет og:image — ссылка развернётся пустой карточкой")

if problems:
    print("Channel page checks failed:", file=sys.stderr)
    for problem in problems:
        print("  " + problem, file=sys.stderr)
    sys.exit(1)
PY

git diff --check
printf 'Dictor checks passed (v%s).\n' "$app_version"
