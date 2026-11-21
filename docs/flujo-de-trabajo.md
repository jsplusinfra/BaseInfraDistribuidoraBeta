# Flujo de trabajo: de la idea al servidor

Local, testing y producción · BaseBack, BaseFront y BaseInfra.

Cómo trabajar con el sistema de punta a punta: probar un cambio en tu PC, validarlo en un servidor de pruebas y publicarlo en producción. Los comandos y resultados de esta guía se **corrieron sobre el código de `master` (v1.1.0) el 04/11/2026**; lo que no se pudo verificar está marcado.

> 🎯 **La idea:** un cambio sube por tres escalones, **local → testing → producción**. En cada uno se prueba algo distinto y en ninguno se compila en el servidor: **la imagen de Docker que se probó es la que se publica.**

---

## 1. Los tres escalones

| Escalón | Qué prueba | Qué NO prueba |
|---|---|---|
| **Local** (tu PC) | Que el código funciona y la lógica es correcta | nginx, HTTPS, memoria real, permisos de archivos, variables del servidor, la red real |
| **Testing** (un VPS aparte) | Que **la imagen de Docker** anda en un servidor igual al de producción | Nada: es lo más parecido a producción que hay |
| **Producción** | — | — |

Casi todos los problemas que tuvimos al desplegar (el certificado que el backend no podía leer, la memoria con Metabase, el caché del tablero, el `/run/sshd` del arranque) **no aparecen en local**. Por eso el escalón de testing vale la pena, sobre todo en un sistema que factura.

---

## 2. Antes de empezar

- **GitHub:** la cuenta activa de `gh` tiene que ser la que tiene acceso a los repos: `gh auth switch --user jsplusinfra`.
- **Node 20 y yarn 1 con corepack:** usá siempre `corepack yarn ...`. **Nunca `npm install`**: genera otro lockfile y las versiones pueden no coincidir con las de las imágenes.
- **Docker** instalado.
- Las tres carpetas lado a lado: `BaseBack`, `BaseFront` y `BaseInfra` dentro de `~/Escritorio/DESPLIEGUE`.

---

## 3. Pruebas locales

### 3.1 Nivel A: desarrollo diario (con recarga automática)

```bash
# 1) base de datos local: MySQL en el 3310 y phpMyAdmin en el 8081
cd ~/Escritorio/DESPLIEGUE/BaseBack/distribuidora-bv
docker compose up -d mysql phpmyadmin

# 2) backend (la primera vez: crear el .env y correr las migraciones)
cp .env-temp .env && chmod 600 .env
#    editar el .env: DB_HOST="127.0.0.1", DB_PORT=3310,
#    DB_USERNAME y DB_PASSWORD="admin", AFIP_ENV=homologacion
corepack yarn install --frozen-lockfile
corepack yarn migration:run
corepack yarn start:dev                  # http://localhost:3000

# 3) frontend (en otra terminal)
cd ~/Escritorio/DESPLIEGUE/BaseFront
corepack yarn install --frozen-lockfile
corepack yarn dev                        # http://localhost:5173
```

- **`AFIP_ENV=homologacion` es obligatorio en local**: así no se factura de verdad.
- El frontend apunta al backend por `VITE_API_URL`, que ya viene en `.env.development` (`http://localhost:3000/api`).
- Si el backend dice `ECONNREFUSED 127.0.0.1:3306`, falta el `.env` o MySQL no está levantado.

### 3.2 Nivel B: chequeos automáticos

Esto es lo que se **midió el 04/11/2026** sobre `master`:

| Repo | Chequeo | Resultado hoy |
|---|---|---|
| BaseBack | `yarn test` (unitarios, todos) | ✅ 97 suites, 293 tests (+3 pendientes), unos 20 segundos |
| BaseBack | `yarn test:int` (integración) | ✅ 151 de 151 |
| BaseBack | `yarn migration:verificar` | ✅ 51 migraciones |
| BaseBack | `yarn build` | ✅ |
| BaseFront | Tests automáticos | No hay: solo el checklist manual (3.4) |
| BaseFront | `yarn lint` | ✅ 0 errores (459 avisos de antes, que no frenan) |
| BaseFront | `yarn build` | ✅ |
| BaseFront | Tipos (`tsc --noEmit`) | 🔴 218 errores. `vite build` no los revisa |
| BaseInfra | `bash -n`, `shellcheck`, `docker compose config`, `nginx -t` | ✅ |

