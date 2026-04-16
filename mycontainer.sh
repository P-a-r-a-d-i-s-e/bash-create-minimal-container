#!/bin/bash

# Проверка на запуск от имени root (для unshare и cgroup)
if [[ $EUID -ne 0 ]]; then
   echo "Ошибка: cкрипт должен быть запущен от имени root."
   exit 1
fi

if [[ $# -eq 0 ]]; then
    echo "Использование: sudo $0 <команда> [аргументы...]"
    exit 1
fi

EXEC_COMMAND=$@

# Генерируем уникальный ID для запуска как container_ + количество наносекунд с 1 янв 1970
CONTAINER_ID="container_$(date +%s%N)"
CGROUP_PATH="/sys/fs/cgroup/${CONTAINER_ID}"

cleanup() {
    # Перемещаем текущий процесс скрипта в корневой cgroup 
    echo 0 > /sys/fs/cgroup/cgroup.procs

    if [[ -d "${CGROUP_PATH}" ]]; then
        # Убиваем все процессы, которые остались внутри
        if [[ -f "${CGROUP_PATH}/cgroup.kill" ]]; then
            echo "1" > "${CGROUP_PATH}/cgroup.kill"
        else
            # Если cgroup.kill недоступен (старое ядро)
            local pids=$(cat "${CGROUP_PATH}/cgroup.procs" 2> /dev/null)
            [[ -n "$pids" ]] && kill -9 $pids 2> /dev/null
        fi

        # Даем ядру небольшую паузу
        sleep 0.2

        if rmdir "${CGROUP_PATH}" 2> /dev/null; then
            echo "[Cleanup] Cgroup успешно удалена."
        else
            echo "[Error] Не удалось удалить ${CGROUP_PATH}. Процессы внутри: $(cat "${CGROUP_PATH}/cgroup.procs" 2> /dev/null)"
            # Последняя попытка: если rmdir не сработал, попробуем еще раз через секунду
            sleep 1
            rmdir "${CGROUP_PATH}" 2> /dev/null && echo "[Cleanup] Удалена со второй попытки."
        fi
    fi
}

trap cleanup EXIT

echo "[Init] Создание cgroup: ${CONTAINER_ID}"
mkdir -p "${CGROUP_PATH}"

echo "[Init] Установка лимита памяти: 128MB"
if [[ -f "${CGROUP_PATH}/memory.max" ]]; then
    echo $(( 128 * 1024 * 1024 )) > "${CGROUP_PATH}/memory.max"
    echo "0" > "${CGROUP_PATH}/memory.swap.max"
else
    echo "Ошибка: cgroup v2 не поддерживается или контроллер памяти не активен."
    exit 1
fi

# 3. Установка лимита CPU (0.5 ядра)
# 50000 микросекунд (квота) на каждые 100000 микросекунд (период)
echo "[Init] Установка лимита CPU: 50%"
if [[ -f "${CGROUP_PATH}/cpu.max" ]]; then
    echo "50000 100000" > "${CGROUP_PATH}/cpu.max"
else
    echo "[Warning] Контроллер CPU не активен. Возможно, нужно включить его в родительской cgroup."
fi

echo "[Run] Выполнение: ${EXEC_COMMAND}"
echo "------------------------------------------------"

# Добавляем текущую оболочку в cgroup, чтобы дочерние процессы унаследовали ограничение
echo $$ > "${CGROUP_PATH}/cgroup.procs"

unshare --fork --pid --uts --net --mount --mount-proc "${EXEC_COMMAND}"

EXIT_CODE=$?

echo "------------------------------------------------"
echo "[Done] Команда завершена с кодом: ${EXIT_CODE}"

exit "${EXIT_CODE}"
