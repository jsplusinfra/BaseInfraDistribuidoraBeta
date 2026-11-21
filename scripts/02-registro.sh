#!/usr/bin/env bash
# Conecta Docker del servidor con GitHub Container Registry (ghcr.io) para poder
# descargar las imágenes privadas. Correr una vez, como el usuario de despliegue:
#   bash scripts/02-registro.sh
#
# Usa un token CLÁSICO de GitHub con un único permiso: read:packages.
# (github.com → Settings → Developer settings → Personal access tokens → Tokens (classic))
# Con ese token solo se pueden DESCARGAR imágenes: no da acceso al código ni a publicar.
set -euo pipefail
cd "$(dirname "$0")/.."

REGISTRY="ghcr.io/jsplusinfra"
[[ -f .env ]] && REGISTRY="$(grep -E '^REGISTRY=' .env | cut -d= -f2- || true)"
REGISTRY="${REGISTRY:-ghcr.io/jsplusinfra}"
BACKEND_IMAGE="baseback"; FRONTEND_IMAGE="basefront"
if [[ -f .env ]]; then
  BACKEND_IMAGE="$(grep -E '^BACKEND_IMAGE=.' .env | cut -d= -f2- || echo baseback)"; BACKEND_IMAGE="${BACKEND_IMAGE:-baseback}"
  FRONTEND_IMAGE="$(grep -E '^FRONTEND_IMAGE=.' .env | cut -d= -f2- || echo basefront)"; FRONTEND_IMAGE="${FRONTEND_IMAGE:-basefront}"
fi

read -rp  "Usuario de GitHub dueño del token: " USUARIO
read -rsp "Token (read:packages, no se muestra): " TOKEN; echo
[[ -n $USUARIO && -n $TOKEN ]] || { echo "Faltan datos."; exit 1; }

printf '%s' "$TOKEN" | docker login ghcr.io -u "$USUARIO" --password-stdin
unset TOKEN
chmod 600 ~/.docker/config.json 2>/dev/null || true

echo "==> Probando acceso a las imágenes"
for img in "$BACKEND_IMAGE" "$FRONTEND_IMAGE"; do
  if docker manifest inspect "$REGISTRY/$img:master" >/dev/null 2>&1; then
    echo "   $img: OK"
  else
    echo "   $img: no se pudo leer $REGISTRY/$img:master (¿se publicó alguna vez? ¿el token tiene read:packages y acceso a la organización?)"
  fi
done
echo "Listo. Siguiente paso: bash scripts/generar-env.sh"