**En GitHub corren solos:** en BaseBack el workflow **Pruebas** (compila, verifica migraciones, unitarios e integración con una base MySQL de test) y en BaseFront el workflow **Verificar** (`yarn lint` y `yarn build`). Se ejecutan en cada PR y en cada push a `master`: si queda en rojo, el cambio no se mergea.

**Los comandos del backend:**

```bash
cd ~/Escritorio/DESPLIEGUE/BaseBack/distribuidora-bv

# unitarios: todos, o solo un módulo (el filtro es parte de la ruta del archivo)
corepack yarn test
corepack yarn test anticipo-sueldo

# integración: necesita la base de test (MySQL en el 3311, en memoria)
corepack yarn test:db:up
corepack yarn test:int
corepack yarn test:db:down

corepack yarn build                         # que compile (es lo que hace la imagen)
corepack yarn migration:verificar           # nombres de migraciones
```

> ⚠️ **`yarn lint` del backend arregla archivos solo** (`--fix`): corrélo con el trabajo ya commiteado para ver qué cambió. Y los tests de integración **borran y recrean** la base de test en cada corrida: nunca se apuntan a la de desarrollo (el código se niega a hacerlo).

**Los comandos del frontend:**

```bash
cd ~/Escritorio/DESPLIEGUE/BaseFront
corepack yarn build        # que compile
corepack yarn lint         # tiene que terminar sin errores (los avisos de antes no frenan)
```

### 3.3 Nivel C: las imágenes de producción en tu PC

Prueba lo que el nivel A no ve: el Dockerfile, las variables y el camino `/api` por nginx. Levanta **backend, frontend, base y un nginx local** igual que en el servidor.

```bash
cd ~/Escritorio/DESPLIEGUE/BaseInfra
[ -f .env ] || bash scripts/generar-env.sh
export COMPOSE_PROJECT_NAME=prueba-local        # no pisa tu stack de siempre
export REGISTRY=local BACKEND_TAG=prueba FRONTEND_TAG=prueba
export COMPOSE_FILE=docker-compose.yml:docker-compose.build.yml:docker-compose.local.yml

docker compose build backend frontend
docker compose up -d --wait db

# cargar datos (recomendado: sin datos el login no muestra empresas)
set -a; source .env; set +a
docker compose exec -T -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" db \
  mysql -uroot "$DB_DATABASE" < ~/Descargas/"gestion_distribuidora_bv (17)-corregido.sql"

docker compose --profile tools run --rm migrate
docker compose up -d backend frontend proxy     # entrar a http://localhost:8000
```

Cuando termines: `docker compose down -v` (con el mismo `COMPOSE_PROJECT_NAME`) borra todo lo de la prueba.

- **Construye lo que tengas en tus carpetas** `BaseBack` y `BaseFront`, en la rama en que estén. Para usar otra carpeta: `BACK_DIR` y `FRONT_DIR`.
- **`COMPOSE_PROJECT_NAME` y un tag distinto de `local`** evitan pisar las imágenes y la base de tu otro stack. El backend y el frontend no publican puertos en este modo (solo el 8000), así que tampoco chocan con el 3000 y el 8080.
- **Con las imágenes oficiales** (en vez de construir): `docker login ghcr.io` con un token `read:packages`, `export REGISTRY=ghcr.io/jsplusinfra BACKEND_TAG=v1.1.0 FRONTEND_TAG=v1.1.0`, `COMPOSE_FILE=docker-compose.yml:docker-compose.local.yml` y `docker compose pull backend frontend`. *Esta variante no se probó en esta revisión (hace falta el token).*

