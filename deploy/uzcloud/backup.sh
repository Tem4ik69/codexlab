#!/bin/bash
#
# Резервные копии базы Codex Lab с машины админки в хранилище S3 UzCloud.
# Всё, что нельзя потерять, — в базе: заявки, подписчики, проекты и сайты
# клиентов, тексты и цены сайта. Папок с файлами копировать не нужно.
#
#   backup.sh db        копия базы: pg_dump, проверка, шифрование gpg —
#                       codexlab/db/codexlab-ГГГГ-ММ-ДД.dump.gpg, 90 дней;
#                       три последние ночи — ещё и в /opt/codexlab/backup
#   backup.sh db МЕТКА  то же, отдельным файлом со временем и меткой —
#                       codexlab-ГГГГ-ММ-ДД-ЧЧММ-МЕТКА.dump.gpg; ночную копию
#                       не заменяет. Так снимает копию кнопка релиза перед
#                       схемой базы (метка release)
#   backup.sh check     проверка восстановления: последняя ночная копия — из
#                       хранилища, расшифровка, загрузка во временную базу без
#                       сети и сверка с боевой. Временная база и расшифрованная
#                       копия удаляются сразу: данные с машины не уходят
#
# Расписание (cron пользователя deploy, ставит release.sh admin): копия —
# каждую ночь в 03:40, проверка — в 05:10 по Ташкенту. Ключи хранилища и
# пароль шифрования — /opt/codexlab/env/backup.env (кладёт кнопка релиза из
# секретов GitHub): S3_ENDPOINT, S3_BUCKET, S3_ACCESS_KEY, S3_SECRET_KEY,
# BACKUP_PASSPHRASE — без него копию не открыть.
#
# Итог — строкой в журнал (/opt/codexlab/backup/backup.log) и кодом выхода;
# сбой начинается со слова ОШИБКА. Без данных из базы: только размеры,
# число таблиц и доли строк.
#
# Сигналы в Healthchecks.io — HC_PING_DB (ночная копия базы) и HC_PING_CHECK
# (проверка восстановления), адреса — в backup.env из секретов GitHub (в коде и
# журнале их нет). Начало — /start, итог — строка журнала, сбой — /fail с
# причиной. Не пришёл сигнал вовремя (машина выключена, cron не сработал) —
# тревогу поднимает сам Healthchecks. Копия перед релизом (с меткой) сигналов
# не шлёт: её итог виден в самом релизе. Пустые адреса — без сигналов.
set -euo pipefail

APP_HOME=${CODEXLAB_HOME:-/opt/codexlab}
DEPLOY=$APP_HOME/deploy
ENV_DIR=$APP_HOME/env
WORK=$APP_HOME/backup
# Точные версии и digest, через зеркало Google (Docker Hub режет скачивания без входа);
# PG_IMAGE — тот же, что у базы в compose.admin.yml: копия поднимается той же версией
RCLONE_IMAGE=mirror.gcr.io/rclone/rclone:1.68.2@sha256:74c51b8817e5431bd6d7ed27cb2a50d8ee78d77f6807b72a41ef6f898845942b
PG_IMAGE=mirror.gcr.io/library/postgres:18.7@sha256:2ea8630df176ad090ec92136dee850397c5af8781e4bcf2e4162593691c61bbc
KEEP_DAYS=90
MIN_TABLES=14            # таблиц в схеме codexlab (app/db.py) — меньше: копия неполная

what=${1:?db или check}
label=${2:-}
if [ -n "$label" ] && ! [[ "$label" =~ ^[a-z0-9-]{1,32}$ ]]; then
    echo "Метка копии — латиница, цифры и дефис: «$label» не подходит" >&2
    exit 1
fi

if [ ! -s "$ENV_DIR/backup.env" ]; then
    echo "$(date -Iseconds) ОШИБКА: нет $ENV_DIR/backup.env — копия не снята." >&2
    exit 1
fi
# shellcheck disable=SC1091
. "$ENV_DIR/backup.env"
: "${S3_ENDPOINT:?}" "${S3_BUCKET:?}" "${S3_ACCESS_KEY:?}" "${S3_SECRET_KEY:?}" "${BACKUP_PASSPHRASE:?}"
prefix=${BACKUP_PREFIX:-codexlab}

hc_url=""
case "$what" in
    db) if [ -z "$label" ]; then hc_url=${HC_PING_DB:-}; fi ;;
    check) hc_url=${HC_PING_CHECK:-} ;;
esac
hc_sent=0
# hc_ping <"" | /start | /fail> [текст] — сбой связи с Healthchecks копию не останавливает
hc_ping() {
    if [ -z "$hc_url" ]; then return 0; fi
    curl -fsS -m 10 --retry 3 -o /dev/null --data-raw "${2:-}" "$hc_url$1" 2> /dev/null || true
}
hc_ping /start

compose=(docker compose -p codexlab -f "$DEPLOY/compose.admin.yml" --env-file "$ENV_DIR/compose.env")
live() { "${compose[@]}" exec -T db psql -U codexlab -d codexlab -Atqc "$1"; }

