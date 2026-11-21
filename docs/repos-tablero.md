# Los repos Tablero*: la línea nueva del sistema

`TableroDistribuidoraBack` y `TableroDistribuidoraFront` son **el mismo sistema** que BaseBack y BaseFront, con las actualizaciones más nuevas. BaseInfra sirve a las dos líneas: lo único que cambia es el nombre de las imágenes, y se elige en el `.env`.

| | Línea de siempre | Línea nueva |
|---|---|---|
| Repos | `BaseBack` / `BaseFront` | `TableroDistribuidoraBack` / `TableroDistribuidoraFront` |
| `BACKEND_IMAGE` | `baseback` (por defecto) | `tablerodistribuidoraback` |
| `FRONTEND_IMAGE` | `basefront` (por defecto) | `tablerodistribuidorafront` |
| Estadísticas | Metabase (servicio aparte) | Tableros propios con ECharts, dentro del sistema |
| Migraciones | 53 | 73 |

Si no definís nada, todo sigue funcionando como antes.

## Qué trae la línea nueva (y qué cambia en el servidor)

- **Tableros propios.** Los 6 tableros de Metabase más un constructor ("Mis tableros"), dibujados en el front. **No hace falta Metabase**: el servicio queda opcional (perfil `metabase`, apagado por defecto) y las variables `METABASE_*` no se usan.
- **El backend refresca solo la tabla de ventas** (`tablero_venta_item`) cada 2 horas. Se cambia con `TABLEROS_REFRESCO_MINUTOS` (`0` = nunca).
- **Seeds cerrados.** Los `/api/seed-*/execute` responden 404 salvo con `HABILITAR_SEEDS=true`. En producción dejalo **vacío**. La contraseña del Root que crea el seed sale de `SEED_ROOT_PASSWORD` (mínimo 12 caracteres).
- **IA apagada.** `IA_HABILITADA=false`: el botón de análisis necesita Ollama, que no corre en el servidor.
- **Collation.** Todo usa `utf8mb4_0900_ai_ci` (servidor, base, tablas, vistas y la conexión del backend). Con eso `mysqldump` vuelca las vistas sin error, que era lo que rompía el backup. `mysql/conf.d/produccion.cnf` lo deja explícito.

Las variables nuevas están en `.env.example`; el compose las pasa con valores seguros por defecto.

## Cómo desplegar la línea nueva

1. En el `.env`: `BACKEND_IMAGE=tablerodistribuidoraback` y `FRONTEND_IMAGE=tablerodistribuidorafront`.
2. `bash scripts/02-registro.sh` (prueba que el token lea esas imágenes).
3. **Cargá un dump antes del primer deploy**, como siempre (`restaurar-db.sh`).
4. `bash scripts/deploy.sh <tag-back> <tag-front>`.

### ⚠️ La migración `DeleteOrdenPagoPersonal1788902138107` y el espacio en el `name`

En el código de la línea nueva esa migración tiene **un espacio al final del `name`** (`'DeleteOrdenPagoPersonal1788902138107 '`), igual que en la base real. Consecuencias:

- **No hagas el `UPDATE` que quita el espacio** (el paso "Corregir la migración con espacio" de las guías de BaseBack). Con esta línea el código y la base ya coinciden; si lo sacás, TypeORM da la migración por no ejecutada y la **vuelve a correr: borra tablas**.
- **Usá el dump original**, el que tiene el nombre con el espacio. El dump "corregido" es solo para BaseBack.
- **Una base vacía no sirve:** con el espacio, TypeORM ordena esa migración *primera* y falla (`Unknown table item_forma_orden_pago_personal`). Probado. Siempre se arranca de un dump.

La solución de fondo (sacar el espacio del código **y** hacer el `UPDATE` en la base real) es una decisión del equipo del sistema; hasta entonces, se respeta como está.

### No se puede pasar una base de una línea a la otra

Las dos líneas se separan en la migración `1791469170206`: en BaseBack es `add-vistas-estadisticas` y en la nueva es `add-forma-pago-anticipo-sueldo`. Una base que ya corrió la de BaseBack no es compatible con el código nuevo. Para probar la línea nueva se carga un dump anterior a esa migración, en un servidor limpio.

## Qué se probó (en local, con las imágenes construidas desde los repos)

- Imagen del backend: usuario `node`, sin `.d.ts` en `dist/`, con `src/assets` y `tessdata`, arranca y responde `GET /api` 200.
- Dump original + código nuevo: corren las **24 migraciones pendientes** sin errores.
- `mysqldump` de toda la base (22 vistas): sin errores.
- Imagen del frontend: 55 MB, rutas de la SPA caen en `index.html`, `index.html` sin caché, API relativa `/api`.

No se probó contra un servidor real con nginx y HTTPS.

## Pendientes de los repos Tablero*

- `certs/AFIP.crt`, `certs/privada` y `.env-temp` están **versionados**: hay que rotar el certificado y limpiar el historial.
- `deploy.yml` (frontend) es el método viejo: compila y sube `dist` por SCP con una clave SSH guardada en GitHub. Conviene retirarlo para que el único camino sea la imagen.
- El frontend tiene 4 errores de lint y 455 avisos.