**Resultado verificado de este flujo (con `master` y el dump corregido):** el frontend responde 200, el login vacío da 400 (la API está viva), `/api/estadisticas/tablero/ventas` da 401 (pide sesión) y `/api/empresa` devuelve la empresa del dump. En el `migrate` corren solo 2 migraciones.

### 3.4 Nivel D: la prueba manual

BaseFront trae `TESTING_CHECKLIST.md`, el **circuito mínimo** a mano: autenticación, ABM de datos maestros, compras, stock, ventas, pedido mobile, cobros y pagos, gestión bancaria, configuración y precios. Cómo usarlo:

- **Al terminar un cambio:** corré las secciones que toca.
- **Antes de publicar (en testing):** el circuito completo, porque un cambio puede romper algo que no tocaste.

---

## 4. Probar una funcionalidad nueva, paso a paso

```bash
# 1) rama nueva, siempre desde master actualizado
cd ~/Escritorio/DESPLIEGUE/BaseBack
git switch master && git pull
git switch -c feature/nombre-corto

# 2) programar y probar en local (niveles A y B)

# 3) si cambia la base de datos: generar la migración
corepack yarn migration:generate src/migrations/NombreDelCambio
corepack yarn migration:verificar
corepack yarn migration:run                 # probarla en tu base local

# 4) subir y abrir el PR
git add -A && git commit -m "Describí qué hace"
git push -u origin feature/nombre-corto
```

Después abrís el PR en GitHub, alguien lo revisa y se mergea a `master`.

**Reglas para las migraciones** (por lo que pasó con `DeleteOrdenPagoPersonal`):

- No escribas el `name` a mano.
- **Una migración que ya corrió en algún servidor no se edita**: se hace otra nueva.
- Preferí las que **agregan** (columnas que aceptan `NULL`, tablas nuevas) antes que las que borran o renombran: así `revertir.sh` es seguro.
- Revisá el archivo generado: a veces arrastra diferencias que no son tuyas.

**Si el cambio toca el Dockerfile, las variables, nginx o el compose**, además del nivel A corré el nivel C: es lo único que lo detecta antes del servidor.

---

## 5. Qué repo se toca según el cambio

| Qué cambió | Dónde se programa | Qué se publica | Qué se corre en el servidor |
|---|---|---|---|
| Lógica del backend | BaseBack | Tag del backend | `deploy.sh vNUEVO vFRONT_ACTUAL` |
| Backend con migración | BaseBack | Tag del backend | Lo mismo: `deploy.sh` hace backup y migra solo |
| Solo pantallas | BaseFront | Tag del frontend | `deploy.sh vBACK_ACTUAL vNUEVO` |
| Back y front que dependen entre sí | Los dos | Tag de cada uno | Un solo `deploy.sh vB vF` con las dos versiones |
| **Variable de entorno nueva** | BaseBack + **BaseInfra** | Tag del back | Agregarla al `.env` de cada servidor y `deploy.sh` |
| nginx, compose, scripts, MySQL | **BaseInfra** | Nada (no lleva tags) | `git pull` y lo que corresponda (abajo) |
| Dependencia npm nueva | El repo que la usa | Tag | `package.json` **y** `yarn.lock` van en el mismo commit |
| Certificado o archivo secreto | Nada de git | Nada | `scp` a `secrets/` |

**Cuando se toca BaseInfra**, en el servidor:

```bash
cd /opt/sistema/BaseInfra
git pull
sudo bash scripts/03-ssl.sh       # si cambió nginx (recarga sin cortar)
bash scripts/deploy.sh            # si cambió el compose o el .env (recrea contenedores)
```

**Una variable nueva se agrega en tres lugares.** Si falta alguno, el contenedor no la ve:

1. El código del backend la lee.
2. `.env.example` y `docker-compose.yml` de BaseInfra la declaran y se la pasan al contenedor.
3. El `.env` de **cada servidor** tiene el valor (testing y producción).

---

## 6. Del código al servidor: los comandos

