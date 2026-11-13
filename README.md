# Respaldo PostgreSQL (Docker) → Google Drive

Genera un dump de una base PostgreSQL que corre en un contenedor Docker, lo verifica, lo sube a una carpeta de
Google Drive con [rclone](https://rclone.org) y conserva solo los últimos `KEEP_LAST` respaldos (en local y en Drive).
Se programa con cron en el servidor.

Vive **fuera del proyecto de la app**, para que los deploys no lo toquen:

| Qué | Ruta en el servidor |
|---|---|
| Script | `/opt/respaldo-postgres/respaldo.sh` |
| Configuración | `/opt/respaldo-postgres/.env` (copia del `.env` del proyecto, `chmod 600`) |
| Dumps | `/var/backups/postgres/` |
| Log | `/var/log/respaldo-postgres.log` |

## Qué hace cada ejecución

1. Comprueba que el contenedor está corriendo y que `rclone` está instalado. Un lock impide dos ejecuciones a la vez.
2. `pg_dump --format=custom` **dentro del contenedor** (misma versión que el servidor), con la salida al disco del host
   como `.partial`.
3. Lo verifica: que no esté vacío y que `pg_restore --list` lo lea. Solo entonces lo renombra a `.dump`.
4. Borra los dumps locales que pasen de `KEEP_LAST`.
5. `rclone copy` a Drive (sube también cualquier dump que no se hubiera subido antes) y `rclone check` del archivo nuevo.
6. Borra en Drive los que pasen de `KEEP_LAST` (van a la papelera de Drive).

Si algo falla, el script termina con código 1 y el error queda en el log.

## Instalación en el servidor

### 1. rclone y el remoto de Google Drive

```bash
sudo -v ; curl https://rclone.org/install.sh | sudo bash
sudo rclone config        # como root, porque el cron corre como root
```

En `rclone config`: `n` (nuevo remoto) → nombre `gdrive` → tipo `drive` → `client_id`/`client_secret` en blanco
(o los de tu proyecto de Google Cloud, recomendado si hay mucho tráfico) → scope **`drive.file`**
(rclone solo ve lo que él mismo crea) → `Use web browser to automatically authenticate?` → **`n`**,
porque el servidor no tiene navegador.

rclone te mostrará un comando `rclone authorize "drive" "..."`. Ejecútalo **en tu PC** (con rclone instalado),
inicia sesión en el navegador con la cuenta de Google y pega en el servidor el token que devuelve.

Comprueba:

```bash
sudo rclone mkdir gdrive:Respaldos/mi_base
sudo rclone lsd gdrive:Respaldos
```

### 2. Copiar e instalar

```bash
scp -r respaldo-postgres-drive usuario@servidor:/tmp/
ssh usuario@servidor
cd /tmp/respaldo-postgres-drive
nano .env                                 # llenar CONTAINER, DB_NAME, RCLONE_REMOTE... (si no lo llenaste antes)
sudo bash instalar.sh "0 2 * * *"            # todos los días a las 02:00 (hora del servidor)
```

El nombre del contenedor sale de `docker ps --format '{{.Names}}'`. Para cambiar la configuración después,
edita el `.env` del proyecto y vuelve a ejecutar `instalar.sh`.

### 3. Primera prueba manual

```bash
sudo /opt/respaldo-postgres/respaldo.sh
ls -lh /var/backups/postgres
sudo rclone ls gdrive:Respaldos/mi_base
```

Al día siguiente revisa `/var/log/respaldo-postgres.log`.

## Restaurar

```bash
# Bajar un respaldo desde Drive (si ya no está en local)
sudo rclone copy gdrive:Respaldos/mi_base/mi_base_20261113_020000.dump /tmp/

# Restaurar en una base nueva para revisarla
docker exec <contenedor> createdb -U postgres mi_base_restaurada
docker exec -i <contenedor> pg_restore -U postgres -d mi_base_restaurada --no-owner < /tmp/mi_base_20261113_020000.dump
```

Para reemplazar la base original, añade `--clean --if-exists` y apunta `-d` a la base real.
**Hazlo primero en una base de prueba.**

## Notas

- La imagen oficial de Postgres no pide contraseña por socket local, así que `DB_PASSWORD` normalmente va vacío.
- Con una cuenta de servicio de Google en lugar de OAuth, usa una **Unidad compartida**: las cuentas de servicio no
  tienen cuota propia en "Mi unidad".
- El log no se rota solo. Si crece mucho, añade una regla en `/etc/logrotate.d/`.
