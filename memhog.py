#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ============================================================================
# memhog.py — Сценарий 2, метод C (грубый): занимает оперативную память
# стенда, оставляя заданный запас свободной, и удерживает её. Применяется,
# если методы A (prlimit) и B (cgroup MemoryMax) недоступны.
#
# ВНИМАНИЕ: запускать только на выделенном тестовом стенде! Скрипт доводит
# систему до состояния нехватки памяти — ядро может прибить любой процесс
# (OOM killer), включая сам memhog.
#
# Запуск:    sudo python3 memhog.py --leave-free 60
#            (оставить свободными ~60 МиБ; подбирайте 20-100 МиБ)
# Остановка: Ctrl+C — вся память освобождается.
# ============================================================================
import argparse
import time


def mem_available_kb():
    """Свободная память по данным ядра (MemAvailable, КиБ)."""
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemAvailable"):
                    return int(line.split()[1])
    except OSError:
        pass
    return 0


def main():
    ap = argparse.ArgumentParser(description="Занимает RAM стенда до заданного остатка")
    ap.add_argument("--leave-free", type=int, default=60,
                    help="сколько МиБ оставить свободными (по умолчанию 60)")
    ap.add_argument("--chunk", type=int, default=32,
                    help="размер куска, МиБ (по умолчанию 32)")
    ap.add_argument("--step-sleep", type=float, default=0.3,
                    help="пауза между кусками, секунд")
    a = ap.parse_args()

    target_kb = a.leave_free * 1024
    chunks = []
    print("Цель: держать MemAvailable на уровне <= %d МиБ." % a.leave_free)
    print("Кусками по %d МиБ. Остановка — Ctrl+C (память освободится).\n" % a.chunk)

    try:
        while True:
            avail = mem_available_kb()
            if avail <= target_kb:
                print("[удержание] MemAvailable=%d МиБ (цель <= %d МиБ). "
                      "Нажмите Ctrl+C, чтобы освободить память."
                      % (avail // 1024, a.leave_free), flush=True)
                time.sleep(2)
                continue
            block = bytearray(a.chunk * 1024 * 1024)
            # трогаем каждую страницу (4096 байт), чтобы память реально выделилась
            for i in range(0, len(block), 4096):
                block[i] = 1
            chunks.append(block)
            print("занято ещё %d МиБ, всего %d МиБ, свободно %d МиБ"
                  % (a.chunk, len(chunks) * a.chunk, avail // 1024), flush=True)
            time.sleep(a.step_sleep)
    except KeyboardInterrupt:
        n = len(chunks)
        chunks.clear()
        print("\nОсвобождаем память (%d кусков)... Стенд возвращён в исходное состояние." % n)


if __name__ == "__main__":
    main()