```bash
# 1) la versión: en el repo que cambió, ya mergeado a master
git switch master && git pull
git tag v1.2.0 && git push origin v1.2.0
# 2) esperar el verde en GitHub → Actions → "Publicar imagen"

# 3) en el servidor
ssh masita@IP
cd /opt/sistema/BaseInfra
grep _TAG .env                        # versiones actuales
bash scripts/deploy.sh v1.2.0 v1.1.0  # backend frontend (la que no cambió, igual)
docker compose ps                     # todo en Up
docker compose logs --tail=50 backend

# si algo sale mal
bash scripts/revertir.sh              # vuelve a las versiones anteriores
```

**Cómo numerar:** corrección sin cambios de comportamiento, `v1.1.0` → `v1.1.1`; funcionalidad nueva o migración, `v1.1.0` → `v1.2.0`; cambio incompatible, `v2.0.0`. Los tags **no se reutilizan**: si `v1.2.0` salió mal, se arregla y se publica `v1.2.1`. Backend y frontend se numeran por separado.

`deploy.sh` descarga las imágenes, hace un backup, corre las migraciones pendientes, levanta las versiones nuevas y verifica que respondan. **`revertir.sh` vuelve a las imágenes anteriores pero no deshace migraciones**: si la versión nueva cambió tablas, puede hacer falta restaurar el backup que hizo `deploy.sh`.

---

## 7. El VPS de testing

> ✅ **Conviene tenerlo.** Prueba exactamente lo que va a correr en producción, con nginx, HTTPS, memoria y red reales, y te deja probar las migraciones sobre una copia de los datos reales **antes** de tocar los datos de verdad.

**Cómo se arma:** con **el mismo BaseInfra y la misma guía rápida de despliegue**. No hay un repo aparte: lo único que cambia entre testing y producción es el `.env` y el servidor. Cada servidor lleva su propia *deploy key*, con el nombre del servidor como título.

| | Testing | Producción |
|---|---|---|
| Servidor | Droplet de 1 GB (2 GB si probás Metabase) | El actual |
| Dominio | Otro (`IP-con-guiones.sslip.io` ya es distinto) | El actual |
| `AFIP_ENV` | **`homologacion`**, sin el certificado real | `produccion` |
| Mails | `EMAIL_USER` vacío o una cuenta de prueba | Los reales |
| Contraseñas | Propias, generadas por `generar-env.sh` | Propias |
| Datos | Copia de producción, o el dump corregido | Los reales |
| Backups externos | No hacen falta | Sí |
| Login con Google | Agregar su URL en *Authorized JavaScript origins* | La actual |

**Cuidados importantes:**

- **Si lo cargás con una copia de producción, tiene datos reales de clientes.** Limitá quién entra: *basic auth* en nginx o el firewall del proveedor por IP. Ojo: Let's Encrypt necesita el puerto 80 abierto para emitir y renovar el certificado.
- **Nunca el certificado de AFIP de producción en testing.** Una factura de prueba sería real.
- **Sin mails reales:** con datos copiados, una prueba puede terminar escribiéndole a un cliente.
- **Cambiá las contraseñas de los usuarios** del sistema después de cargar la copia.
- **Costo:** un droplet apagado **sigue cobrando** en DigitalOcean. Para no pagar hay que destruirlo; con la guía rápida se recrea en unos 15 minutos.

**Para refrescar los datos de testing** (hasta que exista un script que lo haga): bajar el último backup o dump y seguir la Parte 7 de la guía de despliegue, incluido `docker compose --profile tools run --rm migrate`.

---

## 8. El flujo completo con testing

| # | Etapa | Qué se hace |
|---|---|---|
| 1 | Local | Rama, desarrollo, chequeos (3.2) y, si toca infraestructura, el nivel C |
| 2 | PR | Los workflows *Pruebas* (backend) y *Verificar* (frontend) tienen que estar en verde. Revisión y merge a `master`. GitHub publica la imagen `:master` y una `sha-xxxxxxx` de ese commit |
| 3 | Testing | `deploy.sh sha-xxxxxxx vFRONT_ACTUAL` |
| 4 | Pruebas | Lo nuevo **y** el circuito mínimo (3.4) |
| 5 | Versión | Si está bien, `git tag v1.2.0` **sobre ese mismo commit** y esperar el verde |
| 6 | Producción | `deploy.sh v1.2.0 vFRONT_ACTUAL` y verificar |

