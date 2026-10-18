# Datos de demostración

> **Desde el 18/10/2026 la base tiene la carga de `06_carga_completa/`**, que borró todo lo
> cargado por `00_` a `05_` y lo reemplazó por seis meses de operación. Esos archivos quedan
> como historia; ver `06_carga_completa/README.md`.

**Esto NO son migraciones y no se aplican solas.** Están fuera de
`supabase/migrations/` a propósito: una migración corre en cada despliegue, y
sembrar clientes y precios inventados en cada despliegue sería un error.

Son los datos con los que se recorre el sistema para el TCC: sirven para ver
la agenda con turnos, el ranking con diferencias reales entre barberos y el
portal del cliente con historial.

## Orden

| Archivo | Qué carga |
|---|---|
| `00_usuarios_de_prueba.sql` | Enlaza las cuatro cuentas de Auth (una por rol) con su ficha de `usuarios`, y crea la de `profesionales` del barbero y la de `clientes` del cliente |
| `01_catalogo.sql` | Servicios, categorías, productos, proveedores, la receta de dos servicios y los datos de la barbería |
| `02_operacion.sql` | 15 clientes, 6 barberos, ~95 turnos completados de los últimos 3 meses, cobros, facturas, comisiones, cancelaciones y la agenda de la semana |
| `03_jornada_de_hoy.sql` | Los turnos del día en curso, que es lo primero que muestra la agenda |
| `04_septiembre_octubre.sql` | Cargado el 15/10/2026 para la defensa: ~160 turnos completados del 1/9 al 14/10 con sus cobros, insumos y comisiones, ~50 turnos hasta el 31/10, y cierra los turnos viejos que habían quedado pendientes. Depende de `now()`: ver su encabezado |
| `05_junio_agosto.sql` | Cargado después de `04_`: suma turnos a junio, julio y agosto para que el gráfico de ingresos no muestre un salto de 4 veces en septiembre |

Las cuentas de Auth (`auth.users`) hay que crearlas antes; `00_` solo las
enlaza. Ver la sección «Cuentas de prueba» de `CLAUDE.md`.

## Cómo se aplican

Con el mismo método que las migraciones (sección 1 de `CLAUDE.md`), pero sin
el `rollback`. **Conviene probarlos primero dentro de una transacción que se
revierte**, que es como se encontraron los tres errores que tenían:
`fecha_nacimiento` sin castear, las fechas construidas en UTC cuando
`trg_cita_validar` compara contra la hora local de Asunción, y los estados de
`pedidos`, que la migración 7 cambió a `pedido/recibido/completado/cancelado`.

## Los tres son idempotentes

Cada uno comprueba antes si ya hay datos y no hace nada si los encuentra.
Volver a ejecutarlos no duplica nada.

## Por qué no insertan `historial_servicio` ni `pagos_profesional`

Porque los genera la base. `trg_cita_completada_after_update` corre cuando una
cita pasa a `completado` y, por cada línea del detalle, crea su fila de
historial y calcula la comisión con el porcentaje del barbero. Por eso cada
turno del pasado recorre el ciclo real —`en_proceso` → detalle → `completado`—
en lugar de insertarse ya cerrado: escribir esas filas a mano daría números
que no se corresponden con el porcentaje de cada barbero y dejaría sin probar
el disparador que importa.
