#!/usr/bin/env bash
# Respaldo de una base PostgreSQL que corre en Docker y subida a Google Drive con rclone.
#
# Uso:   respaldo.sh [ruta_config]        (por defecto, el .env junto a este script)
# Salida: 0 = dump verificado y subido; 1 = algo falló (ver log).

set -Eeuo pipefail

CONFIG="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.env}"
if [[ ! -r "$CONFIG" ]]; then
    echo "No se puede leer la configuración: $CONFIG" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG"

: "${CONTAINER:?Falta CONTAINER en $CONFIG}"
: "${DB_NAME:?Falta DB_NAME en $CONFIG}"
: "${DB_USER:?Falta DB_USER en $CONFIG}"
: "${LOCAL_DIR:?Falta LOCAL_DIR en $CONFIG}"
: "${RCLONE_REMOTE:?Falta RCLONE_REMOTE en $CONFIG}"
KEEP_LAST="${KEEP_LAST:-7}"
COMPRESS="${COMPRESS:-6}"
DB_PASSWORD="${DB_PASSWORD:-}"
LOG_FILE="${LOG_FILE:-}"
RCLONE_CONFIG_FILE="${RCLONE_CONFIG_FILE:-}"

if ! [[ "$KEEP_LAST" =~ ^[1-9][0-9]*$ ]]; then
    echo "KEEP_LAST debe ser un entero >= 1 (valor: $KEEP_LAST)" >&2
    exit 1
fi

mkdir -p "$LOCAL_DIR"
if [[ -n "$LOG_FILE" ]]; then
    mkdir -p "$(dirname "$LOG_FILE")"
    exec > >(tee -a "$LOG_FILE") 2>&1
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

PARTIAL=""
on_error() {
    log "ERROR en la línea $1 (código $2). Respaldo NO completado."
}
cleanup() {
    [[ -n "$PARTIAL" && -f "$PARTIAL" ]] && rm -f -- "$PARTIAL"
    return 0
}
trap 'on_error $LINENO $?' ERR
trap cleanup EXIT

rclone_cmd() {
    if [[ -n "$RCLONE_CONFIG_FILE" ]]; then
        rclone --config "$RCLONE_CONFIG_FILE" "$@"
    else
        rclone "$@"
    fi
}

# Une el remoto con un nombre de archivo ("gdrive:" + "x" -> "gdrive:x"; "gdrive:a" + "x" -> "gdrive:a/x").
remote_path() {
    case "$RCLONE_REMOTE" in
        *: | */) echo "${RCLONE_REMOTE}$1" ;;
        *) echo "${RCLONE_REMOTE}/$1" ;;
    esac
}

# Evita que dos ejecuciones se solapen.
if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCAL_DIR/.respaldo.lock"
    if ! flock -n 9; then
        log "Ya hay otro respaldo en curso; se omite esta ejecución."
        exit 1
    fi
fi

INICIO=$(date +%s)
log "=== Inicio del respaldo de '$DB_NAME' (contenedor '$CONTAINER') ==="

# 1. Requisitos
command -v docker >/dev/null || { log "ERROR: no se encontró 'docker'."; exit 1; }
command -v rclone >/dev/null || { log "ERROR: no se encontró 'rclone'."; exit 1; }
if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != "true" ]]; then
    log "ERROR: el contenedor '$CONTAINER' no existe o no está corriendo."
    exit 1
fi

# Restos de ejecuciones interrumpidas (el lock garantiza que no hay otra en curso).
shopt -s nullglob
rm -f -- "$LOCAL_DIR/${DB_NAME}"_*.dump.partial

# 2. Dump con el pg_dump del propio contenedor (misma versión que el servidor).
NOMBRE="${DB_NAME}_$(date '+%Y%m%d_%H%M%S').dump"
DESTINO="$LOCAL_DIR/$NOMBRE"
PARTIAL="$DESTINO.partial"

ENV_ARGS=()
[[ -n "$DB_PASSWORD" ]] && ENV_ARGS=(-e "PGPASSWORD=$DB_PASSWORD")

log "Generando dump: $NOMBRE"
docker exec ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} "$CONTAINER" \
    pg_dump -U "$DB_USER" -d "$DB_NAME" --format=custom --compress="$COMPRESS" >"$PARTIAL"

# 3. Verificación: no vacío y legible por pg_restore.
if [[ ! -s "$PARTIAL" ]]; then
    log "ERROR: el dump quedó vacío."
    exit 1
fi
docker exec -i "$CONTAINER" pg_restore --list <"$PARTIAL" >/dev/null
mv -- "$PARTIAL" "$DESTINO"
PARTIAL=""
TAMANO=$(du -h "$DESTINO" | cut -f1)
log "Dump verificado ($TAMANO)."

# 4. Retención local: conservar los KEEP_LAST más recientes (el nombre lleva la fecha).
LOCALES=("$LOCAL_DIR/${DB_NAME}"_*.dump)
printf '%s\n' "${LOCALES[@]##*/}" | sort -r |
    tail -n +"$((KEEP_LAST + 1))" | while read -r viejo; do
        rm -f -- "$LOCAL_DIR/$viejo"
        log "Borrado local: $viejo"
    done

# 5. Subida: copia el nuevo y cualquier dump que no se hubiera subido antes.
log "Subiendo a $RCLONE_REMOTE ..."
rclone_cmd copy "$LOCAL_DIR" "$RCLONE_REMOTE" --include "${DB_NAME}_*.dump" --checksum --retries 3
rclone_cmd check "$LOCAL_DIR" "$RCLONE_REMOTE" --one-way --include "$NOMBRE"
log "Subida verificada: $(remote_path "$NOMBRE")"

# 6. Retención en Drive (lo borrado va a la papelera de Drive).
rclone_cmd lsf "$RCLONE_REMOTE" --files-only --include "${DB_NAME}_*.dump" | sort -r |
    tail -n +"$((KEEP_LAST + 1))" | while read -r viejo; do
        rclone_cmd deletefile "$(remote_path "$viejo")"
        log "Borrado en Drive: $viejo"
    done

log "=== Respaldo completado en $(($(date +%s) - INICIO)) s: $NOMBRE ($TAMANO) ==="
