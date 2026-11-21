#!/usr/bin/env bash
# Instala el sitio en nginx y obtiene el certificado de Let's Encrypt.
#   sudo bash scripts/03-ssl.sh
# Requisito: el registro DNS A de $DOMAIN ya apunta a la IP del droplet.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $EUID -eq 0 ]] || { echo "Correr con sudo"; exit 1; }

set -a; source .env; set +a
: "${DOMAIN:?Falta DOMAIN en .env}"
: "${CERTBOT_EMAIL:?Falta CERTBOT_EMAIL en .env}"

SITE=/etc/nginx/sites-available/sistema.conf
ln -sf "$SITE" /etc/nginx/sites-enabled/sistema.conf
install -m 644 nginx/conf.d/00-hardening.conf /etc/nginx/conf.d/00-hardening.conf
install -m 644 nginx/snippets/*.conf /etc/nginx/snippets/
install -d -m 755 /var/www/certbot

# Comprobar DNS antes de pedir el certificado (Let's Encrypt limita los intentos fallidos)
IP_PUBLICA=$(curl -4 -fsS https://ifconfig.me || true)
IP_DNS=$(getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}' || true)
if [[ -n $IP_PUBLICA && $IP_PUBLICA != "$IP_DNS" ]]; then
  echo "!! $DOMAIN resuelve a '${IP_DNS:-nada}' pero este servidor es $IP_PUBLICA."
  echo "!! Corregí el registro A en el DNS y esperá a que propague."
  exit 1
fi

if [[ ! -f /etc/letsencrypt/live/$DOMAIN/fullchain.pem ]]; then
  echo "==> Etapa 1: sitio HTTP para el desafío ACME"
  envsubst '${DOMAIN}' < nginx/sites/sistema-http.conf.template > "$SITE"
  nginx -t && systemctl reload nginx

  echo "==> Pidiendo certificado para $DOMAIN"
  certbot certonly --webroot -w /var/www/certbot -d "$DOMAIN" \
    --email "$CERTBOT_EMAIL" --agree-tos --no-eff-email --non-interactive
fi

echo "==> Etapa 2: sitio HTTPS definitivo"
envsubst '${DOMAIN}' < nginx/sites/sistema.conf.template > "$SITE"
nginx -t && systemctl reload nginx

# Renovación automática: el paquete certbot trae un timer de systemd.
# Este hook recarga nginx cada vez que se renueva el certificado.
install -d /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/bin/sh
systemctl reload nginx
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
systemctl enable --now certbot.timer

echo "==> Probando renovación (simulada)"
certbot renew --dry-run

systemctl restart fail2ban
echo "Listo: https://$DOMAIN"
