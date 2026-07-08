#!/usr/bin/env bash
# Прогоняет все headless-самотесты порта на Godot. Запускать из папки godot/:
#   ./run_tests.sh
# Требует godot4 в PATH. Возвращает ненулевой код, если хоть один тест упал.
set -u
cd "$(dirname "$0")" || exit 1

GODOT="${GODOT:-godot4}"
TESTS=(selftest selftest_story selftest_pause)
fail=0

for t in "${TESTS[@]}"; do
	echo "=== $t ==="
	out="$("$GODOT" --headless -s "test/$t.gd" 2>&1)"
	echo "$out" | grep -E "  ok:|  FAIL:|SELFTEST"
	if ! echo "$out" | grep -q "PASS"; then
		fail=1
		echo "!!! $t НЕ прошёл"
	fi
done

echo
if [ "$fail" -eq 0 ]; then
	echo "ВСЕ ТЕСТЫ ЗЕЛЁНЫЕ"
else
	echo "ЕСТЬ ПАДЕНИЯ"
fi
exit "$fail"
