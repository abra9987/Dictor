#!/bin/bash
#
# Сколько раз скачали и сколько раз открыли страницу.
#
# Считается по журналу доступа веб-сервера — приложение для этого ничего не
# отправляет и отправлять не должно. Адреса нужны только чтобы отличить
# «десять скачиваний одним человеком» от «десятью»; в сохранённую историю
# уходят одни числа.
#
# Использование:
#   ./scripts/channel-stats.sh             # отчёт по живому журналу
#   ./scripts/channel-stats.sh --history   # накопленная история по дням
#   ./scripts/channel-stats.sh --json      # то же машинным видом

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_ENV="$ROOT_DIR/scripts/release.env"
# shellcheck source=/dev/null
[[ -f "$RELEASE_ENV" ]] && source "$RELEASE_ENV"

SSH_HOST="${DICTOR_RELEASE_HOST:-}"
CONTAINER="${DICTOR_CHANNEL_CONTAINER:-dictor-updates}"
STATS_DIR="${DICTOR_STATS_DIR:-/opt/dictor-stats}"

[[ -n "$SSH_HOST" ]] || {
    printf 'Dictor: не задан DICTOR_RELEASE_HOST — смотрите scripts/release.env.example\n' >&2
    exit 1
}

if [[ "${1:-}" == "--history" ]]; then
    # История переживает перезапуск контейнера и ротацию журнала: её раз в
    # час дописывает агрегатор на сервере.
    ssh "$SSH_HOST" "cat '$STATS_DIR/history.json' 2>/dev/null" \
        | python3 "$ROOT_DIR/scripts/channel-stats.py" --history-json
    exit 0
fi

ssh "$SSH_HOST" "docker logs '$CONTAINER' 2>/dev/null" \
    | python3 "$ROOT_DIR/scripts/channel-stats.py" "$@"
