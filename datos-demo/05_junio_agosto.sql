-- =============================================================================
-- Junio a agosto de 2026: emparejar con septiembre (cargado el 15/10/2026)
-- =============================================================================
--
-- NO es una migracion. Se ejecuto una vez, despues de 04_septiembre_octubre.sql.
--
-- Con solo 02_operacion.sql, junio a agosto tenian ~30 turnos por mes y
-- septiembre, despues de 04_, ~140: el grafico de ingresos mostraba un salto de
-- 4 veces que en la defensa parecia inventado. Esto suma 2 a 4 turnos por dia
-- habil a esos tres meses, por el mismo camino que 04_ (no_asistio y luego
-- completado), con sus cobros, insumos y comisiones liquidadas. Sin turnos
-- futuros y sin tocar las cuentas reales.
--
-- Resultado: 213 completados, 13 cancelados, 11 ausentes, 213 cobros, 88
-- insumos. Ingresos: jun 6,18 M; jul 6,64 M; ago 5,52 M; sep 7,88 M.

create temp table resumen_demo (paso text, cantidad int) on commit drop;

do $$
declare
  barberos int[] := array[12,13,14,15,28,29];
  -- Sin Angel Rolon (109), William Gimenez (112) ni el cliente de prueba de la app (16):
  -- son cuentas reales y no tienen por que recibir recordatorios de turnos inventados.
  clientes_pasado int[] := array[94,95,96,97,98,99,100,101,102,103,104,105,106,107,108];
  clientes_futuro int[] := array[96,100,101,103,104,105,107,108];
  servicios int[] := array[9,10,11,12,13,14];
  horas time[] := array['09:00','10:00','11:00','14:00','15:00','16:00','17:00','18:00','19:00']::time[];
  motivos text[] := array['El cliente avisó que no puede venir', 'Reprogramó por viaje', 'Se enfermó'];
  d date; h time; b int; s int; c int; v_cita int; v_ts timestamptz; n int; i int;
  v_dur int; v_precio numeric; r float;
  hoy date := (now() at time zone 'America/Asuncion')::date;
  completadas int := 0; ausentes int := 0; canceladas int := 0; futuras int := 0; saltadas int := 0;
begin
  perform setseed(0.17);

  -- 1. Pasado: del 1/9 a ayer.
  for d in select generate_series('2026-06-01'::date, '2026-08-31'::date, '1 day')::date loop
    continue when extract(dow from d) = 0;
    n := 2 + floor(random() * 3)::int;
    for i in 1..n loop
      b := barberos[1 + floor(random() * 6)::int];
      h := horas[1 + floor(random() * 9)::int];
      c := clientes_pasado[1 + floor(random() * 15)::int];
      s := servicios[1 + floor(random() * 6)::int];
      v_ts := (d + h) at time zone 'America/Asuncion';
      r := random();
      begin
        insert into public.citas (id_cliente, fecha_hora, estado)
        values (c, v_ts, 'no_asistio') returning id_cita into v_cita;
        select duracion_min, precio_base into v_dur, v_precio from public.servicios where id_servicio = s;
        insert into public.detalle_cita (id_cita, id_servicio, id_profesional, duracion_min, precio_unit, subtotal)
        values (v_cita, s, b, v_dur, v_precio, v_precio);
        if r < 0.90 then
          update public.citas set estado = 'completado' where id_cita = v_cita;
          completadas := completadas + 1;
        elsif r < 0.95 then
          update public.citas set estado = 'cancelado', motivo_cancelacion = motivos[1 + floor(random() * 3)::int]
          where id_cita = v_cita;
          canceladas := canceladas + 1;
        else
          ausentes := ausentes + 1;
        end if;
      exception when others then
        saltadas := saltadas + 1;
      end;
    end loop;
  end loop;

  insert into resumen_demo values ('pasado completadas', completadas), ('pasado canceladas', canceladas),
    ('pasado no asistio', ausentes), ('futuras', futuras), ('saltadas por choque', saltadas);
end $$;


-- 4. Cobros de lo completado, salvo los cuatro ultimos (quedan para cobrar en la demo).
with cobrados as (
  insert into public.cobros_cliente (id_cita, id_metodo_pago, monto, estado, fecha_pago)
  select c.id_cita, 1 + floor(random() * 5)::int, c.total, 'pagado', c.fecha_hora + interval '50 minutes'
  from public.citas c
  where c.estado = 'completado' and not c.deleted and c.total > 0
    and not exists (select 1 from public.cobros_cliente k where k.id_cita = c.id_cita and not k.deleted)
    and c.fecha_hora < '2026-09-01'
  returning 1
) insert into resumen_demo select 'cobros', count(*) from cobrados;

-- 5. Insumos de los servicios con receta (cera y aceite, que tienen stock).
with usos as (
  insert into public.productos_utilizados (id_historial, id_producto, cantidad_usada, excepcion_stock)
  select h.id_historial, case h.id_servicio when 11 then 6 else 7 end, 1, false
  from public.historial_servicio h
  where h.fecha_realizacion between '2026-06-01' and '2026-08-31' and h.id_servicio in (11, 13)
    and not exists (select 1 from public.productos_utilizados u where u.id_historial = h.id_historial)
  returning 1
) insert into resumen_demo select 'insumos', count(*) from usos;

-- 6. Liquidar las comisiones de septiembre y anteriores.
with liquidadas as (
  update public.pagos_profesional p set estado = 'liquidado', fecha_liquidacion = '2026-10-01'
  from public.historial_servicio h
  where h.id_historial = p.id_historial and p.estado = 'pendiente' and h.fecha_realizacion < '2026-10-01'
  returning 1
) insert into resumen_demo select 'comisiones liquidadas', count(*) from liquidadas;

select * from resumen_demo;
