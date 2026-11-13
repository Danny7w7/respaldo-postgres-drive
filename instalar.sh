#!/usr/bin/env bash
# Instala el respaldo en el servidor y lo programa en cron.
#
# Uso (como root o con sudo, desde la carpeta de este proyecto, con el .env ya lleno):
#   sudo bash instalar.sh "0 2 * * *"      # expresión cron; por defecto, todos los días a las 02:00
#
# Instala:
#   /opt/respaldo-postgres/respaldo.sh
#   /opt/respaldo-postgres/.env         (copia del .env de este proyecto, chmod 600)
#   la carpeta LOCAL_DIR del .env
#   línea en el crontab de root

set -euo pipefail

HORARIO="${1:-0 2 * * *}"
ORIGEN="$(cd "$(dirname "$0")" && pwd)"
DESTINO=/opt/respaldo-postgres
SCRIPT="$DESTINO/respaldo.sh"

if [[ $EUID -ne 0 ]]; then
    echo "Ejecuta este instalador con sudo." >&2
    exit 1
fi
if [[ ! -f "$ORIGEN/.env" ]]; then
    echo "Falta $ORIGEN/.env (cópialo de .env.example y llénalo)." >&2
    exit 1
fi

install -d -m 700 "$DESTINO"
install -m 700 "$ORIGEN/respaldo.sh" "$SCRIPT"
install -m 600 "$ORIGEN/.env" "$DESTINO/.env"

# shellcheck source=/dev/null
LOCAL_DIR="$(source "$DESTINO/.env" && echo "${LOCAL_DIR:-/var/backups/postgres}")"
install -d -m 700 "$LOCAL_DIR"

LINEA="$HORARIO $SCRIPT >/dev/null 2>&1"
( crontab -l 2>/dev/null | grep -vF "$SCRIPT" || true; echo "$LINEA" ) | crontab -
echo "Instalado en $DESTINO (config: $DESTINO/.env)"
echo "Cron: $LINEA"
echo
echo "Prueba manual: sudo $SCRIPT"
