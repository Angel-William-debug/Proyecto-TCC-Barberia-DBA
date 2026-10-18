select json_build_object(
 'citas_por_mes', (select json_object_agg(mes, x) from (select mes, json_object_agg(estado, n) x from (select to_char(fecha_hora at time zone 'America/Asuncion','YYYY-MM') mes, estado, count(*) n from public.citas group by 1, 2) y group by 1) z),
 'ingresos_por_mes', (select json_object_agg(mes, total) from (select to_char(fecha_pago at time zone 'America/Asuncion','YYYY-MM') mes, sum(monto)::bigint total from public.cobros_cliente where estado in ('pagado','parcial') group by 1 order by 1) x),
 'historial', (select count(*) from public.historial_servicio),
 'historial_sin_cita_completada', (select count(*) from public.historial_servicio h join public.citas c using (id_cita) where c.estado <> 'completado'),
 'comisiones', (select json_object_agg(estado, n) from (select estado, count(*) n from public.pagos_profesional group by 1) x),
 'comision_pendiente_vieja', (select count(*) from public.pagos_profesional p join public.historial_servicio h using (id_historial) where p.estado = 'pendiente' and h.fecha_realizacion < '2026-10-01'),
 'cobros', (select json_object_agg(estado, n) from (select estado, count(*) n from public.cobros_cliente group by 1) x),
 'completados_sin_cobro', (select count(*) from public.citas c where c.estado = 'completado' and not exists (select 1 from public.cobros_cliente k where k.id_cita = c.id_cita)),
 'cobro_excede', (select count(*) from public.citas c where (select coalesce(sum(monto), 0) from public.cobros_cliente k where k.id_cita = c.id_cita and k.estado in ('pagado','parcial')) > c.total),
 'facturas', (select count(*) from public.facturas),
 'factura_total_distinto', (select count(*) from public.facturas f where f.total <> (select sum(subtotal) from public.detalle_factura d where d.id_factura = f.id_factura)),
 'insumos', (select count(*) from public.productos_utilizados),
 'excepciones', (select count(*) from public.productos_utilizados where excepcion_stock),
 'movs', (select json_object_agg(tipo, n) from (select tipo, count(*) n from public.movimientos_inventario group by 1) x),
 'pedidos', (select json_object_agg(estado, n) from (select estado, count(*) n from public.pedidos group by 1) x),
 'pagos_prov', (select count(*) from public.pagos_proveedor),
 'pago_prov_excede', (select count(*) from public.pedidos p where (select coalesce(sum(monto), 0) from public.pagos_proveedor x where x.id_pedido = p.id_pedido) > p.total),
 'notif', (select json_object_agg(tipo || '/' || estado_envio, n) from (select tipo, estado_envio, count(*) n from public.notificaciones group by 1, 2) x),
 'notif_expo_pendiente', (select count(*) from public.notificaciones where proveedor = 'expo' and estado_envio = 'pendiente'),
 'valoraciones', (select json_object_agg(puntaje, n) from (select puntaje, count(*) n from public.valoraciones group by 1) x),
 'valoracion_cliente_sin_cuenta', (select count(*) from public.valoraciones v join public.clientes c using (id_cliente) where c.id_usuario is null),
 'alertas', (select json_object_agg(resuelta, n) from (select resuelta, count(*) n from public.alertas_stock group by 1) x),
 'recomendaciones', (select count(distinct id_cliente) || ' clientes, ' || count(*) || ' filas' from public.recomendaciones_ml),
 'auditoria', (select count(*) filter (where id_usuario is not null) || ' con usuario de ' || count(*) from public.auditoria),
 'fechas_de_carga', (select count(*) from public.historial_servicio where created_at > now() - interval '1 hour')
   + (select count(*) from public.movimientos_inventario where fecha > now() - interval '1 hour')
   + (select count(*) from public.auditoria where fecha_accion > now() - interval '1 hour')
   + (select count(*) from public.alertas_stock where fecha_alerta > now() - interval '1 hour'),
 'superpuestos', (select count(*) from public.detalle_cita a join public.citas ca on ca.id_cita = a.id_cita
    join public.detalle_cita b2 on b2.id_profesional = a.id_profesional and b2.id_cita < a.id_cita
    join public.citas cb on cb.id_cita = b2.id_cita
    where ca.estado <> 'cancelado' and cb.estado <> 'cancelado' and ca.fecha_hora::date = cb.fecha_hora::date
      and tstzrange(ca.fecha_hora, ca.fecha_hora + make_interval(mins => a.duracion_min))
       && tstzrange(cb.fecha_hora, cb.fecha_hora + make_interval(mins => b2.duracion_min))),
 'fuera_de_horario', (select count(*) from public.citas
    where (fecha_hora at time zone 'America/Asuncion')::time < '09:00' or (fecha_hora at time zone 'America/Asuncion')::time >= '20:00'
       or extract(dow from fecha_hora at time zone 'America/Asuncion') = 0
       or ((fecha_hora at time zone 'America/Asuncion')::time >= '12:00' and (fecha_hora at time zone 'America/Asuncion')::time < '14:00')),
 'stock', (select json_build_object('negativos', count(*) filter (where stock_actual < 0), 'criticos', count(*) filter (where stock_actual <= stock_minimo), 'sin_stock', count(*) filter (where stock_actual <= 0)) from public.productos),
 'stock_bajo', (select json_object_agg(nombre, stock_actual || ' (min ' || stock_minimo || ', max ' || stock_maximo || ')') from public.productos where stock_actual <= stock_minimo * 1.3),
 'turnos_por_barbero', (select json_object_agg(nombre, n) from (select p.nombre, count(distinct d.id_cita) n from public.detalle_cita d join public.profesionales p using (id_profesional) group by 1) x),
 'futuros', (select json_object_agg(estado, n) from (select estado, count(*) n from public.citas where fecha_hora > now() group by 1) x),
 'mis_cuentas', (select json_object_agg(cl.email, json_build_object(
    'pasados', (select count(*) from public.citas c where c.id_cliente = cl.id_cliente and c.fecha_hora < now()),
    'futuros', (select string_agg(c.estado, ',') from public.citas c where c.id_cliente = cl.id_cliente and c.fecha_hora > now()),
    'valoraciones', (select count(*) from public.valoraciones v where v.id_cliente = cl.id_cliente)))
    from public.clientes cl where cl.email in ('cliente@correo.com.py', 'CORREO_ANGEL@gmail.com', 'CORREO_WILLIAM+cliente@gmail.com')),
 'lunes_19_por_barbero', (select json_object_agg(p.nombre, n) from (select d.id_profesional, count(*) n from public.detalle_cita d join public.citas c using (id_cita) where (c.fecha_hora at time zone 'America/Asuncion')::date = '2026-10-19' group by 1) x join public.profesionales p using (id_profesional)),
 'clientes', (select json_build_object('total', count(*), 'con_cuenta', count(id_usuario), 'sin_email', count(*) filter (where email is null),
    'inactivos', count(*) filter (where not estado),
    'sin_turnos', count(*) filter (where not exists (select 1 from public.citas c where c.id_cliente = clientes.id_cliente))) from public.clientes),
 'max_visitas_cliente', (select max(n) from (select id_cliente, count(*) n from public.citas group by 1) x),
 'usuarios', (select json_object_agg(r.nombre, n) from (select id_rol, count(*) n from public.usuarios group by 1) x join public.roles r using (id_rol)),
 'precio_corte_degradado_por_mes', (select json_object_agg(m, p) from (select to_char(c.fecha_hora, 'MM') m, max(d.precio_unit) p from public.detalle_cita d join public.citas c using (id_cita) join public.servicios s using (id_servicio) where s.nombre = 'Corte degradado' group by 1) x)
) verificacion;
