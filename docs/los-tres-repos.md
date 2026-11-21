# Los tres repos: qué tiene cada uno y por qué

Qué tiene cada uno de los tres repos del sistema, cómo se conectan entre sí y por qué se armó así. Está escrito leyendo los repos en su estado actual (`master` del 04/11/2026).

> **Cómo leerlo:** en cada repo separo dos cosas. **Lo que ya existía** es el código de la aplicación, escrito por el equipo: lo describo, pero no puedo explicar por qué se decidió así, solo qué hace y cómo se ve. **Lo que se agregó** (Dockerfiles, workflows, el repo de infraestructura, scripts, tests y documentación) es lo que se hizo durante este trabajo: de eso sí explico **cada decisión y la alternativa que se descartó**.

---

## 1. Vista general

| Repo | Para qué sirve | Tecnología | Dónde vive |
|---|---|---|---|
| **BaseBack** | El backend: la API, las reglas del negocio, la facturación de AFIP | NestJS 11, TypeORM, MySQL | GitHub. No está en el servidor |
| **BaseFront** | El frontend: lo que ve y usa la gente | React 19, Vite 6, TypeScript, Tailwind | GitHub. No está en el servidor |
| **BaseInfra** | Cómo corre todo en un servidor: contenedores, nginx, scripts, backups | Docker Compose, nginx, bash | GitHub **y** el servidor (`/opt/sistema/BaseInfra`) |

**Cómo se conectan:**

```text
 BaseBack ──git tag v1.2.0──► GitHub Actions ──► imagen  ghcr.io/jsplusinfra/baseback:v1.2.0 ─┐
 BaseFront ─git tag v1.4.0──► GitHub Actions ──► imagen  ghcr.io/jsplusinfra/basefront:v1.4.0 ─┤
                                                                                              ▼
 BaseInfra (en el servidor) ── deploy.sh v1.2.0 v1.4.0 ──► descarga las imágenes, migra la base,
                               docker-compose + nginx       las levanta y comprueba que respondan
```

**La idea central:** el código **se compila una sola vez, en GitHub**, y el servidor solo descarga la imagen ya armada. El único repo que se clona en el servidor es BaseInfra: no lleva código de la aplicación ni secretos.

**Por qué tres repos y no uno:** el backend y el frontend se versionan **por separado** (cada uno con su propio número de versión), y la infraestructura cambia con otro ritmo y otras personas la tocan. Con un repo aparte, el servidor clona solo lo que necesita (la infraestructura) y nunca el código fuente.

---

## 2. BaseBack (el backend)

### 2.1 Qué es

Una API REST hecha con **NestJS 11**, que guarda en **MySQL 8** con **TypeORM**. Tiene unos 2.100 archivos TypeScript, **146 entidades**, **150 controladores** y **51 migraciones** de base de datos. Se publica bajo `/api` y tiene documentación Swagger.

Librerías que marcan lo que hace: `@nestjs/jwt` y `bcrypt` (login y contraseñas), `google-auth-library` (ingresar con Google), `nodemailer` (recuperar contraseña por mail), `soap` y `node-forge` (los servicios web de AFIP: autenticación y factura electrónica), `pdfkit` y `pdfmake` (comprobantes en PDF), `tesseract.js` (lectura de documentos por OCR) y `class-validator` (validar lo que llega a la API).

### 2.2 Cómo está ordenado el repo

La aplicación vive en la subcarpeta `distribuidora-bv/`. Eso importa: los workflows y Docker tienen que apuntar a esa carpeta (`working-directory` y `context`).

