#!/usr/bin/env bash
# Despliega (o actualiza) el sistema DESCARGANDO las imágenes que publica GitHub Actions.
# En el servidor no se construye nada. Correr como el usuario de despliegue:
#
#   bash scripts/deploy.sh v1.2.0 v1.4.0    # versión del backend y del frontend
#   bash scripts/deploy.sh                  # vuelve a desplegar las versiones que dice .env
#
# Pasos: verifica que existan las imágenes, las descarga, hace un backup, corre las
# migraciones, levanta backend y frontend y comprueba que respondan.
# Para volver a la versión anterior: bash scripts/revertir.sh
set -euo pipefail
cd "$(dirname "$0")/.."

uso() { sed -n '2,8p' "$0"; exit 1; }
[[ $# -eq 0 || $# -eq 2 ]] || uso
[[ -f .env ]] || { echo "Falta .env (bash scripts/generar-env.sh)"; exit 1; }
set -a; source .env; set +a

REGISTRY="${REGISTRY:-ghcr.io/jsplusinfra}"
ANTERIOR_BACK="${BACKEND_TAG:-}"
ANTERIOR_FRONT="${FRONTEND_TAG:-}"
NUEVO_BACK="${1:-$ANTERIOR_BACK}"
NUEVO_FRONT="${2:-$ANTERIOR_FRONT}"
[[ -n $NUEVO_BACK && -n $NUEVO_FRONT ]] || { echo "No hay versiones en .env: indicalas."; uso; }

# Escribe (o agrega) una variable en .env sin tocar el resto del archivo.
poner_en_env() {
  if grep -q "^$1=" .env; then sed -i "s|^$1=.*|$1=$2|" .env; else echo "$1=$2" >> .env; fi
}

for v in "$NUEVO_BACK" "$NUEVO_FRONT"; do
  [[ $v == master || $v == sha-* ]] && echo "!! '$v' no es una versión fija: usala solo para probar."
done

echo "==> Versiones: backend $ANTERIOR_BACK -> $NUEVO_BACK | frontend $ANTERIOR_FRONT -> $NUEVO_FRONT"

if [[ ! -f secrets/afip/AFIP.crt || ! -f secrets/afip/privada.key ]]; then
  echo "!! No están secrets/afip/AFIP.crt y secrets/afip/privada.key: la facturación electrónica quedará deshabilitada."
fi

# A partir de acá, docker compose usa las versiones nuevas.
export BACKEND_TAG="$NUEVO_BACK" FRONTEND_TAG="$NUEVO_FRONT"

# Si una versión no existe, falla acá, antes de tocar nada de lo que está corriendo.
echo "==> Descargando imágenes de $REGISTRY"
if ! docker compose pull backend frontend; then
  echo "!! No se pudieron descargar ${BACKEND_IMAGE:-baseback}:$NUEVO_BACK / ${FRONTEND_IMAGE:-basefront}:$NUEVO_FRONT."
  echo "   ¿Existe el tag y terminó el workflow en GitHub Actions? ¿Hiciste docker login? (bash scripts/02-registro.sh)"
  exit 1
fi

echo "==> Base de datos"
docker compose up -d --wait db

echo "==> Backup antes de migrar (las migraciones pueden borrar o transformar datos)"
bash scripts/backup.sh

echo "==> Migraciones"
docker compose --profile tools run --rm migrate

# Recién ahora se registran las versiones: si algo falló antes, .env sigue como estaba.
if [[ -n $ANTERIOR_BACK && ( $ANTERIOR_BACK != "$NUEVO_BACK" || $ANTERIOR_FRONT != "$NUEVO_FRONT" ) ]]; then
  printf 'BACKEND_TAG=%s\nFRONTEND_TAG=%s\n' "$ANTERIOR_BACK" "$ANTERIOR_FRONT" > .deploy-anterior
fi
poner_en_env BACKEND_TAG "$NUEVO_BACK"
poner_en_env FRONTEND_TAG "$NUEVO_FRONT"

echo "==> Levantando backend y frontend"
docker compose up -d --remove-orphans backend frontend

echo "==> Esperando que respondan"
for i in $(seq 1 40); do
  front=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/ || true)
  # Un POST vacío al login devuelve 400: alcanza para saber que la API está viva.
  back=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{}' \
         http://127.0.0.1:3000/api/auth/login || true)
  if [[ $front == 200 && $back =~ ^[1-4] ]]; then echo "OK"; break; fi
  if [[ $i -eq 40 ]]; then
    echo "!! No respondieron (frontend: $front, backend: $back). Ver: docker compose logs --tail=100 backend"
    [[ -f .deploy-anterior ]] && echo "   Para volver a la versión anterior: bash scripts/revertir.sh"
    exit 1
  fi
  sleep 3
done

# Solo borra capas huérfanas: las versiones anteriores quedan para un rollback rápido.
docker image prune -f >/dev/null
docker compose ps
echo "Deploy terminado: backend $NUEVO_BACK, frontend $NUEVO_FRONT"
