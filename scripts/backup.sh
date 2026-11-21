#!/usr/bin/env bash
# Backup de la base de datos y de los archivos subidos (uploads).
#   bash scripts/backup.sh
# Programado con cron (ver README). Guarda en BaseInfra/backups y borra los
# que tengan más de RETENCION_DIAS días.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

DIR="${BACKUP_DIR:-$PWD/backups}"
RETENCION_DIAS="${RETENCION_DIAS:-14}"
FECHA=$(date +%Y%m%d-%H%M)
mkdir -p "$DIR" && chmod 700 "$DIR"

echo "==> Dump de $DB_DATABASE"
docker compose exec -T -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" db \
  mysqldump -uroot --single-transaction --routines --triggers --events \
  --set-gtid-purged=OFF "$DB_DATABASE" | gzip > "$DIR/db-$FECHA.sql.gz.tmp"
mv "$DIR/db-$FECHA.sql.gz.tmp" "$DIR/db-$FECHA.sql.gz"

echo "==> Archivos subidos"
docker run --rm -v sistema_uploads:/data:ro -v "$DIR":/backup alpine \
  tar czf "/backup/uploads-$FECHA.tar.gz" -C /data .

find "$DIR" -name 'db-*.sql.gz' -mtime +"$RETENCION_DIAS" -delete
find "$DIR" -name 'uploads-*.tar.gz' -mtime +"$RETENCION_DIAS" -delete
ls -lh "$DIR" | tail -n 5
