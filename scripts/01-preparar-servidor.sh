#!/usr/bin/env bash
# Prepara un droplet Ubuntu 24.04 recién creado. Correr UNA vez, como root:
#   bash scripts/01-preparar-servidor.sh
#
# Hace: actualizaciones, usuario "deploy", SSH endurecido, UFW, fail2ban,
# actualizaciones automáticas de seguridad, swap, sysctl, Docker, nginx y certbot.
set -euo pipefail

DEPLOY_USER="${DEPLOY_USER:-deploy}"
APP_DIR="${APP_DIR:-/opt/sistema}"
SWAP_SIZE="${SWAP_SIZE:-2G}"
TIMEZONE="${TIMEZONE:-America/Argentina/Buenos_Aires}"
INFRA_DIR="$(cd "$(dirname "$0")/.." && pwd)"

[[ $EUID -eq 0 ]] || { echo "Correr como root"; exit 1; }
log() { echo -e "\n\033[1;32m==> $*\033[0m"; }

log "Actualizando paquetes"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y upgrade
apt-get install -y ca-certificates curl gnupg git ufw fail2ban python3-systemd unattended-upgrades \
  nginx certbot gettext-base cron rclone age

log "Zona horaria: $TIMEZONE"
timedatectl set-timezone "$TIMEZONE"

# ---------- Usuario de despliegue ----------
if ! id "$DEPLOY_USER" &>/dev/null; then
  log "Creando usuario $DEPLOY_USER"
  adduser --disabled-password --gecos "" "$DEPLOY_USER"
  usermod -aG sudo "$DEPLOY_USER"
  echo "Elegí una contraseña para $DEPLOY_USER (se usa para sudo, no para SSH):"
  passwd "$DEPLOY_USER"
fi
install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"
if [[ -s /root/.ssh/authorized_keys && ! -s "/home/$DEPLOY_USER/.ssh/authorized_keys" ]]; then
  cp /root/.ssh/authorized_keys "/home/$DEPLOY_USER/.ssh/authorized_keys"
fi
chown "$DEPLOY_USER:$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh/authorized_keys" 2>/dev/null || true
chmod 600 "/home/$DEPLOY_USER/.ssh/authorized_keys" 2>/dev/null || true

# ---------- SSH ----------
if [[ -s "/home/$DEPLOY_USER/.ssh/authorized_keys" ]]; then
  log "Endureciendo SSH (sin root, sin contraseñas)"
  # Prefijo 00-: sshd usa el PRIMER valor que encuentra y DigitalOcean deja
  # 50-cloud-init.conf con PasswordAuthentication yes.
  cat > /etc/ssh/sshd_config.d/00-hardening.conf <<EOF
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowAgentForwarding no
AllowUsers $DEPLOY_USER
EOF
  # Ubuntu 24.04 activa sshd por socket: /run/sshd recién existe después de la primera
  # conexión, y sin esa carpeta `sshd -t` falla ("Missing privilege separation directory").
  install -d -m 0755 /run/sshd
  sshd -t
  # Ubuntu 24.04 activa sshd por socket (ssh.socket): hay que reiniciar los dos.
  systemctl daemon-reload
  systemctl restart ssh.socket 2>/dev/null || true
  systemctl restart ssh
  # Si SSH no quedó escuchando, se deshace el endurecimiento para no perder el acceso.
  for _ in $(seq 1 10); do ss -ltn | grep -qE ':22\s' && break; sleep 1; done
  if ! ss -ltn | grep -qE ':22\s'; then
    echo "!! SSH no quedó escuchando en el puerto 22: se revierte el endurecimiento."
    rm -f /etc/ssh/sshd_config.d/00-hardening.conf
    systemctl restart ssh.socket 2>/dev/null || true
    systemctl restart ssh
    systemctl status ssh ssh.socket --no-pager || true
    exit 1
  fi
else
  echo "!! $DEPLOY_USER no tiene clave SSH: NO se endurece SSH para no dejarte afuera."
  echo "!! Agregá tu clave pública en /home/$DEPLOY_USER/.ssh/authorized_keys y volvé a correr el script."
fi

# ---------- Firewall ----------
log "Configurando UFW (solo 22, 80, 443)"
ufw default deny incoming
ufw default allow outgoing
ufw limit OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# ---------- fail2ban ----------
log "Configurando fail2ban"
install -d -m 755 /var/log/nginx
touch /var/log/nginx/sistema.access.log /var/log/nginx/sistema.error.log
install -m 644 "$INFRA_DIR/fail2ban/jail.local" /etc/fail2ban/jail.local
systemctl enable --now fail2ban
systemctl restart fail2ban

# ---------- Actualizaciones automáticas ----------
log "Activando actualizaciones automáticas de seguridad"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
cat > /etc/apt/apt.conf.d/52unattended-upgrades-local <<EOF
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:30";
EOF
systemctl enable --now unattended-upgrades

# ---------- Swap ----------
if ! swapon --show | grep -q .; then
  log "Creando swap de $SWAP_SIZE"
  fallocate -l "$SWAP_SIZE" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo "/swapfile none swap sw 0 0" >> /etc/fstab
  echo "vm.swappiness=10" > /etc/sysctl.d/99-swap.conf
fi

# ---------- Kernel / red ----------
log "Aplicando sysctl de red"
cat > /etc/sysctl.d/99-hardening.conf <<EOF
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.log_martians = 1
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
EOF
sysctl --system >/dev/null

# ---------- Docker ----------
if ! command -v docker &>/dev/null; then
  log "Instalando Docker"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
cat > /etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "5" },
  "live-restore": true,
  "no-new-privileges": true
}
EOF
systemctl enable docker
systemctl restart docker
usermod -aG docker "$DEPLOY_USER"

# ---------- nginx ----------
log "Configurando nginx base"
rm -f /etc/nginx/sites-enabled/default
install -m 644 "$INFRA_DIR/nginx/conf.d/00-hardening.conf" /etc/nginx/conf.d/00-hardening.conf
install -m 644 "$INFRA_DIR"/nginx/snippets/*.conf /etc/nginx/snippets/
install -d -m 755 /var/www/certbot
nginx -t
systemctl enable nginx
systemctl reload nginx

# ---------- Carpeta de la app ----------
install -d -m 750 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$APP_DIR"

log "Listo. Siguiente paso: entrar como $DEPLOY_USER (ssh $DEPLOY_USER@<IP>) y seguir el README."