| Ubicación | Qué tiene |
|---|---|
| `.github/workflows/` | Los tres workflows de GitHub Actions (ver 2.4) |
| `.kiro/` | Especificaciones de diseño de funcionalidades (AFIP, factura electrónica, notificaciones) |
| `distribuidora-bv/src/` | Todo el código |
| `distribuidora-bv/src/modules/` | Los módulos del negocio, uno por área |
| `distribuidora-bv/src/migrations/` | Las 51 migraciones de la base |
| `distribuidora-bv/orm.config.ts` | La conexión que usa la herramienta de migraciones |
| `distribuidora-bv/Dockerfile` y `.dockerignore` | Cómo se arma la imagen de producción y qué se deja afuera |
| `distribuidora-bv/docker-compose.yml` | **Solo para desarrollo**: MySQL (3310), phpMyAdmin (8081) y Metabase (3002) |
| `distribuidora-bv/docker-compose.test.yml` | La base MySQL de los tests de integración (3311, en memoria) |
| `distribuidora-bv/scripts/verificar-migraciones.mjs` | El chequeo de nombres de migraciones |
| `distribuidora-bv/test/` | Soporte de los tests de integración (esquema de la base, datos de prueba) |
| `distribuidora-bv/docs/` | Guías: tests, desarrollo y pruebas, Metabase, seguridad por token |
| `distribuidora-bv/CONVENTIONS.md` | Las reglas de cómo se escribe el código |
| `distribuidora-bv/tessdata`, `*.traineddata` | Los idiomas del OCR |
| `distribuidora-bv/assets/` | Imágenes que usan los PDF (logos) |
| `distribuidora-bv/uploads/` | Archivos subidos por los usuarios (en producción es un volumen) |

### 2.3 Cómo está armado el código (lo que ya existía)

Cada módulo del negocio sigue la misma estructura en capas. Tomando `anticipo-sueldo` de ejemplo:

```text
anticipo-sueldo/
├── domain/            reglas del negocio, sin saber nada de la base de datos
│   ├── entities/      la entidad (con sus reglas, por ejemplo cómo se calcula el saldo)
│   └── interfaces/    el "contrato" del repositorio: qué operaciones necesita
├── application/       lo que el sistema hace
│   ├── controllers/   los endpoints HTTP
│   ├── uses-cases/    una acción por archivo (crear, imprimir...)
│   └── queries/       las búsquedas
├── dto/               la forma de los datos que entran y salen de la API
├── mappers/           convierten entre entidad y DTO
└── infraestructure/   la parte que sí habla con la base de datos
    └── repositories/  implementa el contrato de `domain/interfaces` con TypeORM
```

**Por qué sirve este orden** (según `CONVENTIONS.md` y la guía de tests): las reglas del negocio no dependen de TypeORM ni de MySQL, así que se pueden probar rápido y sin base de datos usando objetos simulados. Eso es lo que permite los tests unitarios de la guía. Los módulos más nuevos usan *casos de uso*; los más viejos, *services*.

**Los 16 módulos** (`src/modules/`): `afip`, `common`, `estadisticas`, `gestion-bancos`, `gestion-cobros-pagos`, `gestion-cuenta`, `gestion-despacho`, `gestion-documentos`, `gestion-productos`, `gestion-sistema`, `gestion-usuario`, `gutil`, `ia`, `impresion`, `organizacion` y `templates`.

**`common/`** tiene lo que usan todos: decoradores, filtros de errores, interceptores, pipes de normalización, excepciones propias, el manejo de transacciones (*unit of work*) y los datos iniciales (*seed*).

**`main.ts`** hace tres cosas que se notan desde afuera: publica todo bajo `/api`, **descarta los campos que no están declarados en el DTO** (`whitelist`) y levanta Swagger en `/api`. Por eso nginx bloquea esa ruta desde internet.

### 2.4 Lo que se agregó, y por qué

