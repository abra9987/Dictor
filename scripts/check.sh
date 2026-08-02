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

# Мёртвый код. Дважды этот класс доходил до релиза: апдейтер был написан целиком
# и недостижим, кнопка очистки поиска рисовалась и не принимала кликов.
# Компилятор молчит и про приватный метод без вызывающего, и про класс, который
# никто не создаёт, — сторожить приходится здесь.
python3 - <<'DEADCODE'
import re
import sys
from collections import Counter
from pathlib import Path

sources = sorted(Path("swift/Sources/Dictor").glob("*.swift"))
texts = {p: p.read_text(encoding="utf-8") for p in sources}

# Имена колбэков AppKit: их зовёт фреймворк, вызывающего в коде нет и быть не
# должно. Правило обязано молчать там, где не уверено.
FRAMEWORK_PREFIXES = re.compile(
    r"^(application|window|menu|control|text|tableView|outlineView|splitView|tabView"
    r"|toolbar|collectionView|scrollView|comboBox|panel|sheet|service|net|gesture"
    r"|touchBar|dragging|validate|accessibility|numberOfRows|encode|copy|hash"
    r"|isEqual|observeValue|pasteboard)"
)

DECLARATIONS = [
    # приватные методы: видны только внутри своего файла
    re.compile(r"^\s*(?:@objc\s+)?(?:private|fileprivate)\s+(?:static\s+)?func\s+(\w+)"),
    # функции файлового уровня: свидетелем протокола быть не могут
    re.compile(r"^func\s+(\w+)"),
    # типы файлового уровня: xib и NSClassFromString в проекте не используются
    re.compile(r"^(?:final\s+)?(?:class|struct|enum|actor)\s+(\w+)"),
    # приватные свойства — самое незаметное
    re.compile(r"^\s*(?:private|fileprivate)\s+(?:static\s+)?(?:var|let)\s+(\w+)"),
]
INTERNAL_METHOD = re.compile(r"^\s+(?:static\s+)?func\s+(\w+)")

candidates = set()
for text in texts.values():
    for line in text.split("\n"):
        for pattern in DECLARATIONS:
            match = pattern.match(line)
            if match:
                candidates.add(match.group(1))
        match = INTERNAL_METHOD.match(line)
        if match and not FRAMEWORK_PREFIXES.match(match.group(1)):
            candidates.add(match.group(1))

counts = Counter()
for text in texts.values():
    for word in re.findall(r"\b\w+\b", text):
        if word in candidates:
            counts[word] += 1

dead = sorted(name for name in candidates if counts[name] <= 1)
if not dead:
    sys.exit(0)

print("Объявлено и ни разу не использовано:", file=sys.stderr)
for name in dead:
    for path, text in texts.items():
        for number, line in enumerate(text.split("\n"), 1):
            if re.search(rf"\b{re.escape(name)}\b", line):
                print(f"  {path}:{number}: {name}", file=sys.stderr)
                break
        else:
            continue
        break
sys.exit(1)
DEADCODE

# Сьют самотестов, не достижимый из `--self-test all`, — тот же мёртвый код,
# только в тестах: написан, но не выполняется никогда. Исключения объявлены
# поимённо, дописать четвёртое молча не выйдет.
python3 - <<'SUITES'
import re, sys
src = open("swift/Sources/Dictor/SelfTests.swift", encoding="utf-8").read()
excluded = {"all", "clipboard-paste-live", "corrections-cost", "insertion-target-live"}
body = re.search(r"private static func testAll\(\).*?\n    \}", src, re.S)
if not body:
    sys.exit("check.sh: не нашёл testAll в SelfTests.swift")
missing = [
    (suite, fn)
    for suite, fn in re.findall(r'runSuite\("([a-z-]+)",\s*(test\w+)\)', src)
    if suite not in excluded and f"try {fn}()" not in body.group(0)
]
if missing:
    for suite, fn in missing:
        print(f"Сьют {suite} ({fn}) не достижим из --self-test all", file=sys.stderr)
    sys.exit(1)
SUITES

# Документация, разъехавшаяся с кодом. Так испортился CONTRIBUTING.md: он звал
# таргет и файл, которых в проекте давно нет, и заметить это можно было, только
# выполнив его команды.
python3 - <<'DOCS'
import pathlib, re, sys
problems = []
sources = "\n".join(p.read_text(encoding="utf-8") for p in pathlib.Path("swift/Sources/Dictor").glob("*.swift"))
readmes = {name: pathlib.Path(name).read_text(encoding="utf-8") for name in ("README.md", "README.ru.md")}

for flag in sorted(set(re.findall(r'"(--export-[a-z-]+)"', sources))):
    for name, text in readmes.items():
        if flag not in text:
            problems.append(f"{name}: не описан ключ {flag}")

for doc in sorted(set(re.findall(r"\b([A-Z][A-Z_]+\.md)\b", sources))):
    if not pathlib.Path(doc).exists():
        problems.append(f"исходники ссылаются на {doc}, которого нет")

for name in ("README.md", "README.ru.md", "CONTRIBUTING.md", "AGENTS.md", "SECURITY.md"):
    text = pathlib.Path(name).read_text(encoding="utf-8")
    for script in set(re.findall(r"(scripts/[a-z-]+\.sh)", text)):
        if not pathlib.Path(script).exists():
            problems.append(f"{name}: ссылается на {script}, которого нет")

if problems:
    print("\n".join(problems), file=sys.stderr)
    sys.exit(1)
DOCS

# Страница канала. Ломается она тихо: битая ссылка на картинку видна только
# на выложенном сайте, а незаполненная подстановка — только человеку, который
# пришёл скачивать.
python3 - <<'PY'
import pathlib, re, sys

root = pathlib.Path("web")
pages = [root / "index.html", root / "en" / "index.html"]
install_pages = [root / "install" / "index.html",
                 root / "en" / "install" / "index.html"]
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

for page in install_pages:
    if not page.exists():
        problems.append(f"{page}: страницы установки нет")
        continue
    text = page.read_text(encoding="utf-8")
    if "{{VERSION}}" not in text:
        problems.append(f"{page}: нет подстановки версии")
    # Ради этой страницы всё и затевалось: если ссылка на образ потерялась,
    # загрузка не начнётся и человек останется с инструкцией без файла.
    if "Dictor-{{VERSION}}.dmg" not in text:
        problems.append(f"{page}: нет ссылки на образ — загрузка не начнётся")

if problems:
    print("Channel page checks failed:", file=sys.stderr)
    for problem in problems:
        print("  " + problem, file=sys.stderr)
    sys.exit(1)
PY

git diff --check
printf 'Dictor checks passed (v%s).\n' "$app_version"
