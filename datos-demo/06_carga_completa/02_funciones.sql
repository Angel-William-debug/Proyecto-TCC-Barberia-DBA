-- =============================================================================
-- Carga completa de prueba (18/10/2026) · Parte 2: la simulacion dia por dia
-- =============================================================================
-- Cada dia habil se arma, por barbero, una linea de tiempo sin superposiciones
-- (con el recreo de 12 a 14), y cada turno pasa por el mismo camino que en el
-- mostrador: se inserta, se completa (el disparador genera historial,
-- comision y auditoria), consume insumos (descuenta stock y deja el
-- movimiento) y se cobra. Los lunes se piden a los proveedores los productos
-- que bajaron, los jueves llegan (el disparador suma el stock) y despues se
-- pagan. El primer dia habil de cada mes se liquidan las comisiones del mes
-- anterior.
--
-- Todo lo que generan los disparadores sale con la hora de la carga (now() es
-- el mismo en toda la transaccion): carga_demo.reloj() le pone la hora del
-- evento simulado inmediatamente despues de cada paso.
-- =============================================================================

-- Quien esta haciendo la accion: la auditoria lo toma de auth.uid().
create or replace function carga_demo.actor(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$$;

create or replace function carga_demo.personal_al_azar(p_rol text) returns carga_demo.personal language sql as $$
  select * from carga_demo.personal where rol = p_rol order by random() limit 1;
$$;

-- Lo que crearon los disparadores en este paso pasa a la hora del evento.
create or replace function carga_demo.reloj(p timestamptz) returns void language plpgsql as $$
begin
  update public.historial_servicio set created_at = p where created_at = now();
  update public.pagos_profesional set created_at = p where created_at = now();
  update public.auditoria set fecha_accion = p, created_at = p where created_at = now();
  update public.movimientos_inventario set fecha = p, created_at = p where created_at = now();
  update public.alertas_stock set fecha_alerta = p, created_at = p where created_at = now();
end $$;

-- El precio de un servicio en una fecha: en agosto subieron 10 %.
create or replace function carga_demo.precio(p_precio numeric, p_dia date) returns numeric language sql immutable as $$
  select case when p_dia < date '2026-08-01' then round(p_precio / 1.1 / 5000) * 5000 else p_precio end;
$$;

create or replace function carga_demo.elegir_servicios(b carga_demo.barbero, p_dia date) returns int[] language plpgsql as $$
declare
  v_primero carga_demo.servicio;
  v_segundo int;
begin
  select s.* into v_primero
  from carga_demo.servicio s
  where s.hasta is null or p_dia <= s.hasta
  order by -ln(random()) / (s.peso * case
      when s.categoria = b.fuerte then 3
      when b.fuerte = 'Tratamientos' and s.categoria = 'Cortes' then 0.4
      when b.fuerte <> 'Niños' and s.categoria = 'Niños' then 0.5
      else 1 end)
  limit 1;

  -- Uno de cada siete agrega algo de barba o un tratamiento corto.
  if v_primero.categoria in ('Cortes', 'Niños') and random() < 0.15 then
    select s.n into v_segundo from carga_demo.servicio s
    where s.n in (6, 13, 14) and v_primero.categoria = 'Cortes' or (s.n = 14 and v_primero.categoria = 'Niños')
    order by random() limit 1;
  end if;
  return case when v_segundo is null then array[v_primero.n] else array[v_primero.n, v_segundo] end;
end $$;

-- Un cliente para un barbero en un dia: siete de cada diez son de los que lo
-- prefieren; nadie vuelve antes de diez dias.
create or replace function carga_demo.elegir_cliente(b carga_demo.barbero, p_dia date, p_futuro boolean) returns carga_demo.cliente language plpgsql as $$
declare
  v carga_demo.cliente;
  v_pref boolean := random() < 0.7;
begin
  for intento in 1..2 loop
    select c.* into v
    from carga_demo.cliente c join public.clientes pc on pc.id_cliente = c.id_cliente
    where c.desde <= p_dia and pc.estado
      and (not v_pref or c.barbero = b.n)
      and not exists (
        select 1 from public.citas x
        where x.id_cliente = c.id_cliente
          and (case when p_futuro then x.estado in ('pendiente', 'confirmado') and x.fecha_hora > now()
                                    and abs(extract(epoch from x.fecha_hora - p_dia::timestamptz)) < 14 * 86400
                    else x.fecha_hora > (p_dia - 10)::timestamptz and x.fecha_hora < (p_dia + 1)::timestamptz end))
    order by -ln(random()) / c.peso
    limit 1;
    exit when v.id_cliente is not null;
    v_pref := false;
  end loop;
  return v;
end $$;

-- Un turno ya pasado, con todo lo que deja.
create or replace function carga_demo.turno_pasado(b carga_demo.barbero, p_dia date, p_hora time, p_servicios int[]) returns void language plpgsql as $$
declare
  v_cliente carga_demo.cliente;
  v_email text;
  v_ts timestamptz := (p_dia + p_hora) at time zone 'America/Asuncion';
  v_fin timestamptz;
  v_cita int;
  v_estado text;
  v_r float := random();
  v_dur int := 0;
  v_creado timestamptz;
  v_usuario int;
  v_motivo text;
  v_total numeric;
  v_cobro int;
  v_metodo int;
  v_puntaje int;
  s carga_demo.servicio;
  u record;
  v_cant numeric;
  v_n int;
begin
  v_cliente := carga_demo.elegir_cliente(b, p_dia, false);
  if v_cliente.id_cliente is null then return; end if;
  select email into v_email from public.clientes where id_cliente = v_cliente.id_cliente;

  v_estado := case when v_r < 0.86 then 'completado' when v_r < 0.93 then 'cancelado' else 'no_asistio' end;
  v_creado := greatest(v_ts - (0.3 + random() * 8) * interval '1 day', v_cliente.desde::timestamptz);
  v_usuario := case when v_cliente.con_cuenta and random() < 0.5 then null
                    when not v_cliente.con_cuenta and random() < 0.12 then null
                    else (carga_demo.personal_al_azar('recepcionista')).id_usuario end;
  if v_estado = 'cancelado' then
    v_motivo := case when v_cliente.con_cuenta and v_usuario is null and random() < 0.6 then null
                     else (array['El cliente avisó que no puede venir', 'Reprogramó por un viaje', 'Se enfermó',
                                 'Le surgió un compromiso de trabajo', 'El barbero se enfermó',
                                 'Corte de luz en el local'])[1 + floor(random() * 6)::int] end;
  end if;

  -- Cancelado entra cancelado; el resto entra como «no asistió» y despues se
  -- completa, porque la base no deja agendar un turno vigente en el pasado.
  insert into public.citas (id_cliente, id_usuario, fecha_hora, estado, observaciones, motivo_cancelacion, created_at, updated_at)
  values (v_cliente.id_cliente, v_usuario, v_ts,
          case when v_estado = 'cancelado' then 'cancelado' else 'no_asistio' end,
          case when random() < 0.08 then (array['Prefiere que lo atienda temprano', 'Viene con su hijo',
                 'Quiere probar un degradado más alto', 'Pidió que le recuerden por WhatsApp',
                 'Primera vez en la barbería'])[1 + floor(random() * 5)::int] end,
          v_motivo, v_creado, v_ts)
  returning id_cita into v_cita;

  foreach v_n in array p_servicios loop
    select * into s from carga_demo.servicio where n = v_n;
    insert into public.detalle_cita (id_cita, id_servicio, id_profesional, duracion_min, precio_unit, subtotal, created_at)
    values (v_cita, s.id_servicio, b.id_profesional, s.dur, carga_demo.precio(s.precio, p_dia),
            carga_demo.precio(s.precio, p_dia), v_creado);
    v_dur := v_dur + s.dur;
  end loop;
  v_fin := v_ts + make_interval(mins => v_dur);

  -- Recordatorio del dia anterior, si reservo con tiempo.
  if v_creado < v_ts - interval '1 day' then
    insert into public.notificaciones (id_cita, id_usuario, tipo, mensaje, email_destino, estado_envio, fecha_envio, proveedor, intentos, created_at)
    values (v_cita, v_cliente.id_usuario, 'recordatorio',
            case when v_email is null then 'Sin correo registrado: no se pudo enviar el recordatorio.'
                 when random() < 0.025 then 'Brevo respondió 502: error temporal del servidor'
                 else 'Recordatorio: su turno es el ' || to_char(v_ts at time zone 'America/Asuncion', 'DD/MM "a las" HH24:MI') end,
            v_email,
            case when v_email is null then 'sin_email' else 'enviado' end,
            case when v_email is null then null else v_ts - interval '1 day' + random() * interval '10 minutes' end,
            'brevo', case when v_email is null then 0 else 1 end,
            v_ts - interval '1 day');
    -- Uno de cada cuarenta fallo tres veces.
    update public.notificaciones set estado_envio = 'fallido', intentos = 3, fecha_envio = null
    where id_cita = v_cita and estado_envio = 'enviado' and mensaje like 'Brevo%';
  end if;

  -- Avisos a la app de los clientes con cuenta.
  if v_cliente.con_cuenta and v_estado <> 'cancelado' and random() < 0.6 then
    insert into public.notificaciones (id_cita, id_usuario, tipo, mensaje, estado_envio, fecha_envio, proveedor, created_at)
    values (v_cita, v_cliente.id_usuario, 'turno_confirmado',
            'La barbería confirmó su turno del ' || to_char(v_ts at time zone 'America/Asuncion', 'DD/MM/YYYY "a las" HH24:MI') || '. ¡Lo esperamos!',
            case when random() < 0.35 then 'enviado' else 'sin_dispositivo' end,
            v_creado + interval '2 hours', 'expo', v_creado + interval '2 hours');
  elsif v_cliente.con_cuenta and v_estado = 'cancelado' and v_motivo in ('El barbero se enfermó', 'Corte de luz en el local') then
    insert into public.notificaciones (id_cita, id_usuario, tipo, mensaje, estado_envio, fecha_envio, proveedor, created_at)
    values (v_cita, v_cliente.id_usuario, 'turno_cancelado',
            'La barbería canceló su turno del ' || to_char(v_ts at time zone 'America/Asuncion', 'DD/MM/YYYY "a las" HH24:MI') || '. Puede reservar otro desde la app.',
            case when random() < 0.35 then 'enviado' else 'sin_dispositivo' end,
            v_ts - interval '3 hours', 'expo', v_ts - interval '3 hours');
  end if;

  if v_estado <> 'completado' then return; end if;

  -- Completar: historial, comision y auditoria los hace el disparador.
  update public.citas set estado = 'completado' where id_cita = v_cita;
  perform carga_demo.reloj(v_fin);

  -- Insumos de la receta, con la variacion de cada mano.
  for u in
    select h.id_historial, p.id_producto, r.cantidad, pr.uu, x.stock_actual
    from public.historial_servicio h
    join carga_demo.servicio sv on sv.id_servicio = h.id_servicio
    join carga_demo.receta r on r.servicio = sv.n
    join carga_demo.producto pr on pr.n = r.producto
    join public.productos x on x.id_producto = pr.id_producto
    join carga_demo.producto p on p.n = r.producto
    where h.id_cita = v_cita
  loop
    v_cant := case when u.uu in ('unidad', 'aplicación') then u.cantidad
                   else round((u.cantidad * (0.8 + random() * 0.4))::numeric, 1) end;
    if u.stock_actual >= v_cant then
      insert into public.productos_utilizados (id_historial, id_producto, cantidad_usada, excepcion_stock, fecha_uso, created_at)
      values (u.id_historial, u.id_producto, v_cant, false, v_fin, v_fin);
    elsif random() < 0.4 then
      -- CU-007 A1: se completa igual, con la excepcion de stock.
      insert into public.productos_utilizados (id_historial, id_producto, cantidad_usada, excepcion_stock, fecha_uso, created_at)
      values (u.id_historial, u.id_producto, v_cant, true, v_fin, v_fin);
    end if;
  end loop;
  perform carga_demo.reloj(v_fin);

  -- Cobro: en la ultima semana algunos quedan sin cobrar.
  if p_dia >= date '2026-10-12' and random() < 0.15 then return; end if;
  select total into v_total from public.citas where id_cita = v_cita;
  v_metodo := (array[1,1,1,1,1,1,1,1,1,2,2,2,2,3,3,4,4,4,5,5])[1 + floor(random() * 20)::int];
  if random() < 0.03 then
    insert into public.cobros_cliente (id_cita, id_metodo_pago, monto, estado, fecha_pago, created_at)
    values (v_cita, v_metodo, round(v_total / 2 / 1000) * 1000, 'parcial', v_fin + interval '5 minutes', v_fin + interval '5 minutes');
    insert into public.cobros_cliente (id_cita, id_metodo_pago, monto, estado, fecha_pago, created_at)
    values (v_cita, 4, v_total - round(v_total / 2 / 1000) * 1000, 'pagado', v_fin + interval '3 days', v_fin + interval '3 days')
    returning id_cobro into v_cobro;
  else
    insert into public.cobros_cliente (id_cita, id_metodo_pago, monto, estado, fecha_pago, created_at)
    values (v_cita, v_metodo, v_total, 'pagado', v_fin + interval '5 minutes', v_fin + interval '5 minutes')
    returning id_cobro into v_cobro;
  end if;

  -- Factura (comprobante interno) para un tercio.
  if random() < 0.35 then
    with f as (
      insert into public.facturas (id_cliente, id_cita, id_cobro, fecha_emision, subtotal, total, created_at)
      values (v_cliente.id_cliente, v_cita, v_cobro, v_fin + interval '10 minutes', v_total, v_total, v_fin + interval '10 minutes')
      returning id_factura
    )
    insert into public.detalle_factura (id_factura, descripcion, cantidad, precio_unitario, subtotal, created_at)
    select f.id_factura, sv.nombre, 1, d.precio_unit, d.subtotal, v_fin + interval '10 minutes'
    from f, public.detalle_cita d join public.servicios sv on sv.id_servicio = d.id_servicio
    where d.id_cita = v_cita;
  end if;

  -- Valoracion: solo los clientes con cuenta pueden calificar.
  if v_cliente.con_cuenta and random() < 0.6 then
    v_puntaje := greatest(1, least(5, round(b.calidad + (random() - 0.55) * 2.2)));
    insert into public.valoraciones (id_cita, id_cliente, puntaje, comentario, created_at, updated_at)
    values (v_cita, v_cliente.id_cliente, v_puntaje,
            case when random() < 0.45 then case
              when v_puntaje >= 5 then (array['Excelente como siempre', 'El mejor degradado de Asunción', 'Muy prolijo, volveré',
                                              'Atención de primera', 'Quedé conforme, gracias'])[1 + floor(random() * 5)::int]
              when v_puntaje = 4 then (array['Muy buen corte', 'Bien, aunque esperé un poco', 'Buen trabajo con la barba'])[1 + floor(random() * 3)::int]
              when v_puntaje = 3 then (array['Normal', 'Me cortaron más de lo que pedí', 'Tardaron en atenderme'])[1 + floor(random() * 3)::int]
              else (array['No quedé conforme con el corte', 'Llegué a horario y tuve que esperar mucho'])[1 + floor(random() * 2)::int]
            end end,
            v_fin + (6 + random() * 48) * interval '1 hour', v_fin + (6 + random() * 48) * interval '1 hour');
  end if;
end $$;

-- Lunes: pedido a cada proveedor con lo que bajo del 40 % del maximo.
create or replace function carga_demo.pedir(p_dia date) returns void language plpgsql as $$
declare
  v_admin carga_demo.personal := carga_demo.personal_al_azar('administrador');
  v_prov int;
  v_pedido int;
  v_ts timestamptz := (p_dia + time '09:30') at time zone 'America/Asuncion';
begin
  perform carga_demo.actor(v_admin.uid);
  for v_prov in
    select distinct p.proveedor from carga_demo.producto p join public.productos x on x.id_producto = p.id_producto
    where x.stock_actual < p.maximo * 0.4 and (p.no_reponer_desde is null or p_dia < p.no_reponer_desde or p_dia > p.no_reponer_hasta)
      and not exists (select 1 from public.detalle_pedido dp join public.pedidos pe using (id_pedido)
                      where dp.id_producto = p.id_producto and pe.estado = 'pedido')
  loop
    insert into public.pedidos (id_proveedor, id_usuario, fecha_pedido, estado, created_at)
    values (v_prov, v_admin.id_usuario, v_ts, 'pedido', v_ts)
    returning id_pedido into v_pedido;

    insert into public.detalle_pedido (id_pedido, id_producto, cantidad, precio_unit, subtotal, created_at)
    select v_pedido, p.id_producto, ceil((p.maximo - x.stock_actual) / p.equiv),
           round(p.precio * (0.95 + random() * 0.1) / 100) * 100, 0, v_ts
    from carga_demo.producto p join public.productos x on x.id_producto = p.id_producto
    where p.proveedor = v_prov and x.stock_actual < p.maximo * 0.4
      and (p.no_reponer_desde is null or p_dia < p.no_reponer_desde or p_dia > p.no_reponer_hasta)
      and not exists (select 1 from public.detalle_pedido dp join public.pedidos pe using (id_pedido)
                      where dp.id_producto = p.id_producto and pe.estado = 'pedido');
  end loop;
end $$;

-- Jueves: llega lo pedido (el disparador suma el stock); uno de cada 25 se cancela.
create or replace function carga_demo.recibir(p_dia date) returns void language plpgsql as $$
declare
  v record;
  v_ts timestamptz := (p_dia + time '11:00') at time zone 'America/Asuncion';
begin
  for v in select id_pedido, id_usuario from public.pedidos where estado = 'pedido' and fecha_pedido < v_ts loop
    perform carga_demo.actor((select auth_uid from public.usuarios where id_usuario = v.id_usuario));
    if random() < 0.04 then
      update public.pedidos set estado = 'cancelado', updated_at = v_ts where id_pedido = v.id_pedido;
    else
      update public.pedidos set estado = 'recibido', fecha_recepcion = v_ts where id_pedido = v.id_pedido;
      perform carga_demo.reloj(v_ts);
    end if;
  end loop;
end $$;

-- Pago a proveedores: a los 10 dias de recibido; uno de cada cinco en dos partes.
create or replace function carga_demo.pagar_proveedores(p_dia date) returns void language plpgsql as $$
declare
  v record;
  v_ts timestamptz := (p_dia + time '15:00') at time zone 'America/Asuncion';
  v_pagado numeric;
begin
  for v in
    select p.id_pedido, p.total, p.fecha_recepcion from public.pedidos p
    where p.estado = 'recibido' and p.fecha_recepcion <= v_ts - interval '10 days'
  loop
    select coalesce(sum(monto), 0) into v_pagado from public.pagos_proveedor where id_pedido = v.id_pedido and estado = 'pagado';
    if v_pagado = 0 then
      insert into public.pagos_proveedor (id_pedido, id_metodo_pago, monto, estado, fecha_pago, created_at)
      values (v.id_pedido, case when random() < 0.8 then 4 else 1 end,
              case when random() < 0.8 then v.total else round(v.total / 2 / 1000) * 1000 end,
              'pagado', v_ts, v_ts);
    elsif v_pagado < v.total and v.fecha_recepcion <= v_ts - interval '25 days' then
      insert into public.pagos_proveedor (id_pedido, id_metodo_pago, monto, estado, fecha_pago, created_at)
      values (v.id_pedido, 4, v.total - v_pagado, 'pagado', v_ts, v_ts);
    elsif v_pagado >= v.total and v.fecha_recepcion <= v_ts - interval '30 days' then
      update public.pedidos set estado = 'completado', updated_at = v_ts where id_pedido = v.id_pedido;
    end if;
  end loop;
end $$;

-- Movimientos a mano del administrador: conteo mensual, mermas y compras sueltas.
create or replace function carga_demo.movimientos_manuales(p_dia date) returns void language plpgsql as $$
declare
  v record;
  v_ts timestamptz := (p_dia + time '18:30') at time zone 'America/Asuncion';
  v_dia int := extract(day from p_dia);
begin
  perform carga_demo.actor((carga_demo.personal_al_azar('administrador')).uid);
  if v_dia in (25, 26) and not exists (select 1 from public.movimientos_inventario
       where tipo = 'ajuste' and fecha >= date_trunc('month', v_ts) and motivo like 'Conteo mensual%') then
    for v in select x.id_producto, x.stock_actual from carga_demo.producto p join public.productos x using (id_producto)
             where x.stock_actual > 20 and p.uu not in ('unidad', 'aplicación') order by random() limit 3 loop
      begin
        perform public.fn_movimiento_manual(v.id_producto, 'ajuste',
          round(v.stock_actual * (0.95 + random() * 0.04)::numeric), 'Conteo mensual de estantería');
      exception when others then null;
      end;
    end loop;
  elsif v_dia = 10 or (v_dia = 11 and extract(dow from p_dia) = 1) then
    for v in select x.id_producto, p.equiv from carga_demo.producto p join public.productos x using (id_producto)
             where x.stock_actual > p.equiv * 2 and p.n not in (39) order by random() limit 1 loop
      perform public.fn_movimiento_manual(v.id_producto, 'salida', round(v.equiv * 0.5),
        (array['Se rompió un frasco', 'Producto vencido', 'Se derramó en el lavatorio'])[1 + floor(random() * 3)::int]);
    end loop;
  elsif v_dia = 15 or (v_dia = 16 and extract(dow from p_dia) = 1) then
    for v in select x.id_producto, p.equiv from carga_demo.producto p join public.productos x using (id_producto)
             where p.n in (29, 32) order by random() limit 1 loop
      perform public.fn_movimiento_manual(v.id_producto, 'entrada', v.equiv * 2, 'Compra de urgencia en el supermercado');
    end loop;
  end if;
  perform carga_demo.reloj(v_ts);
end $$;

-- Primer dia habil del mes: se liquidan las comisiones del mes anterior.
create or replace function carga_demo.liquidar(p_dia date) returns void language plpgsql as $$
begin
  perform carga_demo.actor((carga_demo.personal_al_azar('administrador')).uid);
  update public.pagos_profesional p set estado = 'liquidado', fecha_liquidacion = p_dia,
         updated_at = (p_dia + time '19:00') at time zone 'America/Asuncion'
  from public.historial_servicio h
  where h.id_historial = p.id_historial and p.estado = 'pendiente'
    and h.fecha_realizacion < date_trunc('month', p_dia)::date;
end $$;

create or replace function carga_demo.simular_dia(p_dia date) returns void language plpgsql as $$
declare
  v_dow int := extract(dow from p_dia);
  v_crec numeric := 0.85 + 0.25 * ((p_dia - date '2026-04-18')::numeric / 182);
  v_factor numeric := case v_dow when 6 then 1.5 when 5 then 1.2 when 1 then 0.75 else 1 end;
  b carga_demo.barbero;
  t time;
  v_servicios int[];
  v_dur int;
begin
  if v_dow = 0 then return; end if;

  if v_dow = 1 then perform carga_demo.pedir(p_dia); end if;
  if v_dow = 4 then perform carga_demo.recibir(p_dia); end if;
  perform carga_demo.pagar_proveedores(p_dia);
  if (extract(day from p_dia) = 1) or (extract(day from p_dia) = 2 and v_dow = 1) then
    perform carga_demo.liquidar(p_dia);
  end if;
  perform carga_demo.movimientos_manuales(p_dia);

  -- La recepcionista del dia
  perform carga_demo.actor((carga_demo.personal_al_azar('recepcionista')).uid);

  for b in
    select * from carga_demo.barbero
    where desde <= p_dia and (hasta is null or p_dia < hasta)
      and (libre is null or libre <> v_dow) and (solo_dias is null or v_dow = any (solo_dias))
  loop
    t := time '09:00' + floor(random() * 3) * interval '30 minutes';
    while t < time '20:00' loop
      if t >= time '12:00' and t < time '14:00' then t := time '14:00'; continue; end if;
      if random() < 0.19 * b.pop * v_crec * v_factor then
        v_servicios := carga_demo.elegir_servicios(b, p_dia);
        select sum(dur) into v_dur from carga_demo.servicio where n = any (v_servicios);
        if t < time '12:00' and t + make_interval(mins => v_dur) > time '12:00' then t := time '14:00'; continue; end if;
        if t + make_interval(mins => v_dur) > time '20:00' then exit; end if;
        perform carga_demo.turno_pasado(b, p_dia, t, v_servicios);
        t := t + make_interval(mins => (ceil(v_dur / 30.0) * 30)::int);
      else
        t := t + interval '30 minutes';
      end if;
    end loop;
  end loop;
end $$;

create or replace function carga_demo.simular(p_desde date, p_hasta date) returns table (dias int, turnos bigint) language plpgsql as $$
declare
  d date;
begin
  perform setseed(((p_desde - date '2026-01-01') % 997) / 997.0 - 0.5);
  for d in select generate_series(p_desde, p_hasta, interval '1 day')::date loop
    perform carga_demo.simular_dia(d);
  end loop;
  return query select (p_hasta - p_desde + 1)::int, (select count(*) from public.citas where fecha_hora >= p_desde::timestamptz and fecha_hora < (p_hasta + 1)::timestamptz);
end $$;
