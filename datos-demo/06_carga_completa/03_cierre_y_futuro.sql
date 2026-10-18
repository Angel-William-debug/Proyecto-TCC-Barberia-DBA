-- =============================================================================
-- Carga completa de prueba (18/10/2026) · Parte 3: cierre del pasado y futuro
-- =============================================================================

-- --- Lo que cambio durante el periodo ----------------------------------------
select carga_demo.actor((select uid from carga_demo.personal where rol = 'administrador' and n = 1));

-- Pablo Duarte dejo de trabajar el 5/9; el tinte completo se dejo de ofrecer el 15/8.
update public.profesionales set estado = false where nombre = 'Pablo Duarte';
update public.servicios set estado = false where nombre = 'Tinte completo';

-- Cuatro clientes que no volvieron, desactivados.
update public.clientes set estado = false
where id_cliente in (
  select c.id_cliente from carga_demo.cliente c
  where not c.con_cuenta
  order by (select count(*) from public.citas x where x.id_cliente = c.id_cliente and x.fecha_hora > '2026-07-01'), random()
  limit 4);

-- El ultimo peine de bolsillo se vendio el sabado.
select public.fn_movimiento_manual(id_producto, 'ajuste', 0, 'Se vendió el último en el mostrador')
from public.productos where nombre = 'Peine de bolsillo';
select carga_demo.reloj('2026-10-17 18:10-03');

-- Dos ordenes en camino: pedidas el viernes y el sabado, todavia sin llegar.
with nuevas as (
  insert into public.pedidos (id_proveedor, id_usuario, fecha_pedido, estado, created_at)
  values (1, (select id_usuario from carga_demo.personal where rol = 'administrador' and n = 1), '2026-10-16 09:40-03', 'pedido', '2026-10-16 09:40-03'),
         (6, (select id_usuario from carga_demo.personal where rol = 'administrador' and n = 2), '2026-10-17 10:15-03', 'pedido', '2026-10-17 10:15-03')
  returning id_pedido, id_proveedor, created_at
)
insert into public.detalle_pedido (id_pedido, id_producto, cantidad, precio_unit, subtotal, created_at)
select n.id_pedido, p.id_producto, 2 + (p.n % 3), p.precio, 0, n.created_at
from nuevas n join carga_demo.producto p on p.proveedor = n.id_proveedor
where p.n in (1, 3, 5, 25, 27, 29);

-- --- Turnos futuros -------------------------------------------------------------
create or replace function carga_demo.turno_futuro(b carga_demo.barbero, p_dia date, p_hora time, p_servicios int[], p_cliente carga_demo.cliente default null)
returns boolean language plpgsql as $$
declare
  v_cliente carga_demo.cliente := p_cliente;
  v_ts timestamptz := (p_dia + p_hora) at time zone 'America/Asuncion';
  v_portal boolean;
  v_cita int;
  v_creado timestamptz := now() - (0.2 + random() * 9) * interval '1 day';
  v_n int;
  s carga_demo.servicio;
begin
  if v_cliente.id_cliente is null then v_cliente := carga_demo.elegir_cliente(b, p_dia, true); end if;
  if v_cliente.id_cliente is null then return false; end if;
  v_portal := v_cliente.con_cuenta and random() < 0.5;
  begin
    insert into public.citas (id_cliente, id_usuario, fecha_hora, estado, created_at, updated_at)
    values (v_cliente.id_cliente,
            case when v_portal then null else (carga_demo.personal_al_azar('recepcionista')).id_usuario end,
            v_ts,
            case when v_portal then 'pendiente'
                 when random() < case when p_dia - current_date <= 3 then 0.75 else 0.4 end then 'confirmado'
                 else 'pendiente' end,
            v_creado, v_creado)
    returning id_cita into v_cita;
    foreach v_n in array p_servicios loop
      select * into s from carga_demo.servicio where n = v_n;
      insert into public.detalle_cita (id_cita, id_servicio, id_profesional, duracion_min, precio_unit, subtotal, created_at)
      values (v_cita, s.id_servicio, b.id_profesional, s.dur, s.precio, s.precio, v_creado);
    end loop;
  exception when others then
    return false;  -- choque de horario: ese hueco no se usa
  end;
  return true;
end $$;

create or replace function carga_demo.futuro() returns bigint language plpgsql as $$
declare
  d date;
  v_dow int;
  v_lejania numeric;
  v_factor numeric;
  b carga_demo.barbero;
  t time;
  v_servicios int[];
  v_dur int;
begin
  perform setseed(0.31);
  for d in select generate_series(current_date + 1, date '2026-11-29', interval '1 day')::date loop
    v_dow := extract(dow from d);
    continue when v_dow = 0;
    v_lejania := greatest(0.12, 1 - (d - current_date) / 42.0);
    v_factor := case v_dow when 6 then 1.5 when 5 then 1.2 when 1 then 0.75 else 1 end;
    for b in
      select * from carga_demo.barbero
      where desde <= d and hasta is null
        and (libre is null or libre <> v_dow) and (solo_dias is null or v_dow = any (solo_dias))
    loop
      t := time '09:00' + floor(random() * 3) * interval '30 minutes';
      while t < time '20:00' loop
        if t >= time '12:00' and t < time '14:00' then t := time '14:00'; continue; end if;
        if random() < 0.19 * b.pop * 1.1 * v_factor * v_lejania then
          v_servicios := carga_demo.elegir_servicios(b, d);
          select sum(dur) into v_dur from carga_demo.servicio where n = any (v_servicios);
          if t < time '12:00' and t + make_interval(mins => v_dur) > time '12:00' then t := time '14:00'; continue; end if;
          if t + make_interval(mins => v_dur) > time '20:00' then exit; end if;
          perform carga_demo.turno_futuro(b, d, t, v_servicios);
          t := t + make_interval(mins => (ceil(v_dur / 30.0) * 30)::int);
        else
          t := t + interval '30 minutes';
        end if;
      end loop;
    end loop;
  end loop;
  return (select count(*) from public.citas where fecha_hora > now());
