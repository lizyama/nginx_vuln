#!/usr/bin/env bash
# ============================================================================
# collect_evidence.sh — сбор доказательств после падения воркера.
# Создаёт папку evidence_<дата-время> и складывает туда:
#   версию/сборку nginx, снимок процессов, хвост error.log, строки о падениях,
#   dmesg (segfault/oom), попытку расшифровки адреса падения через addr2line,
#   сохранённые тела ответов, отчёт status_stress.py.
#
# Использование:  sudo bash collect_evidence.sh [URL_эндпоинта]
# ============================================================================
set -u

URL="${1:-}"
DIR="evidence_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$DIR"
NGINX_BIN=$(readlink -f "$(command -v nginx 2>/dev/null)" 2>/dev/null)
NGINX_BIN="${NGINX_BIN:-/usr/sbin/nginx}"

echo "Сбор доказательств в папку: $DIR"

# 1. Версия и сборка
{ date; echo; nginx -V 2>&1; } > "$DIR/01_nginx_version.txt" 2>&1

# 2. Процессы на момент сбора
ps -o pid,ppid,etime,rss,vsz,cmd -C nginx > "$DIR/02_processes.txt" 2>&1

# 3. Хвост error.log и только строки о гибели воркеров
LOG=$(nginx -V 2>&1 | grep -oE '\-\-error-log-path=[^ ]+' | head -1 | cut -d= -f2)
LOG="${LOG:-/var/log/nginx/error.log}"
tail -n 300 "$LOG" > "$DIR/03_error_log_tail.txt" 2>&1
grep -nE 'exited on signal|signal SIGSEGV|core dump' "$DIR/03_error_log_tail.txt" \
  > "$DIR/04_crash_lines.txt" 2>/dev/null
echo "Строк о падениях: $(wc -l < "$DIR/04_crash_lines.txt" 2>/dev/null)"

# 4. dmesg: segfault и oom-kill
dmesg -T > "$DIR/05_dmesg_full.txt" 2>/dev/null || sudo dmesg -T > "$DIR/05_dmesg_full.txt" 2>/dev/null
grep -iE 'segfault|out of memory|oom' "$DIR/05_dmesg_full.txt" > "$DIR/06_dmesg_crashes.txt" 2>/dev/null

# 5. Атрибуция адреса падения: segfault ip -> имя функции (addr2line)
#    Для PIE-бинарника нужен офсет: ip минус база загрузки. Пробуем оба варианта.
if command -v python3 >/dev/null 2>&1; then
python3 - "$DIR/06_dmesg_crashes.txt" "$NGINX_BIN" > "$DIR/07_addr2line_result.txt" <<'PY'
import re, subprocess, sys
try:
    dmesg = open(sys.argv[1], errors="replace").read()
except OSError:
    sys.exit(0)
binary = sys.argv[2]
found = False
pat = re.compile(r"segfault at (\S+) ip ([0-9a-f]+).*?in ([^\s\[]+)\[([0-9a-f]+)\+([0-9a-f]+)\]")
for m in pat.finditer(dmesg):
    found = True
    ip = int(m.group(2), 16)
    base = int(m.group(4), 16)
    name = m.group(3)
    print("процесс %s: ip=0x%x база=0x%x" % (name, ip, base))
    for cand, label in ((ip, "как есть (не-PIE)"), (ip - base, "ip-база (PIE)")):
        if cand < 0:
            continue
        try:
            out = subprocess.run(["addr2line", "-e", binary, "-f", "-C", hex(cand)],
                                 capture_output=True, text=True, timeout=10).stdout.strip()
        except Exception as e:
            out = "(addr2line недоступен: %s)" % e
        print("  вариант %s -> %s" % (label, out.replace("\n", " | ")))
    print()
if not found:
    print("Строк segfault в dmesg не найдено (либо ядро пишет их в journalctl -k).")
PY
fi

# 6. core dump (если настраивались)
if command -v coredumpctl >/dev/null 2>&1; then
  coredumpctl list nginx > "$DIR/08_coredumpctl.txt" 2>&1 || true
  tail -3 "$DIR/08_coredumpctl.txt" 2>/dev/null | sed 's/^/  /'
fi
echo "core_pattern: $(cat /proc/sys/kernel/core_pattern 2>/dev/null)" >> "$DIR/08_coredumpctl.txt" 2>/dev/null

# 7. Тела ответов и отчёт нагрузочного генератора
cp -f /tmp/probe_*.bin "$DIR"/ 2>/dev/null
cp -f /tmp/baseline.* "$DIR"/ 2>/dev/null
cp -f /tmp/status_stress_report.json "$DIR/09_status_stress_report.json" 2>/dev/null

# 8. Свежий контрольный запрос (если эндпоинт жив)
if [ -n "$URL" ]; then
  curl -s --max-time 5 "$URL" -o "$DIR/10_last_response.bin" \
    -w 'код=%{http_code} размер=%{size_download}\n' > "$DIR/10_last_response_meta.txt" 2>&1 || true
fi

echo
echo "Готово. Содержимое папки:"
ls -1 "$DIR" 2>/dev/null | sed 's/^/  /'
echo
echo "Ключевые файлы для отчёта:"
echo "  04_crash_lines.txt    — строки error.log о гибели воркеров"
echo "  06_dmesg_crashes.txt  — строки ядра о segfault / oom-kill"
echo "  07_addr2line_result.txt — в какой функции произошло падение"
