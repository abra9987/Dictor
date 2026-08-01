#!/bin/bash
#
# Выпуск версии: сборка, образ, архив для автообновления, манифест и
# выкладка на канал обновлений.
#
# Версия берётся из swift/Info.plist — это единственный источник правды.
# Git-тег ставится из неё же, поэтому разъехаться они не могут.
#
# Использование:
#   ./scripts/make-release.sh              # собрать, выложить, поставить тег
#   ./scripts/make-release.sh --dry-run    # собрать и остановиться
#   ./scripts/make-release.sh --notes "Что нового"
#   ./scripts/make-release.sh --site-only  # обновить только страницу канала
#

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Куда выкладывать — в scripts/release.env, которого нет в репозитории:
# адрес сервера и путь на нём это карта для того, кто захочет подменить
# обновление, и в открытом репозитории им делать нечего. Пример — в
# scripts/release.env.example.
RELEASE_ENV="$ROOT_DIR/scripts/release.env"
# shellcheck source=/dev/null
[[ -f "$RELEASE_ENV" ]] && source "$RELEASE_ENV"

SSH_HOST="${DICTOR_RELEASE_HOST:-}"
REMOTE_DIR="${DICTOR_RELEASE_DIR:-}"
CHANNEL_URL="${DICTOR_CHANNEL_URL:-https://dictor.raulgumerov.com}"
# Репозиторий проекта. Пока он не создан, `origin` смотрит на апстрим, из
# которого Dictor вырос, — туда тег отправлять нельзя. Скрипт советует push
# только когда `origin` действительно наш; задайте DICTOR_ORIGIN_MATCH, когда
# приватный репозиторий появится.
ORIGIN_MATCH="${DICTOR_ORIGIN_MATCH:-abra9987/Dictor}"
DRY_RUN=0
SITE_ONLY=0
NOTES=""

say() { printf 'Dictor: %s\n' "$*"; }
fail() { printf 'Dictor: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --site-only) SITE_ONLY=1 ;;
        --notes) shift; NOTES="${1:-}" ;;
        -h|--help) sed -n '2,13p' "$0" | sed 's|^# \{0,1\}||'; exit 0 ;;
        *) fail "Неизвестный ключ: $1" ;;
    esac
    shift
done

cd "$ROOT_DIR"

# --- Проверки перед сборкой ------------------------------------------------

command -v ditto >/dev/null 2>&1 || fail "ditto не найден."
command -v shasum >/dev/null 2>&1 || fail "shasum не найден."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    swift/Info.plist 2>/dev/null || true)"
[[ -n "$VERSION" ]] || fail "В swift/Info.plist нет CFBundleShortVersionString."
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "Версия «$VERSION» не вида X.Y.Z — апдейтер такую не примет."

TAG="v$VERSION"
# Чистота дерева и свободный тег защищают публикацию, а не сборку: сухой
# прогон ничего не выкладывает и не тегает, поэтому его можно запускать
# посреди работы — иначе скрипт нельзя было бы проверить, не закоммитив.
if (( ! DRY_RUN && ! SITE_ONLY )); then
    if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
        fail "Тег $TAG уже существует. Подними версию в swift/Info.plist."
    fi
    if [[ -n "$(git status --porcelain)" ]]; then
        fail "В рабочем дереве есть незакоммиченные изменения. Релиз собирается только из чистого дерева."
    fi
fi

say "Проверки репозитория…"
./scripts/check.sh >/dev/null

# --- Сборка ----------------------------------------------------------------

# Страницу канала правят чаще, чем выходят версии. Перевыпускать ради текста
# архив, образ и тег незачем — и вредно: у людей поменялась бы контрольная
# сумма уже выложенной версии. В этом режиме версия и sha берутся с канала,
# то есть описывают ровно те файлы, что там лежат.
if (( SITE_ONLY )); then
    say "Только страница: читаем канал…"
    CHANNEL_JSON="$(curl -fsS --max-time 20 "$CHANNEL_URL/update.json")" \
        || fail "Канал $CHANNEL_URL не отвечает."
    VERSION="$(printf '%s' "$CHANNEL_JSON" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')"
    SHA256="$(printf '%s' "$CHANNEL_JSON" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha256"])')"
    PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        swift/Info.plist)"
    [[ "$VERSION" == "$PLIST_VERSION" ]] || say \
        "На канале $VERSION, в Info.plist $PLIST_VERSION — страница опишет выложенную."
    DMG_BYTES="$(curl -fsSI --max-time 20 "$CHANNEL_URL/Dictor-$VERSION.dmg" \
        | awk 'tolower($1) == "content-length:" { gsub(/\r/, "", $2); print $2 }' | tail -1)"
    [[ -n "$DMG_BYTES" ]] || fail "Не удалось узнать размер Dictor-$VERSION.dmg на канале."
