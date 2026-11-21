#!/usr/bin/env bash
# Backup cifrado de la base y de los archivos subidos a un almacenamiento externo
# (Backblaze B2 vía rclone), SIN guardar nada en el disco del servidor:
#   mysqldump | gzip | age (cifra) | rclone rcat (sube)
#
#   bash scripts/backup-externo.sh
#
# Programado con cron una vez por día (ver README). Requiere:
#   - rclone y age instalados (sudo apt-get install -y rclone age)
#   - un remoto de rclone con una llave de B2 que solo puede ESCRIBIR (no borrar)
#   - en .env: BACKUP_REMOTO (ej. b2:sistema-backups/produccion) y
#     BACKUP_AGE_DESTINATARIO (la clave PÚBLICA de age, age1...)
#
# El servidor solo tiene la clave pública: puede cifrar pero no descifrar. La clave
# privada queda fuera del servidor. Los backups viejos los borra B2 con una regla de
# ciclo de vida, no este script (la llave del servidor no tiene permiso de borrado).
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

: "${BACKUP_REMOTO:?Falta BACKUP_REMOTO en .env (ej. b2:sistema-backups/produccion)}"
: "${BACKUP_AGE_DESTINATARIO:?Falta BACKUP_AGE_DESTINATARIO en .env (clave pública age1...)}"
command -v rclone >/dev/null || { echo "Falta rclone: sudo apt-get install -y rclone"; exit 1; }
command -v age    >/dev/null || { echo "Falta age: sudo apt-get install -y age"; exit 1; }

FECHA=$(date +%Y%m%d-%H%M)
DESTINO="${BACKUP_REMOTO%/}/$(hostname)"
cifrar() { age -r "$BACKUP_AGE_DESTINATARIO"; }

echo "==> $(date '+%F %T') Base $DB_DATABASE → $DESTINO/db/db-$FECHA.sql.gz.age"
docker compose exec -T -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" db \
  mysqldump -uroot --single-transaction --routines --triggers --events \
  --set-gtid-purged=OFF "$DB_DATABASE" \
  | gzip | cifrar | rclone rcat "$DESTINO/db/db-$FECHA.sql.gz.age"

echo "==> $(date '+%F %T') Archivos subidos → $DESTINO/uploads/uploads-$FECHA.tar.gz.age"
docker run --rm -v sistema_uploads:/data:ro alpine tar czf - -C /data . \
  | cifrar | rclone rcat "$DESTINO/uploads/uploads-$FECHA.tar.gz.age"

echo "==> $(date '+%F %T') Subidos:"
rclone lsl --include "*-$FECHA.*" "$DESTINO" 2>/dev/null \
  || echo "   (la llave no permite listar: verificalo desde tu PC con rclone lsl)"
echo "==> Listo"