end $$;

select carga_demo.actor((select uid from carga_demo.personal where rol = 'recepcionista' and n = 1));
select carga_demo.futuro() turnos_futuros;

-- Las tres cuentas de cliente para probar (prueba, Angel y William): tres turnos
-- futuros cada una, uno de ellos pendiente para confirmar desde la app.
do $$
declare
  v_cliente carga_demo.cliente;
  b carga_demo.barbero;
  v_intento int;
  v_dia date;
begin
  for v_cliente in
    select c.* from carga_demo.cliente c join public.clientes pc using (id_cliente)
    where pc.email in ('cliente@correo.com.py', 'CORREO_ANGEL@gmail.com', 'CORREO_WILLIAM+cliente@gmail.com')
  loop
    select * into b from carga_demo.barbero where n = v_cliente.barbero;
    v_intento := 0;
    while (select count(*) from public.citas where id_cliente = v_cliente.id_cliente and fecha_hora > now()
           and estado in ('pendiente', 'confirmado')) < 3 and v_intento < 60 loop
      v_intento := v_intento + 1;
      v_dia := current_date + 1 + floor(random() * 28)::int;
      continue when extract(dow from v_dia) = 0 or extract(dow from v_dia) = b.libre;
      perform carga_demo.turno_futuro(b, v_dia,
        (array['09:00','10:00','11:00','14:00','15:00','16:00','17:00','18:00']::time[])[1 + floor(random() * 8)::int],
        carga_demo.elegir_servicios(b, v_dia), v_cliente);
    end loop;
    -- Que haya uno pendiente (el estado nuevo no dispara aviso).
    if not exists (select 1 from public.citas where id_cliente = v_cliente.id_cliente and fecha_hora > now() and estado = 'pendiente') then
      update public.citas set estado = 'pendiente'
      where id_cita = (select id_cita from public.citas where id_cliente = v_cliente.id_cliente and fecha_hora > now()
                       and estado = 'confirmado' order by fecha_hora desc limit 1);
    end if;
  end loop;
end $$;

-- Para la bandeja de Notificaciones: tres recordatorios de mañana que no salieron.
insert into public.notificaciones (id_cita, id_usuario, tipo, mensaje, email_destino, estado_envio, proveedor, intentos, created_at)
select c.id_cita, cl.id_usuario, 'recordatorio',
       case when cl.email is null then 'Sin correo registrado: no se pudo enviar el recordatorio.'
            else 'Brevo respondió 502: error temporal del servidor' end,
       cl.email, case when cl.email is null then 'sin_email' else 'fallido' end, 'brevo',
       case when cl.email is null then 0 else 3 end, now() - interval '2 hours'
from public.citas c join public.clientes cl using (id_cliente)
where c.fecha_hora::date = current_date + 1 and c.estado in ('pendiente', 'confirmado')
order by cl.email is null desc, random() limit 3;

-- --- Recomendaciones del motor para 100 clientes ---------------------------------
with candidatos as (
  select c.id_cliente, c.barbero from carga_demo.cliente c join public.clientes pc using (id_cliente)
  where pc.estado and (select count(*) from public.historial_servicio h where h.id_cliente = c.id_cliente) >= 4
  order by random() limit 100
), ranking as (
  select k.id_cliente, h.id_servicio, count(*) n
  from candidatos k
  join carga_demo.cliente o on o.barbero = k.barbero and o.id_cliente <> k.id_cliente
  join public.historial_servicio h on h.id_cliente = o.id_cliente
  join public.servicios sv on sv.id_servicio = h.id_servicio and sv.estado
  where not exists (select 1 from public.historial_servicio m where m.id_cliente = k.id_cliente and m.id_servicio = h.id_servicio)
  group by 1, 2
), mejores as (
  select *, row_number() over (partition by id_cliente order by n desc, random()) r from ranking
)
insert into public.recomendaciones_ml (id_cliente, id_servicio, score_relevancia, algoritmo, fecha_generacion, created_at)
select m.id_cliente, m.id_servicio, round((0.95 - m.r * 0.12 - random() * 0.07)::numeric, 3),
       case when m.id_cliente % 10 = 0 then 'mas_pedidos_v1' else 'kmeans_colaborativo_v2' end,
       now() - (m.id_cliente % 20) * interval '1 day', now() - (m.id_cliente % 20) * interval '1 day'
from mejores m where m.r <= 3;

-- --- Limpieza --------------------------------------------------------------------
drop index if exists public.carga_demo_citas_cliente, public.carga_demo_hist_creado, public.carga_demo_pprof_creado,
  public.carga_demo_aud_creado, public.carga_demo_mov_creado, public.carga_demo_alerta_creado;
select set_config('request.jwt.claims', '', true);
