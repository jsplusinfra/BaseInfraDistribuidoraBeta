# BaseInfra

Infraestructura para desplegar el sistema (BaseBack + BaseFront) en un VPS (probado en un droplet de DigitalOcean con Ubuntu 24.04) con Docker, nginx, Let's Encrypt y el servidor endurecido.

**El servidor no construye nada.** GitHub Actions arma las imágenes de backend y frontend cuando se crea un tag de versión y las publica en GitHub Container Registry (ghcr.io). El VPS solo las descarga y las arranca. En el servidor vive únicamente este repo.

| Documento | Para qué |
|---|---|
| Este README | Arquitectura y paso a paso para un servidor nuevo |
| [docs/publicar-version.md](docs/publicar-version.md) | Cómo sacar una versión nueva, de la PR al deploy |
| [docs/operacion.md](docs/operacion.md) | Deploy, rollback, migraciones, backups y qué hacer si algo falla |
| [docs/flujo-de-trabajo.md](docs/flujo-de-trabajo.md) | Del código al servidor: pruebas en local, VPS de testing y producción, qué repo se toca según el cambio |
| [docs/los-tres-repos.md](docs/los-tres-repos.md) | Qué tiene BaseBack, BaseFront y BaseInfra, y por qué se armó así cada uno |
| [docs/repos-tablero.md](docs/repos-tablero.md) | La línea nueva del sistema (repos Tablero*): imágenes, variables nuevas, tableros propios y avisos para desplegarla |
| [docs/pruebas.md](docs/pruebas.md) | Cómo probar este repo sin un servidor, y qué solo se prueba en un droplet |
| [docs/decisiones.md](docs/decisiones.md) | Por qué se despliega así y qué alternativas se descartaron |

## Arquitectura

```
  BaseBack ──tag v1.2.0──► GitHub Actions ──► ghcr.io/jsplusinfra/baseback:v1.2.0  ─┐
  BaseFront ─tag v1.4.0──► GitHub Actions ──► ghcr.io/jsplusinfra/basefront:v1.4.0 ─┤  (privadas)
                                                                                     │ docker pull
                                                                                     ▼  (token de solo lectura)
Internet ──► Firewall del proveedor (22, 80, 443)                                  VPS
              │
              ▼
         UFW + fail2ban
              │
     nginx del servidor (TLS, headers, rate limit, bloqueos)
       │                          │
   /api/*                       /*
       ▼                          ▼
 127.0.0.1:3000             127.0.0.1:8080
 backend (NestJS)           frontend (nginx + build de Vite)
       │
       ▼
   MySQL 8 (solo red interna de Docker, sin puerto expuesto)
```

- Frontend y API en **el mismo dominio**: `https://dominio/` y `https://dominio/api`. No hace falta CORS ni un segundo certificado.
- Los contenedores publican puertos **solo en 127.0.0.1**. Docker se saltea UFW cuando publica en `0.0.0.0`, por eso nunca se usa.
- Las migraciones las corre la misma imagen del backend (servicio `migrate`), antes de levantar la versión nueva.
- phpMyAdmin y Metabase son opcionales y se acceden **solo por túnel SSH**.

En el servidor queda así:

```
/opt/sistema/
└── BaseInfra/          ← único repo (+ .env y secrets/ que NO se suben a git)
    └── backups/        ← backup que hace deploy.sh antes de migrar (14 días)
```

Y los volúmenes de Docker: `sistema_db_data` (la base), `sistema_uploads` (archivos subidos).

## Qué hay en este repo

