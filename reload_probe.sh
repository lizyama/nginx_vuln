#!/usr/bin/env bash
# ============================================================================
# reload_probe.sh — Сценарий 1 «пустая статистика».
# Выполняет nginx -s reload (перезапуск воркеров БЕЗ остановки сервиса),
# затем делает ПЕРВЫЙ запрос к эндпоинту мониторинга и сверяет логи:
# если воркер упал по сигналу — скрипт печатает [!] ПАДЕНИЕ.
#
# Использование:  sudo bash reload_probe.sh <URL> [число_попыток]
# Пример:         sudo bash reload_probe.sh http://127.0.0.1:8080/status 8
#
# Тела ответов сохраняются в /tmp/probe_<номер>.bin для последующей сверки.
# ============================================================================
set -u

URL="${1:?Использование: reload_probe.sh <URL> [число_попыток]}"
N="${2:-5}"

# Путь к error.log: из параметров сборки nginx, иначе стандартный
LOG=$(nginx -V 2>&1 | grep -oE '\-\-error-log-path=[^ ]+' | head -1 | cut -d= -f2)
LOG="${LOG:-/var/log/nginx/error.log}"
echo "URL:            $URL"
echo "Число попыток:  $N"
echo "error.log:      $LOG"

crashes=0
for i in $(seq 1 "$N"); do
  echo "--------------------------------------------------------------"
  echo "Попытка $i из $N"

  before=$(pgrep -f 'nginx: worker process' | sort | tr '\n' ',')
  mark=$(wc -l < "$LOG" 2>/dev/null || echo 0)

  # 1) Мягкий перезапуск воркеров (конфигурация и мастер не меняются)
  nginx -s reload 2>/dev/null || { echo '[!] nginx -s reload не удался (нужен root?)'; exit 1; }
  sleep 1

  # 2) ПЕРВЫЙ запрос к эндпоинту после перезапуска воркеров
  code=$(curl -s --max-time 5 -o "/tmp/probe_${i}.bin" -w '%{http_code}' "$URL")
  rc=$?
  size=$(stat -c%s "/tmp/probe_${i}.bin" 2>/dev/null || echo 0)
  echo "  curl: код_ответа=${code:-нет} код_возврата=$rc размер=${size} байт"
  case "$rc" in
    52) echo '  [!] curl 52 — «пустой ответ»: соединение закрыли до отправки данных';;
    56) echo '  [!] curl 56 — соединение сброшено (возможно, упал воркер)';;
    18) echo '  [!] curl 18 — ответ оборван, переданы не все данные (аномалия размера)';;
  esac

  # 3) Ищем в НОВЫХ строках лога сообщения о гибели воркера
  new=$(tail -n +"$((mark + 1))" "$LOG" 2>/dev/null \
        | grep -E 'exited on signal|signal SIGSEGV|core dump')
  if [ -n "$new" ]; then
    echo "  [!] ПАДЕНИЕ ВОРКЕРА:"
    echo "$new" | sed 's/^/        /'
    crashes=$((crashes + 1))
  fi

  after=$(pgrep -f 'nginx: worker process' | sort | tr '\n' ',')
  if [ "$before" != "$after" ]; then
    echo "  [i] состав воркеров изменился (мастер пересоздал процессы)"
  fi

  sleep 1
done

echo "=============================================================="
if [ "$crashes" -gt 0 ]; then
  echo "ИТОГ: падений зафиксировано: $crashes из $N попыток."
  echo "Уязвимость воспроизведена. Переходите к фиксации улик (collect_evidence.sh)."
else
  echo "ИТОГ: падений не зафиксировано за $N попыток."
  echo "Ветку «пустой статистики» на этой конфигурации не задействовали."
  echo "Это НЕ опровержение уязвимости — переходите к Сценарию 2 (нехватка памяти)."
fi
echo "Тела ответов сохранены: /tmp/probe_*.bin"
