#!/usr/bin/env bash
# ============================================================================
# check_env.sh — разведка окружения стенда перед воспроизведением уязвимости
# модуля extstatus (nginx 1.24.0, ngx_http_exstatus_module).
# Запуск:  sudo bash check_env.sh
# Скрипт только ЧИТАЕТ информацию и ничего не меняет на стенде.
# ============================================================================
set -u

hr() { printf '\n===== %s =====\n' "$1"; }

hr "1. Версия и сборка nginx"
nginx -V 2>&1
nginx -V 2>&1 | grep -q 'add-module' \
  || echo '[!] ВНИМАНИЕ: параметр --add-module не найден — возможно, это не тот стенд'

hr "2. Поиск эндпоинтов мониторинга в конфигурации"
# nginx -T выводит итоговую конфигурацию со всеми включёнными файлами
nginx -T 2>/dev/null | grep -niE 'extstatus|prometheus|status_json|status_prometheus' \
  || echo '[!] Директивы не найдены через nginx -T. Попробуйте: sudo nginx -T 2>/dev/null | less'

hr "3. Пути к логам (из параметров сборки)"
nginx -V 2>&1 | grep -oE '\-\-(error|access)-log-path=[^ ]+' || true
echo '(если пути не показаны — логи заданы в конфигурации, ищите на шаге 2)'

hr "4. Процессы nginx (мастер и воркеры)"
ps -o pid,ppid,etime,rss,vsz,cmd -C nginx 2>/dev/null || echo '[!] Процессов nginx не найдено'

hr "5. Потребление виртуальной памяти процессами (VmPeak/VmSize, КиБ)"
for p in $(pgrep -x nginx); do
  cmd=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)
  echo "--- PID $p (${cmd})"
  grep -E 'VmPeak|VmSize|VmRSS' "/proc/$p/status" 2>/dev/null || echo '    (нет доступа к /proc)'
done

hr "6. Доступные утилиты"
for c in python3 curl prlimit gdb addr2line dmesg jq free stat systemd-run; do
  if command -v "$c" >/dev/null 2>&1; then echo "  есть:      $c"; else echo "  ОТСУТСТВУЕТ: $c"; fi
done

hr "7. systemd и контрольная группа (cgroup)"
if command -v systemctl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
  echo "  systemd активен"
  echo "  юнит nginx: $(systemctl is-active nginx 2>/dev/null || echo 'юнит nginx не найден/не активен')"
  systemctl show nginx -p MemoryMax -p MemorySwapMax 2>/dev/null | sed 's/^/  /'
else
  echo "  systemd недоступен (nginx, вероятно, запущен вручную или в контейнере)"
fi
fstype=$(stat -fc %T /sys/fs/cgroup 2>/dev/null)
[ "$fstype" = "cgroup2fs" ] && echo "  контроллер: cgroup v2" || echo "  контроллер: cgroup v1 или неопределён ($fstype)"

hr "8. Оперативная память стенда"
free -m 2>/dev/null || true
grep MemAvailable /proc/meminfo 2>/dev/null || true

hr "9. Права на dmesg и параметры core dump"
if dmesg -T 2>/dev/null | head -1 >/dev/null; then
  echo "  dmesg доступен"
else
  echo "  dmesg требует sudo (запускайте скрипты через sudo)"
fi
echo "  core_pattern: $(cat /proc/sys/kernel/core_pattern 2>/dev/null)"
echo "  ulimit -c (текущая сессия): $(ulimit -c)"
if command -v coredumpctl >/dev/null 2>&1; then
  echo "  coredumpctl есть; список дампов: coredumpctl list nginx"
fi

hr "10. Что зафиксировать перед началом работы"
echo "  а) URL эндпоинтов мониторинга (из шага 2), например:"
echo "     http://127.0.0.1:ПОРТ/ПУТЬ_json   и   http://127.0.0.1:ПОРТ/ПУТЬ_prometheus"
echo "  б) путь к error.log (из шага 3)"
echo "  в) число воркеров и их PID (из шага 4)"
echo
echo "Разведка завершена. Дальше — по инструкции (Этап 0, шаги 1-5)."
