# Publicar una versión

Cómo llega un cambio de código a producción. Sirve para cualquiera del equipo que trabaje en BaseBack o BaseFront.

```
 cambio ──► PR ──► merge a master ──► tag vX.Y.Z ──► GitHub Actions ──► ghcr.io ──► deploy.sh en el VPS
                         │                                                 ▲
                         └──► imagen :master (para probar) ────────────────┘
```

## 1. Del cambio a master

Trabajá en una rama, abrí la PR y mergeá a `master` como siempre. Cada push a `master` publica la imagen **`:master`** (más una `:sha-xxxxxxx`). Sirve para probar en un servidor de pruebas, **nunca para producción**: cambia con cada commit y no se puede volver atrás a "la de ayer".

## 2. Crear la versión

En el repo que cambió (BaseBack o BaseFront):

```bash
git switch master
git pull
git tag v1.3.0
git push origin v1.3.0
```

**Cómo numerar** (semver `vMAYOR.MENOR.PARCHE`):

| Cambio | Ejemplo |
|---|---|
| Corrección sin cambios de comportamiento | `v1.2.0` → `v1.2.1` |
| Funcionalidad nueva o migración de base de datos | `v1.2.1` → `v1.3.0` |
| Cambio incompatible (la otra parte necesita actualizarse sí o sí) | `v1.3.0` → `v2.0.0` |

BaseBack y BaseFront se versionan **por separado**: cada uno tiene su propio número.

Los tags no se reutilizan. Si `v1.3.0` salió mal, se arregla y se publica `v1.3.1`; no borres ni muevas el tag.

## 3. Esperar la imagen

En GitHub → repo → pestaña **Actions** → workflow **"Publicar imagen"**. Tarda unos minutos (menos cuando aprovecha la caché). En verde, la imagen queda en:

- `ghcr.io/jsplusinfra/baseback:v1.3.0`
- `ghcr.io/jsplusinfra/basefront:v1.3.0`

Se ven en tu perfil de GitHub, pestaña *Packages* (`github.com/jsplusinfra?tab=packages`): `jsplusinfra` es una cuenta personal, no una organización. Tienen que figurar como **Private**.

Si el workflow falla, la imagen no se publica y producción no se entera. Revisá el log del paso que falló (casi siempre es un error de compilación que también aparece con `yarn build` en local).

## 4. Desplegar

En el servidor, con las **dos** versiones (la que cambió y la que sigue igual):

```bash
ssh deploy@IP
cd /opt/sistema/BaseInfra
grep _TAG .env                          # versiones actuales
bash scripts/deploy.sh v1.3.0 v1.4.0    # backend frontend
```

`deploy.sh` descarga, hace un backup, corre las migraciones pendientes, levanta las versiones nuevas y verifica que respondan. Si algo sale mal, ver [operacion.md](operacion.md#volver-a-la-versión-anterior).

## Compatibilidad entre backend y frontend

Como se versionan por separado, cuidá el orden cuando un cambio toca a los dos:

- **El backend agrega algo que el frontend va a usar** (endpoint o campo nuevo): desplegá primero el backend y después el frontend. O los dos juntos en el mismo `deploy.sh`.
- **El backend quita o cambia algo que el frontend usa**: primero el frontend que ya no lo usa, después el backend.
- Anotá en la descripción del tag o de la PR con qué versión de la otra parte se probó (por ejemplo: "requiere baseback ≥ v1.3.0").

## Migraciones de base de datos

- Se aplican solas en cada deploy, **antes** de levantar la versión nueva, y siempre después de un backup.
- **No se revierten solas.** Si una versión con migración sale mal, volver a la imagen anterior puede no alcanzar (ver [operacion.md](operacion.md#volver-a-la-versión-anterior)).
- Preferí migraciones que **agregan** (columnas que aceptan `NULL`, tablas nuevas) antes que las que borran o renombran. Así la versión anterior sigue funcionando con la base migrada, y el rollback es seguro.
- Nunca cambies el `name` de una migración ya desplegada (ver el caso del espacio en [operacion.md](operacion.md#cargar-un-dump)).

## Hotfix

1. Rama desde `master`, corrección, PR, merge.
2. `git tag v1.3.1 && git push origin v1.3.1`.
3. `bash scripts/deploy.sh v1.3.1 <front-actual>`.

Si hay que salir ya y el fix no está listo: `bash scripts/revertir.sh` vuelve a las versiones anteriores en segundos.