else

say "Собираем ${TAG}…"
./scripts/build-app.sh "$ROOT_DIR/dist/Dictor.app"
./scripts/make-dmg.sh --no-build "$ROOT_DIR/dist/Dictor-$VERSION.dmg"

# Архив для автообновления. Образ для этого не годится: апдейтеру пришлось
# бы монтировать том, а `ditto -c -k --keepParent` даёт ровно тот бандл,
# который потом проверяется по подписи и подменяется на месте.
ZIP="$ROOT_DIR/dist/Dictor-$VERSION.zip"
rm -f "$ZIP"
say "Пакуем архив…"
ditto -c -k --keepParent "$ROOT_DIR/dist/Dictor.app" "$ZIP"

# Проверяем то, что реально уедет людям, а не то, что лежит в dist.
VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dictor-release-verify.XXXXXX")"
trap 'rm -rf "$VERIFY_DIR"' EXIT
ditto -x -k "$ZIP" "$VERIFY_DIR"
codesign --verify --deep --strict \
    -R "=identifier \"com.raul.dictor\" and certificate leaf = H\"$(sed -n 's/^let UPDATE_SIGNING_CERT_SHA1 = "\([0-9A-F]*\)"$/\1/p' swift/Sources/Dictor/CoreTypes.swift)\"" \
    "$VERIFY_DIR/Dictor.app" \
    || fail "Архив не удовлетворяет требованию подписи — обновление такую сборку отвергнет."
PACKED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$VERIFY_DIR/Dictor.app/Contents/Info.plist")"
[[ "$PACKED_VERSION" == "$VERSION" ]] \
    || fail "В архиве версия $PACKED_VERSION, ожидалась $VERSION."
rm -rf "$VERIFY_DIR"
trap - EXIT

SHA256="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
SIZE_MB="$(du -m "$ZIP" | cut -f1)"
DMG_BYTES="$(stat -f%z "$ROOT_DIR/dist/Dictor-$VERSION.dmg")"
say "Архив: $(basename "$ZIP"), ${SIZE_MB} МБ, sha256 ${SHA256:0:16}…"
fi

# --- Манифест и страница ---------------------------------------------------

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/dictor-release.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