| Ruta | Para qué |
|---|---|
| `docker-compose.yml` | MySQL, backend, frontend, migraciones y herramientas opcionales. Las imágenes salen de `REGISTRY` + `BACKEND_TAG` / `FRONTEND_TAG` del `.env` |
| `docker-compose.build.yml` | Override opcional para construir las imágenes desde los repos vecinos (pruebas locales o plan B) |
| `nginx/` | Sitio, TLS, headers de seguridad y rate limiting del nginx del servidor |
| `fail2ban/jail.local` | Bloqueos por fuerza bruta en SSH y login, y de bots |
| `mysql/conf.d/` | Ajustes de MySQL para un servidor chico |
| `scripts/01-preparar-servidor.sh` | Deja el servidor listo y seguro (se corre una vez) |
| `scripts/generar-cloud-init.sh` | Genera el *startup script* para que el droplet se prepare solo al crearlo (opción rápida del paso 1) |
| `scripts/02-registro.sh` | `docker login` en ghcr.io con un token de solo lectura (una vez) |
| `scripts/generar-env.sh` | Crea `.env` con contraseñas aleatorias |
| `scripts/metabase-usuario.sh` | Crea el usuario de solo lectura de Metabase en la base (estadísticas) |
| `scripts/03-ssl.sh` | Instala el sitio en nginx y obtiene el certificado |
| `scripts/deploy.sh` | Descarga las versiones indicadas, hace backup, migra y levanta todo |
| `scripts/revertir.sh` | Vuelve a las versiones anteriores al último deploy |
| `scripts/backup.sh` / `restaurar-db.sh` | Backup local (lo usa `deploy.sh` antes de migrar) y restauración |
| `scripts/backup-externo.sh` | Backup diario cifrado de la base y de uploads a Backblaze B2, sin pasar por el disco |

Los Dockerfiles **no están acá**: cada repo tiene el suyo (`BaseBack/distribuidora-bv/Dockerfile`, `BaseFront/Dockerfile`) junto con el workflow que lo publica.

---

## Paso a paso: servidor nuevo

### 0. Requisitos

1. **Imágenes publicadas.** BaseBack y BaseFront tienen que tener al menos un tag de versión con el workflow en verde (ver [docs/publicar-version.md](docs/publicar-version.md)). Los paquetes aparecen en el perfil de GitHub (`github.com/jsplusinfra?tab=packages`; es una cuenta personal, no una organización).
2. **Token de solo lectura** para descargar las imágenes: github.com → Settings → Developer settings → Personal access tokens → **Tokens (classic)** → permiso **únicamente `read:packages`**. Si la organización usa SSO, autorizalo para `jsplusinfra`.
3. **VPS**: Ubuntu **24.04 LTS**. Como ya no se compila en el servidor, **1 GB de RAM alcanza** (2 GB si vas a usar Metabase). Autenticación por **clave SSH**.
4. **Firewall del proveedor** (en DigitalOcean: Networking → Firewalls): inbound solo `22`, `80` y `443`.
5. **DNS**: registro **A** `sistema.tudominio.com` → IP del servidor. Sin dominio propio sirve `IP-CON-GUIONES.sslip.io` (por ejemplo `178-128-228-5.sslip.io`), que ya resuelve a esa IP.

### 1. Preparar el servidor (como root, una sola vez)

**Opción rápida (DigitalOcean o cualquier proveedor con cloud-init / user data).** El droplet se prepara solo en el primer arranque y nunca se entra como root. En tu máquina, antes de crear el droplet:

```bash
bash BaseInfra/scripts/generar-cloud-init.sh   # pide la contraseña de sudo y copia el script al portapapeles
```

Pegalo en *Create Droplet → Additional Options → Startup scripts* y creá el droplet. Unos 5 minutos después:

```bash
ssh $USER@IP
cat /var/log/preparacion-servidor.estado        # OK = terminó bien; EN CURSO: sudo cloud-init status --wait
rm ~/cloud-init-servidor.sh                     # en tu máquina: tiene el hash de la contraseña
```

El script generado crea el usuario (por defecto, el mismo nombre que en tu máquina; se cambia con `DEPLOY_USER=...`) con esa contraseña y tu clave SSH, lleva adentro los archivos de este repo que hacen falta (de `origin/master`) y corre `01-preparar-servidor.sh`. Si falla, el estado dice `ERROR` y el detalle está en `sudo tail -60 /var/log/cloud-init-output.log`. Con esta opción, saltá al paso 2.

**Opción manual.** Desde tu máquina, mandá este repo (solo lo commiteado, nunca tu `.env`):

```bash
git -C BaseInfra archive HEAD | ssh root@IP 'mkdir -p /root/BaseInfra && tar -x -C /root/BaseInfra'
ssh root@IP
tmux new -s prep
DEPLOY_USER=deploy bash /root/BaseInfra/scripts/01-preparar-servidor.sh
```

