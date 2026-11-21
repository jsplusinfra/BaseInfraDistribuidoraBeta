# Probar BaseInfra

Casi todo lo de este repo se puede probar **en tu PC, sin un servidor**. Esta página dice cómo, y qué solo se puede probar en un droplet.

Los comandos se corrieron sobre `master` el 04/11/2026.

## Los chequeos rápidos

Corrélos antes de abrir un PR que toque este repo.

```bash
cd ~/Escritorio/DESPLIEGUE/BaseInfra

# 1) sintaxis de todos los scripts
for f in scripts/*.sh; do bash -n "$f" && echo "OK  $f" || echo "FALLA  $f"; done

# 2) shellcheck (en un contenedor: no hace falta instalarlo)
docker run --rm -v "$PWD":/mnt koalaman/shellcheck:stable -S warning scripts/*.sh

# 3) el compose es válido (con un .env de prueba y con todos los perfiles)
[ -f .env ] || bash scripts/generar-env.sh
docker compose config -q
docker compose --profile tools --profile metabase --profile admin config -q
```

- El `shellcheck` sin salida significa que no encontró advertencias.
- `docker compose config -q` falla con un mensaje claro si falta una variable obligatoria (las que usan `${VAR:?...}`).

## nginx: la plantilla renderizada

`nginx -t` valida la plantilla sin un servidor, con un certificado autofirmado:

```bash
mkdir -p /tmp/n/confd /tmp/n/cert
DOMAIN=prueba.local envsubst '${DOMAIN}' < nginx/sites/sistema.conf.template \
  > /tmp/n/confd/sistema.conf
cp nginx/conf.d/00-hardening.conf /tmp/n/confd/
openssl req -x509 -nodes -newkey rsa:2048 -days 1 -subj /CN=prueba.local \
  -keyout /tmp/n/cert/privkey.pem -out /tmp/n/cert/fullchain.pem
docker run --rm -v /tmp/n/confd:/etc/nginx/conf.d:ro \
  -v /tmp/n/cert:/etc/letsencrypt/live/prueba.local:ro \
  -v "$PWD/nginx/snippets":/etc/nginx/snippets:ro nginx:1.27-alpine nginx -t
```

Tiene que terminar con `configuration file /etc/nginx/nginx.conf test is successful`.

Cuando el cambio es de **reglas** (qué rutas se bloquean, qué headers salen), conviene probarlas de verdad: levantar un nginx con la plantilla, apuntarlo a un servicio de prueba y pedir las rutas con `curl -I`. Así se verificó, por ejemplo, que `/metabase/` responda 404 y que los archivos con hash lleven `Cache-Control` de un año.

## El sistema completo en tu PC

Con `docker-compose.local.yml` se levanta backend, frontend, base y un nginx local en `http://localhost:8000`. Los pasos están en [flujo-de-trabajo.md](flujo-de-trabajo.md#33-nivel-c-las-imágenes-de-producción-en-tu-pc).

Resultado esperado, con `master` y el dump corregido:

| Pedido | Respuesta | Qué significa |
|---|---|---|
| `GET /` | 200 | El frontend se sirve |
| `GET /admin/estadisticas-ventas` | 200 | Las rutas de la SPA funcionan |
| `POST /api/auth/login` con `{}` | 400 | La API está viva |
| `GET /api/estadisticas/tablero/ventas` | 401 | Pide sesión |
| `GET /api/empresa` | La empresa del dump | La base está cargada |

## Cada script

| Script | Cómo se prueba |
|---|---|
| `generar-env.sh` | Correrlo en una carpeta limpia: crea el `.env` con permisos 600 y contraseñas distintas cada vez; no pisa un `.env` existente |
| `generar-cloud-init.sh` | `SALIDA=/tmp/ci.sh bash scripts/generar-cloud-init.sh` y `bash -n /tmp/ci.sh`. El script generado se puede ejecutar en un contenedor `ubuntu:24.04` con la preparación reemplazada por un comando que solo liste lo que extrajo |
| `restaurar-db.sh` | Con el stack local levantado y un dump chico. Pide escribir `SI` en mayúsculas |
| `deploy.sh`, `revertir.sh` | Solo en un servidor: descargan del registro. En local se usa `docker compose` directo |
| `backup.sh` | Está pensado para el servidor: guarda los archivos subidos desde el volumen `sistema_uploads`, que solo existe con el nombre de proyecto `sistema` (no con `prueba-local`). En local, probar el `mysqldump` a mano |
| `backup-externo.sh` | Con `rclone` apuntando a una **carpeta local** como destino y una clave de `age` de prueba (`age-keygen`). Se descifra con `age -d -i clave.key archivo.age`. Contra Backblaze real todavía no se probó |
| `metabase-usuario.sh` | Con la base local levantada: correrlo dos veces seguidas (se puede repetir) y comprobar que `metabase_ro` lee pero no puede crear tablas |

## Lo que solo se prueba en un servidor

systemd (`ssh.socket`, `certbot.timer`, fail2ban), UFW y el primer arranque con cloud-init no se pueden reproducir en un contenedor. Para eso hay que usar **un droplet descartable** (o el VPS de testing):

1. `bash scripts/generar-cloud-init.sh` y pegar el resultado en *Startup scripts*.
2. Entrar como el usuario de despliegue y mirar `cat /var/log/preparacion-servidor.estado`: tiene que decir `OK`.
3. Seguir la guía de despliegue y comprobar el sistema por HTTPS.

Cuando el cambio es de nginx, además: `sudo bash scripts/03-ssl.sh` en el servidor y pedir las rutas desde afuera.

## Antes de abrir un PR en este repo

- [ ] `bash -n` y `shellcheck` sin errores.
- [ ] `docker compose config -q` válido (con los perfiles).
- [ ] `nginx -t` pasa si tocaste las plantillas.
- [ ] Si agregaste una variable: está en `.env.example`, en el compose y en `generar-env.sh` si es un secreto.
- [ ] Probado en un droplet descartable si tocaste `01-preparar-servidor.sh` o `generar-cloud-init.sh`.
- [ ] La documentación que corresponde está actualizada (README, `docs/`).
