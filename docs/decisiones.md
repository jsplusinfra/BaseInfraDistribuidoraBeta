# Decisiones de despliegue

Por qué el sistema se despliega con imágenes publicadas por GitHub Actions, y qué alternativas se descartaron. Sirve para entender el diseño antes de cambiarlo.

## El problema: construir en el servidor

La primera versión de BaseInfra hacía todo dentro del VPS: `deploy.sh` clonaba BaseBack y BaseFront, corría `yarn install`, `nest build` y `vite build`, y armaba las imágenes ahí mismo. En el primer despliegue real (droplet de 1 GB, octubre de 2026):

- El build del frontend se quedó sin memoria (`JavaScript heap out of memory`). Hubo que subir el límite de Node y construir las imágenes de a una.
- El deploy tardó **unos 20 minutos**, con la CPU saturada (carga 9,8 en un núcleo) y el sitio lento mientras tanto.
- El servidor necesitaba deploy keys de los repos de código y tenía el código fuente en el disco.
- Lo que se desplegaba era "lo último de master" en ese momento: no había versiones, y volver atrás implicaba volver a construir.

## La decisión: construir afuera, descargar adentro

| | Antes: build en el VPS | Ahora: imágenes en un registro |
|---|---|---|
| Dónde se compila | En el VPS | En GitHub Actions |
| Duración del deploy | ~20 min, con el sitio lento | Segundos (1-2 min la primera vez, por las migraciones) |
| RAM necesaria en el VPS | 2 GB recomendado (1 GB con swap y ajustes) | 1 GB alcanza |
| Qué hay en el VPS | BaseInfra + BaseBack + BaseFront | Solo BaseInfra |
| Qué se despliega | Lo que haya en master | Una versión exacta (`v1.3.0`) |
| Volver atrás | Reconstruir otra versión | `revertir.sh`, en segundos |
| Acceso del VPS a GitHub | Deploy keys de los repos de código | Token de **solo lectura** de imágenes |

Medido en una prueba local con el `deploy.sh` nuevo: actualizar de una versión a otra (backup incluido) tardó **7 segundos**, y el primer deploy sobre una base vacía (50 migraciones) **1,5 minutos**.

## Por qué en GitHub Actions y no desde una PC

Construir en la PC de alguien y subir la imagen también saca la carga del VPS, pero:

- Si hay cambios sin commitear, se cuelan en la imagen sin que nadie se entere.
- Solo puede publicar quien tiene la máquina configurada.
- No queda registro de qué código exacto generó cada imagen.

Con Actions, cada imagen sale del código exacto de un tag. El workflow es parte del repo y cualquiera del equipo puede publicar con un `git push` del tag.

## Por qué GitHub Container Registry (ghcr.io)

| Opción | A favor | En contra |
|---|---|---|
| **ghcr.io** (elegido) | Mismo GitHub y mismos permisos que el código. Publica con el `GITHUB_TOKEN` del workflow, sin secretos extra. Según la documentación de GitHub, hoy el almacenamiento y la transferencia de contenedores son gratis, con aviso de un mes antes de cualquier cambio | Para descargar hace falta un token clásico `read:packages` |
| Docker Hub | El más conocido | El plan gratis permite **un** repo privado y hacen falta dos. Y no pueden ser públicos: la imagen del backend tiene el código adentro |
| DigitalOcean Container Registry | Cerca del droplet: descargas rápidas | Otro proveedor más con sus credenciales; el plan gratis es chico; ata el despliegue a DigitalOcean |

Las imágenes pesan ~557 MB (backend: Node, dependencias y datos de OCR) y ~55 MB (frontend). Si GitHub empieza a cobrar el almacenamiento, alcanza con borrar las versiones viejas de los paquetes.

## Por qué el frontend también va en Docker

El frontend es un build estático de Vite, así que Docker no es imprescindible. Se evaluaron tres opciones:

| | A. Imagen nginx (elegido) | B. Estáticos copiados por SSH | C. Vercel / Cloudflare Pages |
|---|---|---|---|
| Mecanismo | El mismo que el backend | Uno distinto | Uno distinto |
| Volver atrás | Cambiar la versión, igual que el backend | Hay que guardar builds viejos a mano | Fácil, pero por separado |
| Seguridad | GitHub no entra al servidor | GitHub guarda una **llave SSH a producción** | GitHub no entra al servidor |
| Dominio y `/api` | Igual que hoy | Igual que hoy | Separar dominios: CORS, cookies y orígenes de Google |

La C es la más rápida para el usuario final (CDN), y queda como mejora futura si crece el tráfico.

## Por qué el despliegue es manual

Se podría desplegar automáticamente al crear el tag (GitHub entrando por SSH al VPS), pero eso guarda una llave a producción en GitHub: quien comprometa el repo o una dependencia del workflow entra al servidor. Con el deploy manual, el servidor **saca** las imágenes y GitHub nunca tiene acceso a él. Además, alguien decide cuándo salir (por ejemplo, fuera del horario de facturación).

## Por qué las migraciones corren con la misma imagen

Antes había una tercera imagen (`migrate`) con `ts-node` y el código fuente. Ahora `nest build` compila también `orm.config.ts` y las migraciones, así que la imagen de producción las corre con `node node_modules/typeorm/cli.js migration:run -d dist/orm.config.js`. Una imagen menos para publicar, y las migraciones siempre coinciden con el código desplegado.

Para que funcione, `tsconfig.build.json` desactiva los `.d.ts`: el patrón de migraciones (`*{.ts,.js}`) también los tomaba y Node no puede ejecutarlos.

## Por qué BaseInfra sigue siendo un repo

Las imágenes traen la aplicación, pero no cómo se arma el servidor: qué contenedores corren y cómo se conectan (compose), el dominio y el HTTPS (nginx), los backups y el despliegue (scripts). Como repo de git, cada cambio de infraestructura queda en el historial, se puede revisar en una PR, se actualiza con `git pull` y se puede revertir.

## Qué no viaja nunca en las imágenes

- Secretos de la aplicación: solo en el `.env` del servidor (permisos 600).
- Certificado y clave de AFIP: en `secrets/afip/`, montados como solo lectura al arrancar.
- `.env-temp`, `certs/` y dumps commiteados en BaseBack: excluidos por `.dockerignore` (verificado con `docker history`).
- Las variables `VITE_*` del frontend **sí** quedan grabadas en el JavaScript. Por eso nunca pueden ser secretos. Hoy la única es `VITE_API_URL=/api`.