if (( ! SITE_ONLY )); then
python3 - "$STAGE/update.json" "$VERSION" "$SHA256" "$NOTES" <<'PY'
import json, sys
path, version, sha256, notes = sys.argv[1:5]
with open(path, "w", encoding="utf-8") as handle:
    json.dump({"version": version, "sha256": sha256, "notes": notes},
              handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY
fi

# Страница живёт в web/ и правится отдельно от выпуска. Здесь только
# подстановка того, что известно лишь в момент релиза: версия, размер образа
# и контрольная сумма архива.
[[ -d "$ROOT_DIR/web" ]] || fail "Нет каталога web/ — выкладывать нечего."
cp -R "$ROOT_DIR/web/." "$STAGE/"

SITE_DATE="$(date -u +%Y-%m-%d)"
python3 - "$STAGE" "$VERSION" "$SHA256" "$DMG_BYTES" "$SITE_DATE" <<'PY'
import pathlib, sys
stage, version, sha256, dmg_bytes, site_date = sys.argv[1:6]
# Размер образа — с десятыми и в правописании языка: «4,5 МБ» и «4.5 MB».
# Целые мегабайты врали на полмегабайта в обе стороны.
megabytes = f"{int(dmg_bytes) / 1024 / 1024:.1f}"
sizes = {"index.html": f"{megabytes.replace('.', ',')} МБ",
         "en/index.html": f"{megabytes} MB"}
# Страницы установки показывают и версию, и размер образа.
sizes["install/index.html"] = sizes["index.html"]
sizes["en/install/index.html"] = sizes["en/index.html"]
sizes["sitemap.xml"] = ""  # размера образа в карте сайта нет, дата — есть

for name, size in sizes.items():
    path = pathlib.Path(stage) / name
    if not path.exists():
        raise SystemExit(f"страница {name} не найдена в web/")
    text = path.read_text(encoding="utf-8")
    for token, value in (("{{VERSION}}", version), ("{{SHA256}}", sha256),
                         ("{{DMG_SIZE}}", size), ("{{DATE}}", site_date)):
        text = text.replace(token, value)
    if "{{" in text:
        raise SystemExit(f"в {name} остались незаполненные подстановки")
    path.write_text(text, encoding="utf-8")
PY

if (( DRY_RUN )); then
    # Собранный сайт остаётся на диске: страницу нужно открыть и посмотреть
    # до того, как она уедет на канал, а во временном каталоге её не найти.
    rm -rf "$ROOT_DIR/dist/site"
    mkdir -p "$ROOT_DIR/dist/site"
    cp -R "$STAGE/." "$ROOT_DIR/dist/site/"
    say "Сухой прогон. Готово локально:"
    say "  сайт: $ROOT_DIR/dist/site/index.html"
    if (( ! SITE_ONLY )); then
        say "  $ZIP"
        say "  $ROOT_DIR/dist/Dictor-$VERSION.dmg"
        say "  манифест: $STAGE/update.json"
        cat "$STAGE/update.json"
    fi
    trap - EXIT
    rm -rf "$STAGE"
    exit 0
fi

# --- Выкладка --------------------------------------------------------------

[[ -n "$SSH_HOST" && -n "$REMOTE_DIR" ]] || fail \
    "Не задано, куда выкладывать. Создайте scripts/release.env по образцу scripts/release.env.example."

say "Выкладываем на ${SSH_HOST}:${REMOTE_DIR}…"
ssh "$SSH_HOST" "mkdir -p '$REMOTE_DIR'" \
    || fail "Нет доступа к $SSH_HOST. Проверьте сеть и SSH-доступ."

# Порядок важен: сначала файлы, манифест последним. Иначе приложение успеет
# увидеть новую версию и уйти качать архив, которого ещё нет.
if (( ! SITE_ONLY )); then
    scp -q "$ZIP" "$ROOT_DIR/dist/Dictor-$VERSION.dmg" "$SSH_HOST:$REMOTE_DIR/"
fi
# favicon.ico — отдельной строкой: браузер просит его сам, из корня сайта,
# и в разметке его может не быть вовсе.
scp -qr "$STAGE/index.html" "$STAGE/favicon.ico" "$STAGE/robots.txt" \
    "$STAGE/sitemap.xml" "$STAGE/install" "$STAGE/en" "$STAGE/assets" \
    "$SSH_HOST:$REMOTE_DIR/"
if (( ! SITE_ONLY )); then
    scp -q "$STAGE/update.json" "$SSH_HOST:$REMOTE_DIR/"
fi
# Каталоги должны остаться проходимыми, файлы — читаемыми.
ssh "$SSH_HOST" "find '$REMOTE_DIR' -type d -exec chmod 755 {} + && \
                 find '$REMOTE_DIR' -type f -exec chmod 644 {} +"

if (( SITE_ONLY )); then
    say "Проверяем страницу…"
    for page in "" "en/" "install/" "en/install/"; do
        curl -fsS --max-time 20 "$CHANNEL_URL/$page" >/dev/null \
            || fail "Страница $CHANNEL_URL/$page не открывается."
    done
    # Ссылка на образ — то единственное, ради чего человек сюда пришёл.
    curl -fsSI --max-time 20 "$CHANNEL_URL/Dictor-$VERSION.dmg" >/dev/null \
        || fail "Кнопка скачивания ведёт в никуда: Dictor-$VERSION.dmg не отдаётся."
    for extra in robots.txt sitemap.xml favicon.ico; do
        curl -fsS --max-time 20 "$CHANNEL_URL/$extra" >/dev/null \
            || fail "$extra не отдаётся."
    done
    say "Готово: страница обновлена на $CHANNEL_URL"
    exit 0
fi

say "Проверяем канал…"
REMOTE_VERSION="$(curl -fsS --max-time 20 "$CHANNEL_URL/update.json" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')"
[[ "$REMOTE_VERSION" == "$VERSION" ]] \
    || fail "Канал отдаёт версию $REMOTE_VERSION вместо $VERSION."
REMOTE_SHA="$(curl -fsS --max-time 120 "$CHANNEL_URL/Dictor-$VERSION.zip" | shasum -a 256 | awk '{print $1}')"
[[ "$REMOTE_SHA" == "$SHA256" ]] \
    || fail "Скачанный с канала архив не совпал с локальным по sha256."

git tag -a "$TAG" -m "Dictor $VERSION"
say "Готово: $TAG выложен на $CHANNEL_URL"

# Раздача от git-репозитория не зависит: канал обновлений уже получил всё,
# что нужно людям. Тег — только метка для истории, и отправлять его есть
# смысл лишь в свой репозиторий.
ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
if [[ -n "$ORIGIN_URL" && "$ORIGIN_URL" == *"$ORIGIN_MATCH"* ]]; then
    say "Тег создан локально. Отправить: git push origin $TAG"
else
    say "Тег $TAG создан локально и никуда не отправлен."
    say "  origin = ${ORIGIN_URL:-не задан} — это не репозиторий проекта."
    say "  Не делайте push: тег уедет в чужой репозиторий."
    say "  Когда появится свой, задайте DICTOR_ORIGIN_MATCH или смените origin."
fi
