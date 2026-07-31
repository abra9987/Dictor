#!/bin/bash
#
# Собирает установочный образ Dictor-<версия>.dmg: приложение, ярлык
# «Программы» и оформленное окно Finder с подсказкой про первый запуск.
#
# Использование:
#   ./scripts/make-dmg.sh                 # собрать приложение и образ
#   ./scripts/make-dmg.sh --no-build      # взять готовый dist/Dictor.app
#   ./scripts/make-dmg.sh path/to/out.dmg
#

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT_DIR/dist/Dictor.app"
VOL_NAME="Dictor"
DO_BUILD=1
OUTPUT_DMG=""

say() {
    printf 'Dictor: %s\n' "$*"
}

fail() {
    printf 'Dictor: %s\n' "$*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-build) DO_BUILD=0 ;;
        -h|--help)
            sed -n '2,10p' "$0" | sed 's|^# \{0,1\}||'
            exit 0
            ;;
        -*) fail "Неизвестный ключ: $1" ;;
        *)
            [[ -z "$OUTPUT_DMG" ]] || fail "Путь к образу указан дважды."
            OUTPUT_DMG="$1"
            ;;
    esac
    shift
done

[[ "$(/usr/bin/uname -s)" == "Darwin" ]] || fail "Нужна macOS."
command -v swift >/dev/null 2>&1 || fail "Swift не найден. Запусти: xcode-select --install"
command -v hdiutil >/dev/null 2>&1 || fail "hdiutil не найден."

if (( DO_BUILD )); then
    say "Собираем приложение..."
    "$ROOT_DIR/scripts/build-app.sh" "$APP"
fi
[[ -d "$APP" ]] || fail "Нет $APP. Запусти без --no-build."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$APP/Contents/Info.plist" 2>/dev/null || true)"
[[ -n "$VERSION" ]] || fail "В Info.plist нет CFBundleShortVersionString."

if [[ -z "$OUTPUT_DMG" ]]; then
    OUTPUT_DMG="$ROOT_DIR/dist/Dictor-$VERSION.dmg"
fi
[[ "$OUTPUT_DMG" == *.dmg ]] || fail "Имя образа должно оканчиваться на .dmg."

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dictor-dmg.XXXXXX")"
STAGE="$WORK_DIR/stage"
RW_DMG="$WORK_DIR/rw.dmg"
MOUNT_POINT=""
DEV_ENTRY=""

cleanup() {
    if [[ -n "$DEV_ENTRY" ]]; then
        hdiutil detach "$DEV_ENTRY" -force >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# --- Раскладка образа -------------------------------------------------------

say "Готовим содержимое образа..."
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/Dictor.app"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT_DIR/icon/Dictor.icns" "$STAGE/.VolumeIcon.icns"

swift "$ROOT_DIR/scripts/dmg-art.swift" background \
    "$WORK_DIR/background.png" "$WORK_DIR/background@2x.png"
# Одна картинка с обычным и retina-представлением: Finder сам выберет нужное.
tiffutil -cathidpicheck "$WORK_DIR/background.png" "$WORK_DIR/background@2x.png" \
    -out "$STAGE/.background/background.tiff" >/dev/null

# --- Записываемый образ -----------------------------------------------------

SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 40 ))
say "Создаём временный образ (${SIZE_MB} МБ)..."
hdiutil create -srcfolder "$STAGE" -volname "$VOL_NAME" -fs HFS+ \
    -format UDRW -size "${SIZE_MB}m" -ov "$RW_DMG" >/dev/null

ATTACH_PLIST="$WORK_DIR/attach.plist"
hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen -plist > "$ATTACH_PLIST"

DEV_ENTRY="$(/usr/libexec/PlistBuddy -c 'Print :system-entities:0:dev-entry' "$ATTACH_PLIST")"
for index in 0 1 2 3 4 5; do
    candidate="$(/usr/libexec/PlistBuddy -c "Print :system-entities:$index:mount-point" \
        "$ATTACH_PLIST" 2>/dev/null || true)"
    if [[ -n "$candidate" ]]; then
        MOUNT_POINT="$candidate"
        break
    fi
done
[[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]] || fail "Не удалось смонтировать временный образ."
MOUNTED_NAME="$(basename "$MOUNT_POINT")"

# --- Оформление окна --------------------------------------------------------

say "Расставляем окно Finder..."
if ! osascript - "$MOUNTED_NAME" <<'APPLESCRIPT'
on run argv
    set volumeName to item 1 of argv
    tell application "Finder"
        tell disk volumeName
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            -- Высота bounds включает заголовок окна (28 пунктов), поэтому под
            -- фон 660×520 окно должно быть на эту полосу выше.
            set the bounds of container window to {180, 120, 840, 668}

            set options to the icon view options of container window
            set arrangement of options to not arranged
            set icon size of options to 128
            set text size of options to 13
            set label position of options to bottom
            set background picture of options to file ".background:background.tiff"

            set position of item "Dictor.app" of container window to {170, 234}
            set position of item "Applications" of container window to {490, 234}
            -- Скрытую папку .background не двигаем: иконка шириной 128 не влезает
            -- в нижнюю полосу, а координата левее 64 заставляет Finder сдвинуть
            -- начало холста и утащить за собой обе видимые иконки.

            close
            open
            update without registering applications
            delay 2
        end tell
    end tell
end run
APPLESCRIPT
then
    fail "Finder не дал оформить окно. Разреши Терминалу управлять Finder в
Системных настройках → Конфиденциальность и безопасность → Автоматизация,
затем запусти скрипт снова."
fi

# Свой значок тома: бит kHasCustomIcon в FinderInfo корня образа.
xattr -wx com.apple.FinderInfo \
    "0000000000000000040000000000000000000000000000000000000000000000" \
    "$MOUNT_POINT"

# Журнал файловых событий в готовом образе не нужен: он только мозолит глаза
# тем, у кого показаны скрытые файлы. В read-only образе он уже не вернётся.
rm -rf "$MOUNT_POINT/.fseventsd" >/dev/null 2>&1 || true

chmod -Rf go-w "$MOUNT_POINT" >/dev/null 2>&1 || true
sync

say "Отмонтируем..."
detached=0
for attempt in 1 2 3 4 5; do
    if hdiutil detach "$DEV_ENTRY" >/dev/null 2>&1; then
        detached=1
        break
    fi
    sleep 2
done
if (( ! detached )); then
    hdiutil detach "$DEV_ENTRY" -force >/dev/null 2>&1 || fail "Не удалось отмонтировать образ."
fi
DEV_ENTRY=""

# --- Финальный сжатый образ -------------------------------------------------

say "Сжимаем образ..."
mkdir -p "$(dirname "$OUTPUT_DMG")"
rm -f "$OUTPUT_DMG"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUTPUT_DMG" >/dev/null

# Иконка приложения на самом файле образа.
swift "$ROOT_DIR/scripts/dmg-art.swift" icon "$ROOT_DIR/icon/Dictor.icns" "$OUTPUT_DMG" \
    || say "Не удалось назначить иконку файлу образа — не критично."

say "Готово: $OUTPUT_DMG ($(du -h "$OUTPUT_DMG" | cut -f1))"