- **Probar lo mismo que se publica:** el commit del paso 3 es el que se tagea en el paso 5. Así no cambia nada en el medio.
- **Para un cambio arriesgado** (migraciones grandes) podés probar **antes de mergear**: en GitHub → Actions → *Publicar imagen* → *Run workflow* → elegir tu rama. Eso publica `sha-xxxxxxx` (el commit se ve con `git rev-parse --short=7 HEAD`). También sirve desde la terminal: `gh workflow run publicar-imagen.yml --ref feature/nombre -R jsplusinfra/BaseBack`.
- **Nunca una `sha-...` ni `master` en producción.** `deploy.sh` avisa con `!!`: en testing está bien, en producción no.

---

## 9. Lo que hoy falta

- [ ] **BaseFront:** no tiene tests automáticos. Los 218 errores de tipos (asignaciones y argumentos incompatibles) no se corrigieron: cada uno exige entender el código, y sin tests es riesgoso.
- [ ] **BaseFront:** dos `react-hooks/rules-of-hooks` marcados como `PENDIENTE` (`PrivateRoute.tsx` y `form-input.tsx`): llaman un hook de forma condicional y arreglarlos cambia la lógica de autenticación y de las máscaras.
- [ ] **BaseFront:** en `seleccion-items-facturar.tsx.tsx`, `handleAgregarItems` terminaba con una referencia suelta a `onSuccess` (sin paréntesis): el callback del padre **nunca se llamaba**. Se quitó la línea para no cambiar el comportamiento; probablemente la intención era `onSuccess()`.
- [ ] **BaseBack:** los tests de `marca.service` quedaron como `it.todo` (estaban comentados): rehacerlos.
- [ ] **Casi todos los `catch` del backend** (hay unos 470 `throw new DatabaseConnectionException`) convierten cualquier error en un 500 de base de datos. Se arregló el de libro caja; conviene revisar los demás.
- [ ] **BaseInfra:** `scripts/refrescar-testing.sh` (bajar el último backup, restaurarlo en testing y cambiar las contraseñas).
- [ ] **Backups externos** activos en producción: testing con datos reales solo tiene sentido si de ahí sale la copia.
- [ ] **Variables de entorno:** hoy se copian a mano entre servidores. Una lista de variables obligatorias por entorno evitaría olvidos.

---

## 10. Referencia rápida

| Quiero... | Comando |
|---|---|
| Correr el backend en local | `corepack yarn start:dev` (en `BaseBack/distribuidora-bv`) |
| Correr el frontend en local | `corepack yarn dev` (en `BaseFront`) |
| Tests unitarios del backend | `corepack yarn test <filtro>` |
| Tests de integración del backend | `yarn test:db:up` → `yarn test:int` → `yarn test:db:down` |
| Verificar migraciones | `corepack yarn migration:verificar` |
| Generar una migración | `corepack yarn migration:generate src/migrations/Nombre` |
| Probar las imágenes en mi PC | Sección 3.3 (`http://localhost:8000`) |
| Publicar una versión | `git tag vX.Y.Z && git push origin vX.Y.Z` |
| Publicar una rama para probarla | Actions → *Publicar imagen* → *Run workflow* |
| Ver qué versión corre un servidor | `grep _TAG .env` |
| Desplegar | `bash scripts/deploy.sh vBACK vFRONT` |
| Volver atrás | `bash scripts/revertir.sh` |
| Aplicar un cambio de nginx | `git pull` y `sudo bash scripts/03-ssl.sh` |
| Aplicar un cambio del `.env` o del compose | `bash scripts/deploy.sh` |
| Ver los logs | `docker compose logs -f --tail=100 backend` |
