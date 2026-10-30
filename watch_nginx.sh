#!/usr/bin/env bash
# ============================================================================
# watch_nginx.sh — наблюдение за процессами nginx в реальном времени.
# Каждые 2 секунды печатает PID мастера и воркеров, а при появлении в
# error.log строк о гибели воркера («exited on signal ...») — печатает их
# с пометкой [!]. Запускайте в ОТДЕЛЬНОМ окне терминала на всё время теста.
#
# Использование:  sudo bash watch_nginx.sh [путь_к_error.log]
# Остановка: Ctrl+C
# ============================================================================
set -u

LOG="${1:-/var/log/nginx/error.log}"

echo "Мониторинг запущен (остановка — Ctrl+C)."
echo "Источник лога: $LOG"
echo "Формат: [время] master: PID | workers: PID PID ..."

if [ ! -r "$LOG" ]; then
  echo "[!] Лог '$LOG' недоступен на чтение. Запустите скрипт через sudo."
  echo "    Слежение за логом отключено, показываются только процессы."
fi

# Фоновый поток: следит за новыми строками лога о гибели воркеров
if [ -r "$LOG" ]; then
  (
    tail -n 0 -F "$LOG" 2>/dev/null \
      | grep --line-buffered -E 'exited on signal|signal SIGSEGV|signal 11|core dump|alert' \
      | while IFS= read -r line; do
          echo "[$(date +%H:%M:%S)] [!] ЛОГ: $line"
        done
  ) &
  TAIL_PID=$!
  trap 'kill $TAIL_PID 2>/dev/null; exit 0' INT TERM
fi

# Основной цикл: состояние процессов + новые segfault в dmesg (если доступен)
last_segv=0
while true; do
  ts=$(date +%H:%M:%S)
  master=$(pgrep -f 'nginx: master process' | tr '\n' ' ')
  workers=$(pgrep -f 'nginx: worker process' | tr '\n' ' ')
  echo "[$ts] master: ${master:-НЕТ} | workers: ${workers:-НЕТ ВОРКЕРОВ!}"

  if dmesg -T 2>/dev/null | grep -i segfault >/dev/null 2>&1; then
    cur=$(dmesg -T 2>/dev/null | grep -ic segfault)
    if [ "$cur" -gt "$last_segv" ]; then
      dmesg -T 2>/dev/null | grep -i segfault | tail -1 | sed "s/^/[$ts] [!] DMESG: /"
      last_segv=$cur
    fi
  fi
  sleep 2
done