# Конец: без расшифрованной копии на диске и без временной базы проверки
plain=""
check_dir=""
check_box=""
finish() {
    local rc=$?
    # Упало не через fail (set -e: pg_dump, gpg, docker…) — Healthchecks всё равно узнает о сбое
    if [ "$rc" -ne 0 ] && [ "$hc_sent" = 0 ]; then
        hc_ping /fail "ОШИБКА: $what прервался с кодом $rc — подробности в /opt/codexlab/backup/backup.log"
    fi
    if [ -n "$plain" ]; then rm -f "$plain"; fi
    if [ -n "$check_box" ]; then docker rm -f "$check_box" > /dev/null 2>&1 || true; fi
    if [ -n "$check_dir" ]; then rm -rf "$check_dir"; fi
}
trap finish EXIT

# Хранилище — remote «s3». Значения уходят в контейнер через окружение
# (-e ИМЯ без значения): в списке процессов их не видно
export RCLONE_CONFIG_S3_TYPE=s3
export RCLONE_CONFIG_S3_PROVIDER=Other
export RCLONE_CONFIG_S3_ENDPOINT="$S3_ENDPOINT"
export RCLONE_CONFIG_S3_ACCESS_KEY_ID="$S3_ACCESS_KEY"
export RCLONE_CONFIG_S3_SECRET_ACCESS_KEY="$S3_SECRET_KEY"
export RCLONE_CONFIG_S3_FORCE_PATH_STYLE=true

# rclone <каталог машины> <аргументы rclone…> — каталог виден как /work
rclone() {
    local dir="$1"
    shift
    docker run --rm --network host -v "$dir:/work" \
        -e RCLONE_CONFIG_S3_TYPE -e RCLONE_CONFIG_S3_PROVIDER -e RCLONE_CONFIG_S3_ENDPOINT \
        -e RCLONE_CONFIG_S3_ACCESS_KEY_ID -e RCLONE_CONFIG_S3_SECRET_ACCESS_KEY \
        -e RCLONE_CONFIG_S3_FORCE_PATH_STYLE \
        "$RCLONE_IMAGE" "$@" --s3-no-check-bucket --config ""
}

fail() {
    echo "$(date -Iseconds) ОШИБКА${2:+ $2}: $1" >&2
    hc_sent=1
    hc_ping /fail "ОШИБКА${2:+ $2}: $1"
    exit 1
}

# Итог — в журнал и в Healthchecks
done_ok() {
    echo "$1"
    hc_sent=1
    hc_ping "" "$1"
}

umask 077
mkdir -p "$WORK"

