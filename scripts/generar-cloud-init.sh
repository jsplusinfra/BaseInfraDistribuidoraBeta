#!/usr/bin/env bash
# Genera el "startup script" (cloud-init / user data) para pegar al crear el droplet
# en DigitalOcean. El droplet se prepara solo en el primer arranque, igual que con
# 01-preparar-servidor.sh, y después se entra directo como el usuario de despliegue.
# Correr EN TU PC, desde el repo BaseInfra:
#   bash scripts/generar-cloud-init.sh            # usuario: el mismo que en tu PC ($USER)
#   DEPLOY_USER=deploy bash scripts/generar-cloud-init.sh
#
# Qué hace el texto generado, como root y sin intervención:
#   1. Crea el usuario con la contraseña de sudo ya cifrada (así 01 no pide passwd).
#   2. Le carga tu clave pública SSH.
#   3. Descomprime 01-preparar-servidor.sh, fail2ban/ y nginx/ tal como están en
#      origin/master (solo lo commiteado y pusheado, igual que el flujo manual).
#   4. Corre 01-preparar-servidor.sh. La salida queda en /var/log/cloud-init-output.log
#      y al final deja /var/log/preparacion-servidor.estado con OK o ERROR.
#
# El texto incluye el hash de la contraseña: se guarda con permisos 600 y conviene
# borrarlo después de crear el droplet.
set -euo pipefail
cd "$(dirname "$0")/.."

DEPLOY_USER="${DEPLOY_USER:-$USER}"
CLAVE_PUB="${CLAVE_PUB:-$HOME/.ssh/id_ed25519.pub}"
SALIDA="${SALIDA:-$HOME/cloud-init-servidor.sh}"

[[ $DEPLOY_USER =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "Nombre de usuario inválido: $DEPLOY_USER"; exit 1; }
[[ -s $CLAVE_PUB ]] || { echo "No existe la clave pública $CLAVE_PUB (creala con: ssh-keygen -t ed25519)"; exit 1; }
CLAVE="$(head -n1 "$CLAVE_PUB")"

echo "==> Trayendo BaseInfra de GitHub (origin/master)"
git fetch -q origin
ARCHIVOS=(scripts/01-preparar-servidor.sh fail2ban nginx)
PAQUETE="$(git archive origin/master "${ARCHIVOS[@]}" | gzip -9 | base64 -w0)"

echo "==> Contraseña de $DEPLOY_USER (se usa para sudo, no para entrar por SSH)"
while true; do
  read -rsp "Contraseña: " P1; echo
  read -rsp "Repetila:   " P2; echo
  [[ -n $P1 && $P1 == "$P2" ]] && break
  echo "No coinciden o está vacía. Probá de nuevo."
done
HASH="$(printf '%s' "$P1" | openssl passwd -6 -stdin)"
unset P1 P2

umask 077
cat > "$SALIDA" <<EOF
#!/bin/bash
# Generado por BaseInfra/scripts/generar-cloud-init.sh el $(date '+%Y-%m-%d %H:%M')
# BaseInfra: $(git rev-parse --short origin/master) (origin/master)
set -euo pipefail
ESTADO=/var/log/preparacion-servidor.estado
trap 'echo "ERROR (línea \$LINENO) \$(date)" > \$ESTADO' ERR
echo "EN CURSO \$(date)" > \$ESTADO

DEPLOY_USER='$DEPLOY_USER'
HASH='$HASH'
CLAVE='$CLAVE'

# En el primer arranque Ubuntu suele estar usando apt: esperar el lock en vez de fallar.
echo 'DPkg::Lock::Timeout "900";' > /etc/apt/apt.conf.d/99espera-lock

# Usuario de despliegue con contraseña de sudo (01-preparar-servidor.sh lo encuentra creado y no pide passwd)
if ! id "\$DEPLOY_USER" &>/dev/null; then
  useradd -m -s /bin/bash -G sudo -p "\$HASH" "\$DEPLOY_USER"
fi
install -d -m 700 -o "\$DEPLOY_USER" -g "\$DEPLOY_USER" "/home/\$DEPLOY_USER/.ssh"
AK="/home/\$DEPLOY_USER/.ssh/authorized_keys"
touch "\$AK"
grep -qxF "\$CLAVE" "\$AK" || echo "\$CLAVE" >> "\$AK"
chown "\$DEPLOY_USER:\$DEPLOY_USER" "\$AK"
chmod 600 "\$AK"

# Archivos de BaseInfra que necesita la preparación
install -d -m 700 /root/BaseInfra
echo '$PAQUETE' | base64 -d | tar -xz -C /root/BaseInfra

DEPLOY_USER="\$DEPLOY_USER" bash /root/BaseInfra/scripts/01-preparar-servidor.sh

rm -f /etc/apt/apt.conf.d/99espera-lock
echo "OK \$(date)" > \$ESTADO
EOF

bash -n "$SALIDA"
echo
echo "==> Listo: $SALIDA ($(wc -c < "$SALIDA") bytes, límite de DigitalOcean: 64 KB)"
if command -v wl-copy &>/dev/null && [[ -n ${WAYLAND_DISPLAY:-} ]]; then
  wl-copy < "$SALIDA" && echo "    Copiado al portapapeles."
elif command -v xclip &>/dev/null && [[ -n ${DISPLAY:-} ]]; then
  xclip -selection clipboard < "$SALIDA" && echo "    Copiado al portapapeles."
else
  echo "    Copialo con: cat $SALIDA"
fi
echo "    Pegalo en DigitalOcean → Create Droplet → Additional Options → Startup scripts."
echo "    Después de crear el droplet, borralo: rm $SALIDA"
