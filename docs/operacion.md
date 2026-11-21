# Operación del servidor

Runbook de las tareas habituales. Todo se corre en `/opt/sistema/BaseInfra`, como el usuario de despliegue (`ssh deploy@IP`). Para tareas largas, usá `tmux new -s trabajo`: si se corta SSH, el comando sigue (`tmux attach -t trabajo`).

## Desplegar

```bash
bash scripts/deploy.sh v1.3.0 v1.4.0     # versión del backend y del frontend
```

Qué hace, en orden:

1. Descarga `baseback:v1.3.0` y `basefront:v1.4.0`. Si alguna no existe, se corta acá **sin tocar lo que está corriendo**.
2. Se asegura de que MySQL esté arriba.
3. Hace un **backup** (`backups/db-FECHA.sql.gz` y `uploads-FECHA.tar.gz`).
4. Corre las migraciones pendientes con la imagen nueva.
5. Guarda las versiones que estaban en `.deploy-anterior` y escribe las nuevas en `.env`.
6. Reemplaza los contenedores de backend y frontend.
7. Espera hasta 2 minutos a que el frontend devuelva 200 y la API responda.

Sin argumentos (`bash scripts/deploy.sh`) vuelve a desplegar lo que dice `.env`. Es lo que se usa después de cambiar una variable.

## Volver a la versión anterior

```bash
bash scripts/revertir.sh
```

Pide confirmación y despliega las versiones de `.deploy-anterior`. Las imágenes viejas suelen seguir en el disco, así que tarda segundos. También se puede ir a cualquier versión: `bash scripts/deploy.sh v1.2.0 v1.3.0`.

**Las migraciones no se revierten.** Si la versión que salió mal migró la base:

- Si la migración solo **agregó** cosas (tablas o columnas nuevas), la versión anterior suele funcionar igual.
- Si **borró o renombró**, la versión anterior va a fallar. Hay que restaurar el backup que hizo `deploy.sh` justo antes de migrar (se pierde lo cargado desde ese momento):

  ```bash
  ls -t backups/db-*.sql.gz | head -3
  docker compose stop backend
  bash scripts/restaurar-db.sh backups/db-FECHA.sql.gz
  bash scripts/deploy.sh <versiones anteriores>
  ```

## Cambiar la configuración (.env)

```bash
nano .env
bash scripts/deploy.sh          # recrea los contenedores con los valores nuevos
```

`docker compose restart` **no** relee `.env`. Hay que recrear: `deploy.sh` sin argumentos o `docker compose up -d backend`.

## Migraciones a mano

```bash
docker compose --profile tools run --rm migrate                         # aplicar pendientes
docker compose --profile tools run --rm migrate \
  node node_modules/typeorm/cli.js migration:show -d dist/orm.config.js # ver estado
```

Usan la imagen del backend de `BACKEND_TAG`.

## Cargar un dump

Para pasar datos reales a un servidor nuevo, o restaurar desde otro sistema. **Pisa todo lo que haya en la base.**

```bash
# en tu máquina
scp "dump.sql" deploy@IP:/opt/sistema/BaseInfra/dump.sql

# en el servidor
cd /opt/sistema/BaseInfra
set -a; source .env; set +a
bash scripts/backup.sh
docker compose stop backend

# 1. Vaciar la base (los dumps de phpMyAdmin traen CREATE TABLE sin DROP)
docker compose exec -T -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" db mysql -uroot \
  -e "DROP DATABASE \`$DB_DATABASE\`; CREATE DATABASE \`$DB_DATABASE\` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;"

# 2. Importar (pide escribir SI)
bash scripts/restaurar-db.sh dump.sql

# 3. Corregir la migración con espacio (dumps anteriores a la corrección)
docker compose exec -T -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" db mysql -uroot "$DB_DATABASE" \
  -e "UPDATE migrations SET name='DeleteOrdenPagoPersonal1788902138107' WHERE name='DeleteOrdenPagoPersonal1788902138107 '; SELECT ROW_COUNT();"

# 4. Migraciones que falten y arrancar
docker compose --profile tools run --rm migrate
docker compose up -d backend
rm dump.sql
```

