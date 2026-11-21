#!/usr/bin/env bash
# Vuelve a las versiones que estaban antes del último deploy (las guarda deploy.sh
# en .deploy-anterior).
#   bash scripts/revertir.sh
#
# OJO: las migraciones de base de datos NO se revierten solas. Si la versión nueva
# corrió una migración que cambió tablas, la versión anterior puede no funcionar con
# ellas. En ese caso: restaurar el backup que hizo deploy.sh antes de migrar
# (bash scripts/restaurar-db.sh backups/db-FECHA.sql.gz) o pedir ayuda.
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -f .deploy-anterior ]] || { echo "No hay versión anterior registrada (.deploy-anterior)."; exit 1; }
# shellcheck disable=SC1091
source .deploy-anterior
: "${BACKEND_TAG:?.deploy-anterior incompleto}" "${FRONTEND_TAG:?.deploy-anterior incompleto}"

echo "Se va a volver a: backend $BACKEND_TAG, frontend $FRONTEND_TAG"
echo "Las migraciones NO se revierten. Último backup: $(ls -t backups/db-*.sql.gz 2>/dev/null | head -1 || echo ninguno)"
read -rp "Escribí SI para continuar: " ok
[[ $ok == "SI" ]] || exit 1

exec bash scripts/deploy.sh "$BACKEND_TAG" "$FRONTEND_TAG"
