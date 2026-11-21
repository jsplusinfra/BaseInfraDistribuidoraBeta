#!/usr/bin/env bash
# Crea (o actualiza) el usuario de SOLO LECTURA con el que Metabase consulta la base del
# sistema. La contraseña sale de METABASE_DB_PASSWORD en .env (la genera generar-env.sh).
#   bash scripts/metabase-usuario.sh
#
# Usa mysql_native_password porque el driver de Metabase no negocia caching_sha2_password
# sin SSL. Se puede correr las veces que haga falta.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

: "${METABASE_DB_PASSWORD:?Falta METABASE_DB_PASSWORD en .env. En un .env nuevo lo genera generar-env.sh; en uno viejo agregalo: echo \"METABASE_DB_PASSWORD=\$(openssl rand -hex 16)\" >> .env}"
[[ $METABASE_DB_PASSWORD =~ ^[A-Za-z0-9]+$ ]] || { echo "METABASE_DB_PASSWORD solo puede tener letras y números."; exit 1; }

docker compose up -d --wait db
# La contraseña va por stdin, no como argumento: así no aparece en la lista de procesos.
docker compose exec -T -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" db mysql -uroot <<SQL
CREATE USER IF NOT EXISTS 'metabase_ro'@'%' IDENTIFIED WITH mysql_native_password BY '${METABASE_DB_PASSWORD}';
ALTER USER 'metabase_ro'@'%' IDENTIFIED WITH mysql_native_password BY '${METABASE_DB_PASSWORD}';
GRANT SELECT ON \`${DB_DATABASE}\`.* TO 'metabase_ro'@'%';
FLUSH PRIVILEGES;
SQL

echo "Listo. Datos para conectar la base en Metabase (Admin → Bases de datos → Agregar → MySQL):"
echo "  Host: db   Puerto: 3306   Base: ${DB_DATABASE}   Usuario: metabase_ro"
echo "  Contraseña: la de METABASE_DB_PASSWORD (grep ^METABASE_DB_PASSWORD .env)"