| Qué | Cómo es | Por qué así |
|---|---|---|
| **`Dockerfile`** de producción | 4 etapas: instala dependencias, compila, instala solo las de producción y arma la imagen final | La imagen final **no lleva TypeScript ni herramientas de compilación**: pesa unos 557 MB en vez de más del doble, y tiene menos cosas que atacar. `COPY package.json yarn.lock` va primero para que Docker guarde esa capa y no reinstale todo cuando cambia solo el código |
| | Corre con el usuario `node` y `tini`; `NODE_OPTIONS=--max-old-space-size=1536` | Un proceso que no corre como root limita el daño si alguien lo vulnera. `tini` cierra bien los procesos al apagar. Sin el límite de memoria, Node se frenaba en ~500 MB y el build no entraba en servidores chicos |
| | Copia aparte `src/assets` y `tessdata` | El código lee esas rutas **en tiempo de ejecución**: sin copiarlas, los PDF no tenían logo y el OCR no funcionaba |
| **`.dockerignore`** | Deja afuera `.env`, `certs/`, `*.sql`, `uploads/`, `test/`, `docs/`, `node_modules` | Ningún secreto ni dump entra en una imagen, que es difícil de borrar una vez publicada |
| **`tsconfig.build.json`** con `declaration: false` | No genera archivos `.d.ts` | El patrón de migraciones (`*{.ts,.js}`) también los tomaba y Node no puede ejecutarlos. Sin esto, **las migraciones no corrían desde la imagen** |
| **Las migraciones corren con la misma imagen** | `node node_modules/typeorm/cli.js migration:run -d dist/orm.config.js` | Antes había una tercera imagen solo para migrar. Con la misma, **las migraciones siempre coinciden con el código desplegado** y hay una imagen menos para publicar |
| **Workflow *Publicar imagen*** | Se dispara con un tag `vX.Y.Z`, un push a `master` o a mano desde cualquier rama | El tag da la versión exacta para producción; `master` da una imagen de prueba; y poder publicar una rama permite probarla en el VPS de testing antes de mergear |
| **Workflow *Verificar migraciones*** y `verificar-migraciones.mjs` | Revisa que el `name` de cada migración sea igual al de su clase, sin espacios, y sin fechas repetidas | Un espacio de más en `DeleteOrdenPagoPersonal` hizo que se ordenara mal y casi borra tablas con datos. El chequeo lo frena antes de publicar |
| **Workflow *Pruebas*** | En cada PR y push a `master`: compila, verifica migraciones, corre los tests unitarios y los de integración | GitHub no corría ningún test; un PR roto se descubría recién al desplegar |
| **`docker-compose.test.yml`** | MySQL de test en el 3311, con los datos en memoria | Lo usaban `yarn test:db:up` y la guía de tests, pero el `.gitignore` lo ignoraba: **nadie podía correr los tests de integración**. Los datos en memoria hacen que cada corrida arranque limpia y que nunca se toque la base de desarrollo |
| **Corrección de libro caja** | El `catch` ya no convierte `NotFoundException` y `ConflictException` en un 500 | El código lanzaba esos errores a propósito (no hay libro abierto, hay más de uno) pero un `catch` los transformaba en "error de base de datos". Ahora la API responde 404 y 409 |
| **Limpieza de tests** | Se borraron 177 `.spec.ts` que solo tenían el test autogenerado de Nest | Importaban servicios que ya no existen y no compilaban: hacían que `yarn test` diera rojo siempre y tapaban los fallos reales |
| **`docs/desarrollo-y-pruebas.md`** | Cómo correrlo, probarlo y llevarlo al servidor | Un documento con los comandos que se verificaron, no teoría |

### 2.5 Lo que trajo el profesor en la v1.1.0

- **Seguridad por token:** un interceptor que reemplaza el usuario que manda el navegador por el del token (`sub`). Así nadie puede registrar una operación a nombre de otro.
- **Estadísticas con Metabase:** el endpoint `/api/estadisticas/tablero/:clave`, que firma la URL de un tablero embebido, y 5 vistas SQL (`v_ventas_netas_mensual` y otras) creadas por una migración.
- **Análisis con IA (Ollama):** `/api/ia/...`. Está apagado: no hay pantalla y Ollama no corre en el servidor.

### 2.6 Cosas que conviene saber

- **Hay secretos versionados:** `distribuidora-bv/.env-temp` y `certs/privada` (la clave privada del certificado de AFIP) están en git y quedan en el historial. Hay que revocar el certificado en ARCA, generar uno nuevo y limpiar el historial.
- **Archivos que sobran:** `node_modules/.yarn-integrity` y un `yarn.lock` en la raíz del repo, y `package-lock.json` junto al `yarn.lock` de la aplicación (dos gestores de paquetes). Las imágenes usan **yarn**.
- **Unos 470 `throw new DatabaseConnectionException`:** el mismo patrón de `catch` que causaba el 500 de libro caja puede estar en otros lados.