Crea el usuario de despliegue (`DEPLOY_USER`, por defecto `deploy`; te pide una contraseña para `sudo`), copia tu clave SSH, **desactiva el login de root y por contraseña**, y configura UFW, fail2ban, actualizaciones automáticas, swap, Docker, nginx y certbot. Correlo dentro de `tmux`: si se corta SSH, el script sigue (`tmux attach -t prep` para volver).

> **Antes de cerrar la sesión de root**, abrí otra terminal y probá `ssh deploy@IP`. Si entra, ya podés salir.

### 2. Traer BaseInfra (como deploy)

Con una deploy key de **solo lectura** de este repo:

```bash
ssh deploy@IP
ssh-keygen -t ed25519 -N "" -C "deploy-$(hostname)-BaseInfra" -f ~/.ssh/deploy_baseinfra
cat ~/.ssh/deploy_baseinfra.pub   # → GitHub: BaseInfra → Settings → Deploy keys → Add (SIN write access)
ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts
GIT_SSH_COMMAND="ssh -i ~/.ssh/deploy_baseinfra -o IdentitiesOnly=yes" \
  git clone git@github.com:jsplusinfra/BaseInfra.git /opt/sistema/BaseInfra
git -C /opt/sistema/BaseInfra config core.sshCommand "ssh -i ~/.ssh/deploy_baseinfra -o IdentitiesOnly=yes"
```

Alternativa sin deploy key: el mismo `git archive ... | ssh deploy@IP 'mkdir -p /opt/sistema/BaseInfra && tar -x -C /opt/sistema/BaseInfra'` del paso 1.

### 3. Acceso al registro de imágenes

```bash
cd /opt/sistema/BaseInfra
bash scripts/02-registro.sh
```

Pide tu usuario de GitHub y el token `read:packages`, hace `docker login ghcr.io` y prueba que se puedan leer las dos imágenes.

### 4. Configuración y secretos

```bash
bash scripts/generar-env.sh
nano .env
```

Completá: `DOMAIN`, `CERTBOT_EMAIL`, `GOOGLE_CLIENT_ID`, `EMAIL_USER`, `EMAIL_PASS`, `AFIP_CUIT` (y opcionalmente `AFIP_PUNTO_VENTA`, `AFIP_LETRA_EMISOR=C` si el emisor es monotributista). Las contraseñas de MySQL y el `JWT_SECRET` ya se generaron. `BACKEND_TAG` y `FRONTEND_TAG` los completa `deploy.sh`.

> **No pegues el `.env-temp` del backend acá.** Son formatos distintos: este `.env` configura todo el stack (MySQL, dominio, versiones) y el compose arma con él las variables del backend.

Certificado de AFIP (desde tu máquina):

```bash
scp AFIP.crt      deploy@IP:/opt/sistema/BaseInfra/secrets/afip/AFIP.crt
scp clave_privada deploy@IP:/opt/sistema/BaseInfra/secrets/afip/privada.key
```

En el servidor:

```bash
chmod 700 secrets/afip && chmod 600 secrets/afip/*
sudo chown 1000:1000 secrets/afip/*    # el backend corre como uid 1000 dentro del contenedor
```

El certificado tiene que ser del mismo ambiente que `AFIP_ENV`: uno de homologación (emitido por *Computadores Test*) no sirve en producción y viceversa (`cms.cert.untrusted`).

### 5. Primer deploy

```bash
bash scripts/deploy.sh v1.0.0 v1.0.0     # versión del backend y del frontend
```

Descarga las imágenes, levanta MySQL, hace un backup, corre las migraciones y levanta backend y frontend. Con la base vacía tarda 1 o 2 minutos (las 50 migraciones); las actualizaciones siguientes, segundos.

**Datos iniciales**, una de dos:

