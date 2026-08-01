#!/usr/bin/env python3
"""Отчёт по каналу раздачи: скачивания и заходы на страницу.

Считает по журналу доступа nginx — тому самому, что ведёт любой веб-сервер.
Приложение для этого ничего не отправляет: в нём нет ни аналитики, ни
идентификаторов, и появиться они здесь не должны.

Считаются две вещи: сколько раз скачали программу и сколько раз открыли
страницу. Запросы приложения к манифесту обновлений НЕ считаются — по ним
видно, сколько установок живо и когда ими пользуются, а это наблюдение за
людьми, а не за раздачей.

Адреса используются только для подсчёта «сколько разных» и никуда не
записываются: в сводку уходят одни числа.

    ./scripts/channel-stats.sh              # живой журнал сервера
    ./scripts/channel-stats.sh --history    # накопленная история по дням
"""

import collections
import json
import re
import sys

LINE = re.compile(
    r'^(?P<proxy>\S+) - - \[(?P<time>[^\]]+)\] "(?P<method>\S+) (?P<path>\S+) [^"]*" '
    r'(?P<status>\d+) (?P<bytes>\d+) "(?P<ref>[^"]*)" "(?P<ua>[^"]*)" "(?P<ip>[^"]*)"'
)

# Сканеры и роботы: их запросы к скачиванию не относятся, но и выбрасывать их
# молча нельзя — иначе не заметишь, что сайт обходит только Googlebot.
BOT_MARKERS = ("bot", "crawler", "spider", "curl", "wget", "python-requests",
               "scan", "l9scan", "headless")

PAGES = {"/": "русская", "/index.html": "русская",
         "/en/": "английская", "/en/index.html": "английская"}


def is_bot(user_agent: str) -> bool:
    lowered = user_agent.lower()
    return any(marker in lowered for marker in BOT_MARKERS)


def parse(stream):
    for line in stream:
        match = LINE.match(line.strip())
        if match:
            yield match.groupdict()


def day_of(entry) -> str:
    # 01/Aug/2026:18:24:19 +0000 → 2026-08-01
    day, month, rest = entry["time"].split("/", 2)
    year = rest[:4]
    months = {"Jan": "01", "Feb": "02", "Mar": "03", "Apr": "04", "May": "05",
              "Jun": "06", "Jul": "07", "Aug": "08", "Sep": "09", "Oct": "10",
              "Nov": "11", "Dec": "12"}
    return f"{year}-{months.get(month, '01')}-{day}"


def summarize(entries):
    """Суточные сводки. Уникальные адреса считаются здесь и здесь же
    забываются — наружу уходят только счётчики."""
    per_day = collections.defaultdict(lambda: {
        "downloads": collections.Counter(),
        "download_uniques": collections.defaultdict(set),
        "pages": collections.Counter(),
        "page_uniques": collections.defaultdict(set),
        "bots": collections.Counter(),
    })

    for entry in entries:
        bucket = per_day[day_of(entry)]
        path = entry["path"].split("?")[0]
        bot = is_bot(entry["ua"])

        if bot:
            bucket["bots"][entry["ua"][:60]] += 1

        if entry["status"] in ("200", "206") and path.endswith((".dmg", ".zip")):
            name = path.lstrip("/")
            bucket["downloads"][name] += 1
            bucket["download_uniques"][name].add(entry["ip"])
        elif path in PAGES and not bot:
            bucket["pages"][PAGES[path]] += 1
            bucket["page_uniques"][PAGES[path]].add(entry["ip"])

    result = {}
    for day, bucket in sorted(per_day.items()):
        result[day] = {
            "downloads": {
                name: {"requests": count,
                       "uniques": len(bucket["download_uniques"][name])}
                for name, count in sorted(bucket["downloads"].items())
            },
            "pages": {
                name: {"views": count, "uniques": len(bucket["page_uniques"][name])}
                for name, count in sorted(bucket["pages"].items())
            },
            "bots": dict(bucket["bots"].most_common(5)),
        }
    return result


def print_report(summary):
    if not summary:
        print("Журнал пуст — сервер ещё ничего не отдавал.")
        return

    days = sorted(summary)
    print(f"Канал раздачи · {days[0]} → {days[-1]} ({len(days)} дн.)\n")

    total_dmg = collections.Counter()
    total_zip = collections.Counter()
    for day in days:
        for name, stats in summary[day]["downloads"].items():
            (total_dmg if name.endswith(".dmg") else total_zip)[name] += stats["requests"]

    print("УСТАНОВКИ (образ .dmg)")
    if total_dmg:
        for name, count in total_dmg.most_common():
            print(f"  {name:22} {count:4}")
        print(f"  {'всего':22} {sum(total_dmg.values()):4}")
    else:
        print("  пока ни одной")

    print("\nОБНОВЛЕНИЯ (архив .zip)")
    if total_zip:
        for name, count in total_zip.most_common():
            print(f"  {name:22} {count:4}")
    else:
        print("  пока ни одного")

    print("\nПО ДНЯМ")
    for day in days:
        entry = summary[day]
        installs = sum(stats["requests"] for name, stats in entry["downloads"].items()
                       if name.endswith(".dmg"))
        views = sum(stats["views"] for stats in entry["pages"].values())
        uniques = sum(stats["uniques"] for stats in entry["pages"].values())
        print(f"  {day}  установок {installs:3} · страница {views:4} "
              f"({uniques} адресов)")

    last = summary[days[-1]]
    if last["bots"]:
        print("\nРОБОТЫ (последний день)")
        for agent, count in last["bots"].items():
            print(f"  {count:4} · {agent}")


def merge(old: dict, new: dict) -> dict:
    """Слияние старой истории с новым срезом журнала. Счётчики за день берём
    по максимуму: журнал в контейнере ротируется, и после ротации свежий
    срез за тот же день будет меньше — прошлое затирать им нельзя."""
    result = dict(old)
    for day, fresh in new.items():
        stored = result.get(day)
        if stored is None:
            result[day] = fresh
            continue
        for section in ("downloads", "pages"):
            merged = dict(stored.get(section, {}))
            for name, stats in fresh.get(section, {}).items():
                before = merged.get(name, {})
                merged[name] = {
                    key: max(stats.get(key, 0), before.get(key, 0))
                    for key in set(stats) | set(before)
                }
            result[day][section] = merged
        result[day].pop("update_checks", None)
        result[day]["bots"] = fresh.get("bots", stored.get("bots", {}))
    return result


def main() -> int:
    if "--history-json" in sys.argv:
        raw = sys.stdin.read().strip()
        print_report(json.loads(raw) if raw else {})
        return 0
    if "--merge" in sys.argv:
        # Режим агрегатора на сервере: старая история первым аргументом,
        # свежий журнал на входе.
        path = sys.argv[sys.argv.index("--merge") + 1]
        try:
            with open(path, encoding="utf-8") as handle:
                old = json.load(handle)
        except (FileNotFoundError, json.JSONDecodeError):
            old = {}
        print(json.dumps(merge(old, summarize(parse(sys.stdin))),
                         ensure_ascii=False, indent=2))
        return 0
    if "--json" in sys.argv:
        print(json.dumps(summarize(parse(sys.stdin)), ensure_ascii=False, indent=2))
        return 0
    print_report(summarize(parse(sys.stdin)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