El paso 3 es obligatorio si el dump trae `DeleteOrdenPagoPersonal1788902138107 ` registrada **con espacio al final**. El código la nombra sin espacio, así que TypeORM la tomaría como nueva, la volvería a ejecutar y **borraría las tablas de órdenes de pago personal**. En el paso 4, verificá que **no** aparezca `DeleteOrdenPagoPersonal` entre las migraciones ejecutadas.

## Backups

- Automático diario por cron (ver README, paso 7) y uno antes de cada deploy.
- Se guardan en `backups/` y se borran después de `RETENCION_DIAS` (14 por defecto).
- **Copialos fuera del servidor.** Un backup que vive solo en el VPS se pierde con el VPS.
- Probá restaurar uno de vez en cuando en una máquina de prueba.

## Token del registro

El servidor descarga las imágenes con un token clásico de GitHub `read:packages`, guardado por `docker login` en `~/.docker/config.json`.

- **Si vence o lo revocás:** generá otro y corré `bash scripts/02-registro.sh`.
- **Si se filtró:** revocalo en GitHub ya mismo. Solo permite *descargar* imágenes, no publicar ni ver el código, pero las imágenes contienen el backend compilado.
- Lo ideal es que el token sea de un usuario "de máquina" de la organización y no de una persona, así no se rompe el servidor si esa persona se va.

## Espacio en disco

`deploy.sh` borra solo las capas huérfanas. Las versiones anteriores quedan, para que un rollback sea instantáneo. Para limpiar las de más de 30 días que no estén en uso:

```bash
docker image prune -a --filter "until=720h"
```

## Logs y estado

| Qué | Comando |
|---|---|
| Contenedores | `docker compose ps` |
| Versiones desplegadas | `grep _TAG .env` (y `cat .deploy-anterior`) |
| Logs del backend | `docker compose logs -f --tail=200 backend` |
| Logs de nginx | `sudo tail -f /var/log/nginx/sistema.error.log` |
| Memoria y disco | `free -h` · `df -h /` · `docker system df` |
| AFIP | `curl 127.0.0.1:3000/api/afip/status` · `/api/afip/info` |
| IPs baneadas | `sudo fail2ban-client status sshd` · `nginx-limit-req` |

## Si algo falla

| Síntoma | Causa probable | Qué hacer |
|---|---|---|
| `No se pudieron descargar baseback:vX` | El tag no existe, el workflow falló o todavía corre, o falta `docker login` | Revisá Actions en GitHub. `bash scripts/02-registro.sh` |
| `denied` o `unauthorized` al descargar | Token vencido o sin `read:packages`, o falta autorizar el SSO | Token nuevo + `02-registro.sh` |
| Falla una migración | Bug en la migración, o base con datos inesperados | La versión anterior sigue corriendo y `.env` no cambió, pero la migración pudo quedar a medias: revisá los logs. Corregí y publicá una versión nueva, o restaurá el backup del deploy |
| `No respondieron` al final del deploy | El backend no arranca (variable faltante, base) | `docker compose logs --tail=100 backend`. `bash scripts/revertir.sh` si urge |
| Se ejecutó `DeleteOrdenPagoPersonal` sin querer | Migración con espacio sin corregir | Frená el backend y restaurá el backup previo al deploy |
| AFIP: `cms.cert.untrusted` | Certificado de un ambiente distinto a `AFIP_ENV` | Certificado de homologación con `homologacion`, de producción con `produccion` |
| Login con Google falla | Falta el dominio en Google Cloud Console | Agregar `https://DOMAIN` en *Authorized JavaScript origins* |
| `429 Too Many Requests` | Rate limit de nginx | Si es legítimo: `sudo fail2ban-client unban IP` |
| Te quedaste afuera por SSH | Endurecimiento o ban de fail2ban | Consola web del proveedor (Recovery Console) |
