#!/usr/bin/env bash
# ============================================================================
# apply_prlimit.sh — Сценарий 2, метод A (основной).
# Ограничивает адресное пространство (RLIMIT_AS) УЖЕ РАБОТАЮЩИХ процессов
# nginx утилитой prlimit — БЕЗ перезапуска и без правки конфигурации.
# Идея: каждый процесс получает лимит «VmPeak + запас». VmPeak — пиковое
# виртуальное потребление процесса (КиБ) за всю его жизнь. После этого любой
# рост памяти (вызовы malloc/brk/mmap) сверх лимита возвращает отказ (ENOMEM),
# и nginx попадает в ветку нехватки памяти.
#
# Использование:
#   sudo bash apply_prlimit.sh apply [запас_в_КиБ]   # применить лимиты (по умолчанию запас 4096 КиБ)
#   sudo bash apply_prlimit.sh show                  # показать текущие лимиты AS
#   sudo bash apply_prlimit.sh restore               # снять лимиты и перечитать воркеров
#
# Примечание: RLIMIT_AS задаётся в байтах; скрипт переводит КиБ из /proc в байты.
# ============================================================================
set -u

MODE="${1:-show}"
MARGIN_KB="${2:-4096}"

pids=$(pgrep -x nginx)
if [ -z "$pids" ]; then
  echo '[!] Процессы nginx не найдены.'
  exit 1
fi

case "$MODE" in
  show)
    for p in $pids; do
      echo "--- PID $p"
      prlimit --pid "$p" 2>/dev/null | grep -E 'AS ' || echo '    (нет доступа; запустите через sudo)'
    done
    ;;

  apply)
    for p in $pids; do
      peak=$(awk '/^VmPeak/{print $2}' "/proc/$p/status" 2>/dev/null)
      if [ -z "$peak" ]; then
        echo "[!] PID $p: не удалось прочитать VmPeak (нужен root) — пропуск"
        continue
      fi
      cap=$(( (peak + MARGIN_KB) * 1024 ))   # байты
      cmd=$(tr '\0' ' ' < "/proc/$p/cmdline" | cut -c1-40)
      echo "PID $p ($cmd): VmPeak=${peak} КиБ, запас=${MARGIN_KB} КиБ -> RLIMIT_AS=${cap} байт"
      if prlimit --pid "$p" --as="$cap" 2>/dev/null; then
        echo "    применено"
      else
        echo "    [!] ОШИБКА применения (нужен root?)"
      fi
    done
    echo
    echo "Готово. Новые воркеры наследуют лимит мастера."
    echo "Дальше — нагрузка status_stress.py (шаги 12-13 инструкции)."
    echo "Если nginx перестал отвечать даже без нагрузки — лимит слишком мал:"
    echo "выполните restore и повторите apply с бОльшим запасом (например, 16384)."
    ;;

  restore)
    for p in $pids; do
      if prlimit --pid "$p" --as=unlimited 2>/dev/null; then
        echo "PID $p: лимит снят"
      else
        echo "PID $p: [!] не удалось снять (нужен root?)"
      fi
    done
    echo
    echo "Теперь выполните 'sudo nginx -s reload', чтобы новые воркеры гарантированно"
    echo "пересоздались без лимита (старые уже получили unlimited)."
    ;;

  *)
    echo "Неизвестный режим: $MODE. Допустимо: show | apply | restore"
    exit 1
    ;;
esac