---

## 3. BaseFront (el frontend)

### 3.1 Qué es

Una *single page application* hecha con **React 19, Vite 6 y TypeScript 5.7**, con **Tailwind** para los estilos, **react-router 7** para las pantallas (unas 80 rutas), **react-hook-form + yup** para los formularios, **axios** para hablar con la API y **jwt-decode** para leer el token. Tiene unos 1.070 archivos TypeScript.

### 3.2 Cómo está ordenado el repo

| Ubicación | Qué tiene |
|---|---|
| `src/componentes/` | Las pantallas, **una carpeta por área del negocio**: ventas, compras, productos, stock, cobros y pagos, banco, organización, usuarios, AFIP, comisiones, gastos, notificaciones y estadísticas |
| `src/componentes/herramientas/` | Piezas reutilizables: formularios, campos con máscara, tablas |
| `src/componentes/menu/` | La definición del menú lateral, con qué rol ve cada opción |
| `src/features/` | Funcionalidades armadas como paquete propio (`afip-status`, `alertas`) |
| `src/utils/` | El corazón técnico: `apiService`, `axiosConfig`, `crudFactory`, `PrivateRoute`, `auth` |
| `src/App.tsx` | Todas las rutas |
| `src/hooks/`, `context/`, `interfaces/`, `services/` | Hooks, estado compartido, tipos y servicios |
| `TESTING_CHECKLIST.md` | El circuito mínimo para probar **a mano** |
| `vercel.json` | Reescritura para una SPA en Vercel. Es de antes: hoy el despliegue es con nginx |

### 3.3 Cómo funciona (lo que ya existía)

- **Habla con el backend por un solo lugar.** `axiosConfig.apiUrl` toma `VITE_API_URL`, y `ApiService` agrega a cada pedido el token que guardó el login (`Authorization: Bearer ...`).
- **`createCrudService("producto")`** genera de una vez las operaciones comunes (crear, actualizar, obtener, buscar con `search-by`, imprimir) para un recurso. Por eso casi todas las pantallas se parecen: hay un servicio por área, armado con esa fábrica.
- **Los roles se controlan en dos lugares.** `PrivateRoute` lee los roles del token y deja entrar solo si coinciden con `allowedRoles` de la ruta; y el menú oculta las opciones que el rol no puede usar. **El control de verdad lo hace el backend**: el frontend solo evita mostrar lo que no corresponde.

### 3.4 Lo que se agregó, y por qué

| Qué | Cómo es | Por qué así |
|---|---|---|
| **`Dockerfile`** de producción | 2 etapas: compila con Vite y sirve los archivos con `nginx:1.27-alpine` | La imagen final es **solo nginx con archivos estáticos** (unos 55 MB): sin Node, sin código fuente, nada que actualizar ni atacar |
| `ARG VITE_API_URL=/api` | La API va como ruta **relativa** | Backend y frontend comparten dominio: la misma imagen sirve para cualquier dominio y **no hay problemas de CORS**. Las variables `VITE_*` quedan grabadas en el JavaScript, por eso nunca pueden ser secretos |
| **`nginx.conf`** interno | Puerto 8080; `try_files ... /index.html`; caché de un año en `/assets/`; `index.html` sin caché; gzip | Las rutas de la SPA tienen que caer en `index.html`. Los archivos de `/assets/` llevan un hash en el nombre, así que se pueden guardar para siempre; `index.html` no, para que **cada versión nueva se vea al instante** |
| **`.dockerignore`** y **`Dockerfile.dev`** | Deja afuera `.env`, `.git`, `node_modules`; y un Dockerfile para desarrollar en un contenedor | Mismo criterio que el backend: nada sensible en la imagen |
| **Workflow *Publicar imagen*** | Igual que el del backend | Misma lógica de versiones, así los dos se despliegan igual |
| **Workflow *Verificar*** | `yarn lint` y `yarn build` en cada PR | Antes nada controlaba el código al subirlo |
| **Corrección de lint** | De 81 errores a 0, sin cambiar comportamiento | Para poder usar el lint como control. 43 eran `try/catch` que solo relanzaban el error; se quitaron con un transformador que toca únicamente ese patrón |
| **`docs/desarrollo-y-pruebas.md`** | Cómo correrlo, verificarlo y llevarlo al servidor | Igual que en el backend |