- **Dump existente**: ver [docs/operacion.md → Cargar un dump](docs/operacion.md#cargar-un-dump). Ojo con la migración con espacio en el nombre.
- **Base vacía**: los seeds están bloqueados desde internet; corrélos desde el propio servidor y **cambiá enseguida** las contraseñas que crean (están escritas en el código de BaseBack):

  ```bash
  curl http://127.0.0.1:3000/api/seed-all/execute
  ```

### 6. HTTPS

```bash
sudo bash scripts/03-ssl.sh
```

Verifica que el DNS apunte al servidor, obtiene el certificado por webroot, instala el sitio definitivo y deja configurada la renovación automática (`certbot.timer` + recarga de nginx). Al final hace un `certbot renew --dry-run`.

Listo: `https://sistema.tudominio.com`. Agregá esa URL en *Authorized JavaScript origins* del Client ID de Google para que funcione el login con Google.

### 7. Backups externos (regla 3-2-1)

Los backups **no se guardan en el servidor**: si se pierde el servidor se perderían con él, y quien entre podría borrarlos o leerlos. Solo queda local el que hace `deploy.sh` antes de migrar, para volver atrás.

1. **Backups de DigitalOcean**: droplet → *Backups* → *Enable backups* (diarios o semanales). Imagen completa del servidor, en la misma cuenta.
2. **Backup diario cifrado en Backblaze B2** (otra empresa): `scripts/backup-externo.sh` hace `mysqldump | gzip | age | rclone rcat`, sin escribir en disco.
   - Bucket privado con *Object Lock* y regla de ciclo de vida (ocultar a los 30 días, borrar 1 día después).
   - En el servidor, una llave de B2 **Write Only** (no puede borrar) y solo la clave **pública** de `age` (puede cifrar, no descifrar). La clave privada y una llave *Read Only* quedan en tu máquina y en el gestor de contraseñas.

```bash
sudo apt-get install -y rclone age               # ya incluidos en 01-preparar-servidor.sh
 rclone config create b2 b2 account=KEY_ID key=APPLICATION_KEY hard_delete=false
# .env: BACKUP_REMOTO=b2:BUCKET/produccion  y  BACKUP_AGE_DESTINATARIO=age1...
bash scripts/backup-externo.sh                   # probar
crontab -e                                       # 30 3 * * * bash /opt/sistema/BaseInfra/scripts/backup-externo.sh >> ~/backup.log 2>&1
```

Restaurar (en tu máquina): `rclone copy` del archivo, `age -d -i clave.key db-FECHA.sql.gz.age | gunzip > dump.sql` y seguir la restauración de [docs/operacion.md](docs/operacion.md). Probalo una vez por mes.

---

### 8. Estadísticas con Metabase (opcional, VPS de 2 GB o más)

El sistema muestra tableros de Metabase embebidos (*static embedding*): el backend firma la URL con `METABASE_SECRET_KEY` y el front la muestra en un iframe. Desde internet **solo** se publica el tablero embebido (`/metabase/embed/`, sus archivos y su API); el login y la administración de Metabase responden 404 y se usan **por túnel SSH**.

```bash
bash scripts/metabase-usuario.sh                    # usuario de solo lectura (metabase_ro)
docker compose --profile metabase up -d metabase    # ~1 GB de RAM
# en tu máquina: ssh -L 3002:127.0.0.1:3002 usuario@IP  →  http://localhost:3002
```

En Metabase (por el túnel): crear el admin, agregar la base (host `db`, base del `.env`, usuario `metabase_ro`), armar el tablero, activar **Admin → Embedding → Static embedding** y en el tablero **Compartir → Embed → Publish**. Copiar al `.env` `METABASE_SECRET_KEY` y `METABASE_DASHBOARD_VENTAS` (el número de la URL del tablero) y aplicar con `bash scripts/deploy.sh`.

---

## Operación diaria

Todo en `/opt/sistema/BaseInfra`, como el usuario de despliegue. Detalle en [docs/operacion.md](docs/operacion.md).

| Tarea | Comando |
|---|---|
| Desplegar versiones nuevas | `bash scripts/deploy.sh v1.3.0 v1.5.0` |
| Volver a la versión anterior | `bash scripts/revertir.sh` |
| Redesplegar lo mismo (p. ej. tras cambiar `.env`) | `bash scripts/deploy.sh` |
| Qué versión está corriendo | `grep _TAG .env` |
| Estado | `docker compose ps` |
| Logs del backend | `docker compose logs -f --tail=200 backend` |
| Correr migraciones a mano | `docker compose --profile tools run --rm migrate` |
| Consola MySQL | `docker compose exec db mysql -uroot -p` |
| Backup externo manual | `bash scripts/backup-externo.sh` |
| Actualizar este repo | `git pull` |
| IPs bloqueadas | `sudo fail2ban-client status nginx-limit-req` |
| Desbloquear IP | `sudo fail2ban-client unban 1.2.3.4` |

### Herramientas por túnel SSH

```bash
# en el servidor
docker compose --profile admin up -d phpmyadmin
docker compose --profile metabase up -d metabase

# en tu máquina
ssh -L 8081:127.0.0.1:8081 -L 3002:127.0.0.1:3002 -L 3000:127.0.0.1:3000 deploy@IP
```

Con el túnel abierto: phpMyAdmin → http://localhost:8081, Metabase → http://localhost:3002, Swagger → http://localhost:3000/api. Apagalas cuando no las uses: `docker compose --profile admin stop phpmyadmin`.

---

## Desarrollo local (yarn)

Los dos repos usan **yarn 1** (`yarn.lock`), igual que las imágenes de Docker. No uses `npm install`: genera otro lockfile y las versiones pueden no coincidir con las de producción. Si no tenés yarn instalado, usalo con corepack (viene con Node): `corepack yarn ...`.

**Base de datos.** El compose de *este* repo no expone MySQL. Para desarrollar, usá el `docker-compose.yml` de BaseBack (MySQL en el puerto 3310, phpMyAdmin en el 8081):

```bash
cd BaseBack/distribuidora-bv
docker compose up -d mysql phpmyadmin
```

**Backend.** Necesita un `.env` (el repo solo trae `.env-temp`). Copialo y apuntá la base a tu máquina:

```bash
cp .env-temp .env && chmod 600 .env
# en .env: DB_HOST="127.0.0.1", DB_PORT=3310, DB_USERNAME/DB_PASSWORD="admin"
# y AFIP_ENV=homologacion para no facturar en producción
corepack yarn install --frozen-lockfile
corepack yarn migration:run      # la primera vez: crea las tablas (tarda unos minutos)
corepack yarn start:dev
```

Si el backend tira `ECONNREFUSED 127.0.0.1:3306`, falta el `.env` o el contenedor de MySQL no está levantado.

**Frontend.**

```bash
cd BaseFront
corepack yarn install --frozen-lockfile
corepack yarn dev
```

**Probar las imágenes de producción en local**, sin GitHub: construilas con el override y levantá el stack con una versión `local`:

```bash
cd BaseInfra
export REGISTRY=local BACKEND_TAG=prueba FRONTEND_TAG=prueba
docker compose -f docker-compose.yml -f docker-compose.build.yml build backend frontend
docker compose up -d --wait db                      # necesita un .env (generar-env.sh)
docker compose --profile tools run --rm migrate
docker compose up -d backend frontend               # http://127.0.0.1:8080
```

(`deploy.sh` siempre descarga del registro, así que para esto se usa `docker compose` directo.)

| Tarea | Comando |
|---|---|
| Instalar dependencias | `corepack yarn install --frozen-lockfile` |
| Agregar una dependencia | `corepack yarn add paquete` (commitear `package.json` y `yarn.lock`) |
| Correr migraciones | `corepack yarn migration:run` |
| Generar una migración | `corepack yarn migration:generate src/migrations/nombre` |
| Revertir la última | `corepack yarn migration:revert` |
| Apagar la base local | `docker compose stop mysql phpmyadmin` (los datos quedan en el volumen) |

---

## Protecciones incluidas

**Servidor**

- SSH solo con clave, sin root, solo el usuario de despliegue y máximo 3 intentos. El script verifica que SSH siga escuchando después de endurecerlo y, si no, revierte.
- UFW con política deny por defecto: solo abre 22 (con rate limit), 80 y 443.
- fail2ban sobre SSH, rate limit de nginx, bots y reincidentes (ban de una semana).
- Actualizaciones de seguridad automáticas, con reinicio a las 04:30 si hace falta.
- sysctl de red: syncookies, rp_filter y redirects desactivados.

**Imágenes y despliegue**

- Las imágenes se arman en GitHub Actions desde el código exacto de un tag: nada sin commitear se cuela en producción.
- Imágenes **privadas** en ghcr.io. El servidor las descarga con un token de **solo lectura**; GitHub nunca tiene acceso al servidor.
- El servidor no tiene el código fuente ni claves de los repos de la aplicación.
- Los `.dockerignore` dejan afuera `.env*`, `certs/` y dumps: los secretos no viajan en las imágenes.

**Docker**

- Puertos solo en 127.0.0.1 y MySQL sin puerto expuesto.
- `no-new-privileges` y rotación de logs.
- Backend corriendo como usuario no root, con `tini`.

**Nginx**

- TLS 1.2/1.3 (perfil Mozilla intermediate), HSTS y HTTP→HTTPS.
- Headers de seguridad: nosniff, X-Frame-Options DENY, Referrer-Policy, Permissions-Policy y COOP compatible con Google Login.
- Rate limiting: 10 req/min en login, registro y recuperación de contraseña; 20 req/s en el resto de la API.
- Bloqueados desde internet: `/api/seed*`, Swagger y archivos ocultos.
- Las requests por IP o con otro Host se descartan sin respuesta (444 y rechazo del handshake TLS).
- `server_tokens off`, timeouts cortos y `client_max_body_size 50m`.

**Datos**

- Contraseñas aleatorias, `.env` con permisos 600.
- Certificado de AFIP montado como solo lectura, fuera de las imágenes.
- Backups diarios con retención configurable, y uno antes de cada migración.

---

## Problemas de seguridad encontrados en los repos

Son cambios a hacer en **BaseBack/BaseFront**. Este repo no los toca.

0. **Migración con espacio en el nombre** (`DeleteOrdenPagoPersonal1788902138107 `). Ya está corregida en BaseBack, pero **las bases que la registraron con el espacio** (por ejemplo, los dumps viejos) necesitan, *antes* de correr migraciones:
   `UPDATE migrations SET name='DeleteOrdenPagoPersonal1788902138107' WHERE name='DeleteOrdenPagoPersonal1788902138107 ';`
   Si no, TypeORM la vuelve a ejecutar y **borra las tablas de órdenes de pago personal**. Ver [docs/operacion.md](docs/operacion.md#cargar-un-dump).
1. **Secretos commiteados en BaseBack**: `certs/privada` (clave privada de AFIP), `.env-temp` (credenciales de la base, `JWT_SECRET` y contraseña de mail) y `src/backups/*.sql` (dumps, probablemente con datos reales). Cualquiera con acceso al repo los tiene, y siguen en el historial de git aunque se borren.
   - Rotar todo: revocar el certificado en AFIP y generar uno nuevo, un `JWT_SECRET` nuevo y una contraseña de mail nueva.
   - Sacarlos del repo, agregarlos a `.gitignore` y limpiar el historial (`git filter-repo`).
   - Los `.dockerignore` ya evitan que entren a las imágenes.
2. **Seeds públicos**: `GET /api/seed-all/execute` (y los otros seeds) no tienen guard, y crean usuarios con contraseñas escritas en el código. Nginx ya los bloquea, pero conviene protegerlos o deshabilitarlos en producción dentro del código.
3. **`auth.service.ts` imprime `EMAIL_USER` y `EMAIL_PASS` en los logs** (`console.log`). Hay que borrar esas líneas.
4. **`main.ts` imprime todas las rutas al iniciar** y llama a `app.enableCors()` sin restricción. Con el mismo dominio no hace falta CORS: conviene restringirlo a `https://DOMAIN` o quitarlo.
5. **`GET /api/afip/test-factura/:id`** parece un endpoint de prueba de facturación. Revisar si tiene guard o sacarlo en producción.
6. **`POST /api/auth/registrar` es público**: cualquiera puede crear usuarios. Revisar si debe estarlo.
7. **BaseBack tiene dos lockfiles** (`yarn.lock` y `package-lock.json`). Las imágenes usan `yarn.lock`; el `package-lock.json` sobra y puede quedar desincronizado. Conviene borrarlo y agregar `"packageManager": "yarn@1.22.22"` al `package.json` de los dos repos.
8. **Frontend**: el `clientId` de Google está hardcodeado en `src/main.tsx`. No es un secreto, pero hay que agregar `https://DOMAIN` en *Authorized JavaScript origins* de la consola de Google, o el login con Google no va a funcionar.