case "$what" in
    db)
        stamp=$(date +%Y-%m-%d)
        if [ -n "$label" ]; then
            stamp="$(date +%Y-%m-%d-%H%M)-$label"
        fi
        plain="$WORK/codexlab-$stamp.dump"
        file="codexlab-$stamp.dump.gpg"

        if [ -z "$("${compose[@]}" ps --status running -q db 2>/dev/null)" ]; then
            fail "база не запущена (docker compose ps: служба db) — копия не снята"
        fi
        "${compose[@]}" exec -T db pg_dump -U codexlab --format=custom --compress=9 codexlab > "$plain"
        size=$(stat -c %s "$plain")
        tables=$("${compose[@]}" exec -T db pg_restore --list < "$plain" | grep -c 'TABLE DATA' || true)
        if [ "$tables" -lt "$MIN_TABLES" ]; then
            fail "в копии базы таблиц с данными $tables из $MIN_TABLES ($size байт) — копия неполная"
        fi

        gpg --batch --yes --pinentry-mode loopback --symmetric --cipher-algo AES256 \
            --passphrase-fd 3 --output "$WORK/$file" "$plain" 3<<< "$BACKUP_PASSPHRASE"
        rm -f "$plain"
        plain=""

        rclone "$WORK" copyto "/work/$file" "s3:$S3_BUCKET/$prefix/db/$file" \
            || fail "копия $file не ушла в хранилище $S3_ENDPOINT"
        rclone "$WORK" delete --min-age "${KEEP_DAYS}d" "s3:$S3_BUCKET/$prefix/db/" \
            || echo "$(date -Iseconds) ВНИМАНИЕ: старые копии старше $KEEP_DAYS дней не удалились" >&2
        # На машине — три последние ночи: быстрое восстановление без хранилища
        find "$WORK" -maxdepth 1 -name 'codexlab-*.dump.gpg' -mtime +3 -delete
        done_ok "$(date -Iseconds) Копия базы: $prefix/db/$file, $((size / 1024)) КБ, таблиц $tables"
        ;;
    check)
        # Копия, из которой ни разу не поднимались, — ещё не копия. Здесь —
        # как при аварии: копия из хранилища (не с этого диска), пароль
        # шифрования, пустая база
        started=$(date +%s)
        free=$(df --output=avail -k "$WORK" | tail -n 1)
        if [ "$free" -lt 1048576 ]; then
            fail "мало места на диске ($((free / 1024)) МБ свободно, нужен 1 ГБ)" "проверки восстановления"
        fi

        # Последняя ночная копия — по времени загрузки; не старше 26 часов
        status=0
        listing=$(rclone "$WORK" lsf --files-only --format "tp" --separator ";" --time-format RFC3339 \
            --include "codexlab-????-??-??.dump.gpg" "s3:$S3_BUCKET/$prefix/db/" 2> /dev/null) || status=$?
        # 3 — папки нет: в хранилище S3 это и есть «ни одной копии»
        if [ "$status" -ne 0 ] && [ "$status" -ne 3 ]; then
            fail "хранилище $S3_ENDPOINT недоступно (rclone, код $status)" "проверки восстановления"
        fi
        latest=$(sort -t ";" -k 1 <<< "$listing" | tail -n 1)
        name=${latest#*;}
        if [ -z "$name" ]; then
            fail "в хранилище нет ночных копий базы ($prefix/db/)" "проверки восстановления"
        fi
        age=$(( ($(date +%s) - $(date -d "${latest%%;*}" +%s)) / 3600 ))
        if [ "$age" -gt 26 ]; then
            fail "последняя ночная копия $name снята $age ч назад — ночные копии не снимаются" "проверки восстановления"
        fi

        check_dir=$(mktemp -d "$WORK/check.XXXXXX")
        rclone "$check_dir" copyto "s3:$S3_BUCKET/$prefix/db/$name" "/work/$name" \
            || fail "копия $name не скачивается из хранилища" "проверки восстановления"
        plain="$check_dir/check.dump"
        if ! gpg --batch --quiet --pinentry-mode loopback --passphrase-fd 3 \
            --output "$plain" --decrypt "$check_dir/$name" 3<<< "$BACKUP_PASSPHRASE" 2> /dev/null; then
            fail "копия $name не расшифровывается паролем BACKUP_PASSPHRASE" "проверки восстановления"
        fi
        rm -f "$check_dir/$name"
        size=$(stat -c %s "$plain")

        # Временная база: без сети, вход без пароля — только изнутри
        # контейнера; удаляется вместе с данными при любом исходе
        check_box=codexlab-restore-check
        docker rm -f "$check_box" > /dev/null 2>&1 || true
        docker run -d --rm --name "$check_box" --network none --memory 512m \
            -e POSTGRES_HOST_AUTH_METHOD=trust -e POSTGRES_DB=restore_check \
            "$PG_IMAGE" -c shared_buffers=64MB -c fsync=off -c synchronous_commit=off \
            -c full_page_writes=off > /dev/null
        # По TCP: при первом запуске образ поднимает базу сначала только на сокете
        for _ in $(seq 1 60); do
            docker exec "$check_box" pg_isready -q -h 127.0.0.1 -U postgres && break
            sleep 1
        done
        docker exec "$check_box" pg_isready -q -h 127.0.0.1 -U postgres \
            || fail "временная база для проверки не запустилась" "проверки восстановления"
        restored() { docker exec "$check_box" psql -U postgres -d restore_check -Atqc "$1"; }

        # Владельцы и права — роли боевой базы, во временной их нет: без них
        if ! docker exec -i "$check_box" pg_restore -U postgres -d restore_check \
            --no-owner --no-acl --exit-on-error < "$plain" > /dev/null 2> "$check_dir/restore.err"; then
            # В тексте ошибки бывают строки данных — в итог только начало, без почт и телефонов
            first=$( (grep -m 1 'error:' "$check_dir/restore.err" || true) | cut -c 1-160 \
                | sed -E 's/[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}/[почта]/g; s/\+?[0-9][0-9 ()-]{7,}[0-9]/[номер]/g')
            fail "копия $name не загружается в пустую базу: ${first:-pg_restore завершился с ошибкой}" "проверки восстановления"
        fi
        rm -f "$plain"
        plain=""

        tables=$(restored "select count(*) from pg_tables where schemaname = 'public'")
        if [ "$tables" -lt "$MIN_TABLES" ]; then
            fail "после загрузки копии $name в базе $tables таблиц из $MIN_TABLES — копия неполная" "проверки восстановления"
        fi
        steps=$(restored "select coalesce(max(version), 0) from schema_migrations")
        # Главные таблицы: в копии не меньше 90% строк боевой (за ночь база
        # почти только растёт; меньше — копия старая или обрезанная). Пустая
        # боевая таблица (сайт только открылся) — сверять нечего
        shares=""
        for table in orders subscribers projects site_publications; do
            got=$(restored "select count(*) from $table")
            now=$(live "select count(*) from $table")
            share=100
            if [ "$now" -gt 0 ]; then
                share=$(( got * 100 / now ))
            fi
            if [ "$share" -lt 90 ]; then
                fail "в копии $name в таблице $table $share% строк боевой базы — копия старая или неполная" "проверки восстановления"
            fi
            shares="${shares:+$shares, }$table $share%"
        done

        done_ok "$(date -Iseconds) Проверка восстановления: копия $name ($((size / 1024)) КБ, снята $age ч назад) поднимается: таблиц $tables, схема — шаг $steps; $shares от боевой; $(( $(date +%s) - started )) с"
        ;;
    *)
        echo "Что делать: db или check" >&2
        exit 1
        ;;
esac
