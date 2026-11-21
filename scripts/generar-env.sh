#!/usr/bin/env bash
# Crea .env a partir de .env.example con contraseñas y JWT_SECRET aleatorios.
# Después hay que completar a mano DOMAIN, CERTBOT_EMAIL, AFIP_*, EMAIL_*, etc.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -f .env ]]; then
  echo ".env ya existe, no se toca."; exit 1
fi

rand() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "$1"; }

sed -e "s|^MYSQL_ROOT_PASSWORD=.*|MYSQL_ROOT_PASSWORD=$(rand 32)|" \
    -e "s|^DB_PASSWORD=.*|DB_PASSWORD=$(rand 32)|" \
    -e "s|^JWT_SECRET=.*|JWT_SECRET=$(rand 64)|" \
    -e "s|^METABASE_DB_PASSWORD=.*|METABASE_DB_PASSWORD=$(rand 32)|" \
    .env.example > .env
chmod 600 .env
echo ".env creado (permisos 600). Editalo y completá los valores vacíos: nano .env"
