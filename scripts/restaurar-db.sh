#!/usr/bin/env bash
# Restaura un dump SQL (.sql o .sql.gz) en la base de producción.
#   bash scripts/restaurar-db.sh backups/db-20261017-0300.sql.gz
# ATENCIÓN: pisa las tablas que existan en el dump.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

ARCHIVO="${1:?Uso: restaurar-db.sh <archivo.sql[.gz]>}"
[[ -f $ARCHIVO ]] || { echo "No existe $ARCHIVO"; exit 1; }

read -rp "Esto reemplaza datos de '$DB_DATABASE'. Escribí SI para continuar: " ok
[[ $ok == "SI" ]] || exit 1

docker compose up -d --wait db
if [[ $ARCHIVO == *.gz ]]; then LEER=(gunzip -c "$ARCHIVO"); else LEER=(cat "$ARCHIVO"); fi
"${LEER[@]}" | docker compose exec -T -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" db \
  mysql -uroot "$DB_DATABASE"
echo "Restaurado. Si el dump es de una versión anterior, corré: docker compose --profile tools run --rm migrate"