### 3.5 Lo que trajo el profesor

La pantalla **Estadísticas → Ventas**, que muestra un tablero de Metabase en un `iframe`. Le pide al backend la URL firmada, así la clave secreta de Metabase nunca llega al navegador. Es solo para Administrador y Root.

### 3.6 Cosas que conviene saber

- **No tiene tests automáticos.** Solo el checklist manual.
- **218 errores de tipos** (asignaciones y argumentos incompatibles). `vite build` no revisa tipos, por eso no se ven. Corregirlos exige entender cada uno.
- **Dos hooks de React llamados de forma condicional** (`PrivateRoute.tsx` y `form-input.tsx`), marcados `PENDIENTE`. Arreglarlos cambia la lógica de autenticación y de las máscaras.
- **Posible bug:** en `seleccion-items-facturar`, el callback `onSuccess` del padre **nunca se llamaba** (había una referencia suelta, sin paréntesis).
- El README habla de `npm`, pero el proyecto usa **yarn** (como las imágenes).

---

## 4. BaseInfra (la infraestructura)

### 4.1 Qué es y por qué existe

Las imágenes traen la aplicación, pero **no dicen cómo se arma un servidor**: qué contenedores corren, cómo se conectan, cómo se publica por HTTPS, cómo se despliega y cómo se hace backup. Eso es BaseInfra. Como repo de git, cada cambio queda en el historial, se revisa en un PR, se aplica con `git pull` y se puede revertir.

### 4.2 Qué tiene cada archivo

