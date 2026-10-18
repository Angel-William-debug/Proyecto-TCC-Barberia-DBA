# Carga completa de prueba (18/10/2026)

Reemplaza todo lo anterior (`00_` a `05_`): borra los datos de prueba y carga seis meses de
operación coherente, del 18/4 al 17/10/2026, más los turnos hasta el 29/11. **No es una
migración.** Se ejecuta a mano y una sola vez.

## Qué queda y qué se borra

- **Queda:** roles, configuración de la barbería, horarios, métodos de pago y las cuentas
  de `usuarios`, con su misma contraseña.
- **Se borra todo lo demás**, con `truncate ... restart identity`.
- **Copia previa:** antes de ejecutarlo, los datos se copiaron a JSON en una carpeta local,
  fuera de los repositorios.

## Qué carga

| Qué | Cuántos |
|---|---|
| Cuentas | 3 administradores, 5 recepcionistas, 10 barberos y 28 clientes, todas con `BarberTCC2026!` |
| Barberos | 12. Uno entró en junio, otro en agosto, otro solo trabaja viernes y sábado, y otro se fue en septiembre |
| Clientes | 200, con barbero preferido y frecuencia propia. 55 sin correo, 4 desactivados |
| Catálogo | 20 servicios en 5 categorías, 40 productos en 6 categorías y 8 proveedores |
| Recetas | 70 líneas de receta en 20 servicios |
| Turnos pasados | ~3.200: 86 % completados, 7 % cancelados (con motivo, o desde el portal), 7 % no asistió |
| Turnos futuros | ~430, más cerca del día más llenos |
| Generado por la base | ~2.600 servicios realizados con su comisión (las anteriores a octubre, liquidadas) y ~9.800 consumos de insumos con su movimiento |
| Cobros y facturas | ~2.460 cobros (56 en dos partes, 20 sin cobrar en la última semana) y ~840 facturas |
| Compras | 38 órdenes (dos en camino) con sus pagos, 19 conteos de inventario y mermas mensuales |
| Calificaciones y motor | 240 valoraciones (solo clientes con cuenta) y recomendaciones para 100 clientes |
| Notificaciones | ~2.400: un recordatorio por turno reservado con anticipación, y avisos a la app |
| Auditoría | ~2.500 registros, todos con el usuario que hizo la acción |

## Cómo está hecho para que tenga sentido

- **Una línea de tiempo por barbero y por día.** Respeta el horario (9 a 20, domingo
  cerrado) y el recreo de 12 a 14, sin superposiciones: la base solo controla los choques
  entre turnos vigentes, así que en el pasado había que cuidarlo a mano.
- **Más turnos según el día:** los sábados más, los lunes menos, y el movimiento crece
  mes a mes.
- **Los clientes vuelven a su barbero:** siete de cada diez veces van al que prefieren, y
  nadie vuelve antes de diez días.
- **Cada turno sigue el camino del mostrador:**
  1. Se inserta; los pasados entran como `no_asistio`, porque la base no deja agendar en el
     pasado.
  2. Se completa con un UPDATE: el disparador genera historial, comisión y auditoría.
  3. Consume los insumos de la receta: el disparador descuenta el stock y deja el
     movimiento.
  4. Se cobra.
- **Compras:** los lunes se pide a cada proveedor lo que bajó del 40 % del máximo, los
  jueves llega (el disparador suma el stock) y se paga a los 10 días. Tres pausas de
  reposición generan alertas que después se resuelven. El aceite para barba y el peine
  quedan críticos al final.
- **Precios:** subieron 10 % en agosto. Las facturas viejas tienen el precio viejo.
- **La auditoría tiene autor:** `carga_demo.actor()` fija `request.jwt.claims`, así
  `auth.uid()` devuelve a la recepcionista o al administrador de turno.
- **Las fechas son las del evento simulado.** Lo que crean los disparadores sale con
  `now()`, que es el mismo en toda la transacción. `carga_demo.reloj()` le pone la hora
  simulada apenas termina cada paso.
- **No se manda ningún aviso.** Las notificaciones históricas entran como ya enviadas: un
  aviso `expo` en estado `pendiente` dispararía un push real.

## Cómo se ejecuta

1. `node crear-cuentas.mjs <apps/web/.env.local> cuentas.json` crea las cuentas de Auth, ya
   confirmadas y sin correo. Lee la clave de servicio sin imprimirla.
2. `node correr.mjs prueba` corre todo en una transacción con `rollback` e imprime la
   verificación (`verificar.sql`). Tarda unos 30 segundos, por debajo del límite de 2
   minutos de la API de Supabase.
3. `node correr.mjs real` hace lo mismo con `commit`.
4. Al final: `drop schema carga_demo cascade`.

`CORREO_ANGEL` y `CORREO_WILLIAM` reemplazan los correos reales en esta copia pública. La
copia ejecutada, con los correos, quedó en la carpeta local de respaldos.

## Lo que deja pausado

**El recordatorio por correo.** Con cientos de turnos futuros de clientes inventados, el
recordatorio automático mandaría cientos de correos a direcciones que no existen, y Brevo
gratis permite 300 por día. Para reactivarlo:

```sql
select cron.alter_job(jobid, active := true) from cron.job where jobname = 'recordatorios-turnos';
```

Los avisos del teléfono (los recordatorios locales de la app y los push al confirmar,
cancelar o reprogramar) siguen funcionando.
