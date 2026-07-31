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
#

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_HOST="${DICTOR_RELEASE_HOST:-my-server}"
REMOTE_DIR="${DICTOR_RELEASE_DIR:-/srv/dictor}"
CHANNEL_URL="${DICTOR_CHANNEL_URL:-https://dictor.raulgumerov.com}"
# Репозиторий проекта. Пока он не создан, `origin` смотрит на апстрим, из
# которого Dictor вырос, — туда тег отправлять нельзя. Скрипт советует push
# только когда `origin` действительно наш; задайте DICTOR_ORIGIN_MATCH, когда
# приватный репозиторий появится.
ORIGIN_MATCH="${DICTOR_ORIGIN_MATCH:-abra9987/Dictor}"
DRY_RUN=0
NOTES=""

say() { printf 'Dictor: %s\n' "$*"; }
fail() { printf 'Dictor: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
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
if (( ! DRY_RUN )); then
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
say "Архив: $(basename "$ZIP"), ${SIZE_MB} МБ, sha256 ${SHA256:0:16}…"

# --- Манифест и страница ---------------------------------------------------

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/dictor-release.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

python3 - "$STAGE/update.json" "$VERSION" "$SHA256" "$NOTES" <<'PY'
import json, sys
path, version, sha256, notes = sys.argv[1:5]
with open(path, "w", encoding="utf-8") as handle:
    json.dump({"version": version, "sha256": sha256, "notes": notes},
              handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY

cat > "$STAGE/index.html" <<HTML
<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Dictor $VERSION</title>
<style>
  body { font: 16px/1.6 -apple-system, BlinkMacSystemFont, sans-serif;
         max-width: 34rem; margin: 4rem auto; padding: 0 1.25rem;
         background: #F5F4F1; color: #1C1B19; }
  h1 { font-size: 2rem; margin: 0 0 .25rem; }
  .v { color: #6E6B66; margin: 0 0 2rem; }
  a.dl { display: inline-block; background: #1C1B19; color: #F5F4F1;
         text-decoration: none; padding: .7rem 1.4rem; border-radius: .5rem;
         font-weight: 600; }
  p.small { color: #6E6B66; font-size: .875rem; }
  code { background: #EAE7E1; padding: .1rem .35rem; border-radius: .25rem; }
  @media (prefers-color-scheme: dark) {
    body { background: #1E1D1B; color: #F2F1EE; }
    .v, p.small { color: #A3A09A; }
    a.dl { background: #F2F1EE; color: #1C1B19; }
    code { background: #2B2A27; }
  }
</style>
<h1>Dictor</h1>
<p class="v">Версия $VERSION · локальная диктовка для macOS</p>
<p><a class="dl" href="Dictor-$VERSION.dmg">Скачать Dictor-$VERSION.dmg</a></p>
<p class="small">Apple Silicon, macOS 14 или новее. При первом запуске macOS
предупредит о неизвестном разработчике: Системные настройки →
«Конфиденциальность и безопасность» → «Открыть всё равно».</p>
<p class="small">Установленное приложение обновляется само и спрашивает
разрешения перед установкой.</p>
<p class="small">sha256 архива: <code>$SHA256</code></p>
HTML

if (( DRY_RUN )); then
    say "Сухой прогон. Готово локально:"
    say "  $ZIP"
    say "  $ROOT_DIR/dist/Dictor-$VERSION.dmg"
    say "  манифест: $STAGE/update.json"
    cat "$STAGE/update.json"
    trap - EXIT
    rm -rf "$STAGE"
    exit 0
fi

# --- Выкладка --------------------------------------------------------------

say "Выкладываем на ${SSH_HOST}:${REMOTE_DIR}…"
ssh "$SSH_HOST" "mkdir -p '$REMOTE_DIR'" \
    || fail "Нет доступа к $SSH_HOST. Проверьте сеть и SSH-доступ."

# Порядок важен: сначала файлы, манифест последним. Иначе приложение успеет
# увидеть новую версию и уйти качать архив, которого ещё нет.
scp -q "$ZIP" "$ROOT_DIR/dist/Dictor-$VERSION.dmg" "$SSH_HOST:$REMOTE_DIR/"
scp -q "$STAGE/index.html" "$SSH_HOST:$REMOTE_DIR/"
scp -q "$STAGE/update.json" "$SSH_HOST:$REMOTE_DIR/"
ssh "$SSH_HOST" "chmod 644 '$REMOTE_DIR'/*"

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