| Archivo | Qué hace | Por qué así |
|---|---|---|
| `docker-compose.yml` | Define MySQL, backend, frontend y la tarea de migrar; Metabase y phpMyAdmin son opcionales | **Todos los puertos se publican solo en `127.0.0.1`**: Docker ignora el firewall (UFW) para los puertos abiertos al mundo, así que la única puerta a internet es nginx. La base no publica ninguno. Los opcionales usan `profiles` para no gastar memoria si no se piden |
| `docker-compose.build.yml` | Permite construir las imágenes en local | Para probar sin esperar a GitHub, o como plan B. En producción no se usa |
| `docker-compose.local.yml` y `nginx/local.conf` | Un nginx local para probar todo en `localhost:8000` | Replica el papel del nginx del servidor (`/api` al backend, el resto al frontend). Backend y frontend no publican puertos acá para no chocar con otro stack |
| `.env.example` | La lista de **todas** las variables, sin valores secretos | Es el contrato de configuración: cualquiera ve qué configurar sin leer el código |
| `.gitignore` | Ignora `.env`, `secrets/*`, `backups/`, `.deploy-anterior` | Las contraseñas y los certificados nunca se suben. `secrets/afip/.gitkeep` hace que la carpeta exista al clonar |
| `mysql/conf.d/produccion.cnf` | Ajustes de MySQL para un servidor chico (caché de 256 MB, `performance_schema` apagado) | Con 512 MB de caché en un servidor de 1 GB, MySQL terminaba en el swap |
| `nginx/conf.d/00-hardening.conf` | Límites de pedidos, timeouts y el soporte de websockets | Frena la fuerza bruta (10 intentos por minuto en el login) y los pedidos lentos |
| `nginx/snippets/` | TLS, headers de seguridad, proxy, y una variante que permite `iframe` | Se reutilizan en cada sitio. Los headers van en un archivo porque nginx **anula** los del `server` cuando un `location` define alguno propio |
| `nginx/sites/*.template` | El sitio: primero solo HTTP, después HTTPS | Dos plantillas porque Let's Encrypt necesita un nginx que responda por HTTP para validar el dominio, pero el sitio HTTPS no arranca sin el certificado |
| `fail2ban/jail.local` | Banea las IP que abusan del SSH, superan el límite de nginx o buscan `/wp-admin` | Una capa más, que se activa sola mirando los logs |
| `scripts/generar-cloud-init.sh` | Genera el texto para pegar en *Startup scripts* del proveedor | El servidor se prepara solo en el primer arranque y **nunca se entra como root** |
| `scripts/01-preparar-servidor.sh` | Usuario de despliegue, SSH endurecido, firewall, fail2ban, swap, Docker, nginx | Valida SSH antes de reiniciarlo y deshace el cambio si falla: así no te quedás afuera |
| `scripts/02-registro.sh` | Conecta Docker con ghcr.io | Usa un token con **un solo permiso** (`read:packages`): el servidor solo puede descargar |
| `scripts/generar-env.sh` | Crea el `.env` con contraseñas al azar | Ninguna contraseña la inventa una persona ni se repite entre servidores |
| `scripts/restaurar-db.sh` | Carga un dump | Levanta solo la base. Pide escribir `SI` en mayúsculas |
| `scripts/deploy.sh` | Descarga, hace backup, migra, levanta y verifica | **El orden lo hace seguro** (ver 4.3) |
| `scripts/revertir.sh` | Vuelve a la versión anterior | Usa `.deploy-anterior`, que `deploy.sh` guarda. No deshace migraciones |
| `scripts/03-ssl.sh` | Instala nginx y pide el certificado | Comprueba antes que el DNS apunte al servidor (Let's Encrypt limita los intentos fallidos) |
| `scripts/backup.sh` | Backup local de la base y los archivos subidos | Lo usa `deploy.sh` antes de migrar, para poder volver |
| `scripts/backup-externo.sh` | Backup cifrado a Backblaze B2, sin pasar por el disco | Ver 4.3 |
| `scripts/metabase-usuario.sh` | Crea un usuario de solo lectura para Metabase | Metabase puede consultar pero no modificar la base |
| `docs/` | `decisiones.md`, `operacion.md`, `publicar-version.md`, `flujo-de-trabajo.md`, `pruebas.md` | Un servidor sin documentación se vuelve un misterio a los tres meses |

### 4.3 Las decisiones más importantes y sus alternativas

| Decisión | Alternativa que se descartó | Por qué |
|---|---|---|
| **Construir las imágenes en GitHub** y que el servidor las descargue | Construir en el servidor (como se hizo al principio) | En un servidor de 1 GB, el build **se quedó sin memoria** y tardaba unos 20 minutos con el sitio lento. Ahora actualizar toma segundos y alcanza con 1 GB |
| **Imágenes con versión** (`v1.2.0`) | Desplegar "lo último de master" | Se sabe exactamente qué corre y se puede volver atrás en segundos. Las etiquetas `master` y `sha-...` son solo para probar |
| **ghcr.io** como registro | Docker Hub; el registro de DigitalOcean | Mismos permisos que el código, sin secretos extra (usa el `GITHUB_TOKEN`). Docker Hub gratis permite un solo repo privado y hacen falta dos |
| **Frontend como imagen nginx** | Copiar los archivos por SSH; usar Vercel | Se despliega y se revierte igual que el backend. Copiar por SSH obliga a guardar una llave a producción en GitHub; Vercel obliga a separar dominios (CORS, cookies) |
| **Deploy manual** (`deploy.sh` en el servidor) | Que GitHub entre por SSH al crear el tag | Con el deploy manual GitHub **nunca tiene acceso al servidor**. Además una persona decide cuándo salir |
| **Descargar antes de tocar nada** | Frenar primero y descargar después | Si una versión no existe o no terminó de publicarse, el sistema que está corriendo no se entera |
| **Backup antes de migrar** | Migrar directo | Las migraciones pueden borrar o transformar datos |
| **Registrar la versión al final** | Escribirla al empezar | Si algo falla a mitad, el `.env` sigue como estaba |
| **Los datos se cargan antes del primer deploy** | Desplegar y después cargar el dump | Las migraciones corren solo las que faltan. Con la base vacía corrían las 51 desde cero y el dump las pisaba después |
| **nginx en el servidor** (no en un contenedor) | nginx dentro de Docker | Se integra directo con certbot (renovación), con fail2ban (lee `/var/log/nginx`) y con UFW, y se actualiza con el sistema |
| **Servidor preparado con cloud-init** | Entrar como root y correr el script | No se usa root, y se evitan los errores de la preparación manual |
| **Backups cifrados, fuera del servidor, en otra empresa** | Backups en el mismo disco | Si se pierde el servidor se pierden con él; y quien entre podría leerlos o borrarlos. El servidor solo tiene la clave **pública** de `age` (cifra, no descifra) y una llave de B2 de **solo escritura** |
| **Metabase: solo se publica el tablero embebido** | Publicarlo entero | El login y la administración responden 404 desde internet y se usan por túnel SSH. Solo `/metabase/embed/` y lo que necesita el tablero queda visible |
| **Un solo BaseInfra para testing y producción** | Un repo por entorno | Lo único que cambia es el `.env` y el servidor: lo que se prueba en testing es lo mismo que se publica |

---

## 5. Qué corre solo en GitHub

| Repo | Workflow | Cuándo | Qué hace |
|---|---|---|---|
| BaseBack | **Publicar imagen** | Tag `vX.Y.Z`, push a `master`, a mano | Verifica las migraciones y publica la imagen en ghcr.io |
| BaseBack | **Verificar migraciones** | PR o push que toca migraciones | Revisa los nombres |
| BaseBack | **Pruebas** | Cada PR y push a `master` | Compila, verifica migraciones, tests unitarios y de integración |
| BaseFront | **Publicar imagen** | Tag `vX.Y.Z`, push a `master`, a mano | Publica la imagen |
| BaseFront | **Verificar** | Cada PR y push a `master` | `yarn lint` y `yarn build` |
| BaseInfra | — | — | No tiene workflows. Se prueba como cuenta la guía `docs/pruebas.md` |

Versiones publicadas hasta hoy: `v1.0.0` y `v1.1.0`, en el backend y en el frontend.

---

## 6. Qué conviene hacer después

En orden de importancia:

1. **Revocar el certificado de AFIP** que está versionado en BaseBack y generar uno nuevo sin subirlo a git.
2. **Activar los backups** en producción (DigitalOcean y Backblaze B2): hoy no hay copias fuera del servidor.
3. **Armar el VPS de testing** y probar ahí cada versión antes de producción.
4. **Revisar el patrón de `catch`** del backend (unos 470 lugares).
5. **Corregir los tipos y los dos hooks** del frontend, con tests o probando a mano con el checklist.
6. **Revisar el `onSuccess` que nunca se llamaba** en `seleccion-items-facturar`.
7. Sacar de BaseBack los archivos que sobran (`node_modules/.yarn-integrity`, `package-lock.json`) y definir un solo gestor de paquetes.

---

## 7. Glosario

| Término | Qué es |
|---|---|
| **Imagen** | Un paquete con la aplicación y todo lo que necesita para correr. Se arma una vez y se copia a cualquier servidor |
| **Contenedor** | Una imagen corriendo |
| **Registro** (*registry*) | El lugar donde se guardan las imágenes. Acá: ghcr.io, el de GitHub |
| **Tag** | La etiqueta de una versión. En git marca un commit; en el registro, una imagen |
| **Migración** | Un archivo que cambia la estructura de la base (crea una tabla, agrega una columna). TypeORM anota las que ya corrieron |
| **Healthcheck** | Una comprobación que dice si un servicio ya está listo. La base lo usa para que el backend espere |
| **cloud-init** | El mecanismo de los proveedores para ejecutar un script la primera vez que arranca un servidor |
| **Proxy inverso** | nginx recibiendo los pedidos de internet y repartiéndolos al backend o al frontend |
| **PR** | *Pull request*: la propuesta de un cambio, que se revisa antes de mezclarlo a `master` |
