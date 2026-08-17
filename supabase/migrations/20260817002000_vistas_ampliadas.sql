-- ============================================================================
-- VISTAS AMPLIADAS
--
-- Suma 24 vistas a las 7 existentes: 31 en total. Ninguna requiere cambiar el
-- modelo; todas se derivan de tablas que ya estan.
--
-- Tres reglas comunes a todas:
--   1. security_invoker = true. La vista se ejecuta con los permisos de quien
--      consulta, de modo que las politicas RLS de las tablas base siguen
--      aplicando. Sin esto, una vista seria un agujero para saltear RLS.
--   2. Filtran `not deleted` en cada tabla que lleve borrado logico.
--   3. Devuelven nombres, no claves foraneas: una vista que obliga a resolver
--      el nombre del producto aparte no ahorra trabajo.
--
-- Estan agrupadas por modulo del sistema.
-- ============================================================================


-- ===========================================================================
-- MODULO 1 - CONFIGURACION
-- ===========================================================================

-- Horario de atencion con el nombre del dia ya resuelto.
create or replace view public.v_horarios_semana
with (security_invoker = true) as
select h.id_horario,
       h.dia_semana,
       case h.dia_semana
           when 0 then 'domingo'  when 1 then 'lunes'   when 2 then 'martes'
           when 3 then 'miercoles' when 4 then 'jueves' when 5 then 'viernes'
           else 'sabado'
       end as nombre_dia,
       h.hora_apertura,
       h.hora_cierre,
       h.activo,
       -- Minutos que la barberia abre ese dia: base para medir ocupacion.
       (extract(epoch from (h.hora_cierre - h.hora_apertura)) / 60)::int as minutos_abierta
from public.horarios_atencion h
where not h.deleted
order by h.dia_semana;

comment on view public.v_horarios_semana is
    'CU-020. Horario por dia con el nombre resuelto y los minutos de apertura.';


-- Quien tiene acceso al sistema y con que rol.
create or replace view public.v_usuarios_por_rol
with (security_invoker = true) as
select u.id_usuario,
       u.nombre,
       u.email,
       r.nombre as rol,
       u.estado,
       u.created_at,
       p.id_profesional,
       (p.id_profesional is not null) as es_barbero
from public.usuarios u
join public.roles r on r.id_rol = u.id_rol
left join public.profesionales p on p.id_usuario = u.id_usuario and not p.deleted
where not u.deleted;

comment on view public.v_usuarios_por_rol is
    'CU-001. Usuarios con su rol y, si corresponde, su ficha de barbero.';


-- ===========================================================================
-- MODULO 2 - CLIENTES
-- ===========================================================================

-- Un cliente por fila con su historial resumido. Es la base de las tres
-- vistas de fidelizacion que siguen.
create or replace view public.v_clientes_resumen
with (security_invoker = true) as
select c.id_cliente,
       c.nombre,
       c.telefono,
       c.email,
       c.fecha_nacimiento,
       c.estado,
       c.created_at,
       count(h.id_historial)                       as cantidad_visitas,
       coalesce(sum(h.costo_cobrado), 0)           as total_gastado,
       round(coalesce(avg(h.costo_cobrado), 0), 2) as ticket_promedio,
       max(h.fecha_realizacion)                    as ultima_visita,
       min(h.fecha_realizacion)                    as primera_visita,
       -- Dias desde la ultima visita. Null si nunca vino.
       case when max(h.fecha_realizacion) is not null
            then (current_date - max(h.fecha_realizacion))
       end as dias_sin_venir
from public.clientes c
left join public.historial_servicio h on h.id_cliente = c.id_cliente
where not c.deleted
group by c.id_cliente, c.nombre, c.telefono, c.email,
         c.fecha_nacimiento, c.estado, c.created_at;

comment on view public.v_clientes_resumen is
    'CU-002. Un cliente por fila con visitas, gasto acumulado y ultima visita.';


-- Clientes que dejaron de venir. Alimenta el indicador de retencion del TCC.
create or replace view public.v_clientes_inactivos
with (security_invoker = true) as
select id_cliente,
       nombre,
       telefono,
       email,
       cantidad_visitas,
       total_gastado,
       ultima_visita,
       dias_sin_venir
from public.v_clientes_resumen
where cantidad_visitas > 0
  and dias_sin_venir > 60
  and estado;

comment on view public.v_clientes_inactivos is
    'Clientes con al menos una visita que no vuelven hace mas de 60 dias. '
    'Base del indicador de tasa de retencion.';


-- Los que mas vuelven. El otro lado del mismo indicador.
create or replace view public.v_clientes_frecuentes
with (security_invoker = true) as
select id_cliente,
       nombre,
       telefono,
       cantidad_visitas,
       total_gastado,
       ticket_promedio,
       ultima_visita,
       -- Visitas por mes desde la primera vez: mide frecuencia, no volumen.
       case when primera_visita is not null and primera_visita < current_date
            then round(
                     cantidad_visitas::numeric
                     / greatest(1, (current_date - primera_visita)::numeric / 30),
                     2)
       end as visitas_por_mes
from public.v_clientes_resumen
where cantidad_visitas >= 3
  and estado;

comment on view public.v_clientes_frecuentes is
    'Clientes con 3 o mas visitas, con su frecuencia mensual. '
    'Base del indicador de frecuencia de visitas.';


-- Cumpleanos del mes: excusa concreta para una promocion.
create or replace view public.v_cumpleanos_del_mes
with (security_invoker = true) as
select c.id_cliente,
       c.nombre,
       c.telefono,
       c.email,
       c.fecha_nacimiento,
       extract(day from c.fecha_nacimiento)::int as dia,
       date_part('year', age(c.fecha_nacimiento))::int as edad
from public.clientes c
where not c.deleted
  and c.estado
  and c.fecha_nacimiento is not null
  and extract(month from c.fecha_nacimiento) = extract(month from current_date)
order by extract(day from c.fecha_nacimiento);

comment on view public.v_cumpleanos_del_mes is
    'CU-002. Clientes que cumplen anos este mes.';


-- ===========================================================================
-- MODULO 3 - ADMINISTRACION DE DATOS
-- ===========================================================================

-- Catalogo de servicios con su categoria resuelta.
create or replace view public.v_catalogo_servicios
with (security_invoker = true) as
select s.id_servicio,
       s.nombre,
       s.descripcion,
       cs.nombre as categoria,
       s.duracion_min,
       s.precio_base,
       s.estado,
       -- Cuantos productos consume segun su receta
       (select count(*) from public.servicio_producto sp
         where sp.id_servicio = s.id_servicio and not sp.deleted) as productos_receta
from public.servicios s
join public.categorias_servicio cs on cs.id_categoria = s.id_categoria
where not s.deleted;

comment on view public.v_catalogo_servicios is
    'CU-003. Servicios con categoria, precio, duracion y tamano de su receta.';


-- Ranking de servicios por demanda.
create or replace view public.v_servicios_mas_solicitados
with (security_invoker = true) as
select s.id_servicio,
       s.nombre,
       cs.nombre as categoria,
       s.precio_base,
       count(h.id_historial)             as veces_realizado,
       coalesce(sum(h.costo_cobrado), 0) as facturado,
       max(h.fecha_realizacion)          as ultima_vez
from public.servicios s
join public.categorias_servicio cs on cs.id_categoria = s.id_categoria
left join public.historial_servicio h on h.id_servicio = s.id_servicio
where not s.deleted
group by s.id_servicio, s.nombre, cs.nombre, s.precio_base;

comment on view public.v_servicios_mas_solicitados is
    'Ranking de servicios por cantidad de veces realizados y facturacion.';


-- Un barbero por fila con su produccion.
create or replace view public.v_profesionales_resumen
with (security_invoker = true) as
select p.id_profesional,
       p.nombre,
       p.especialidad,
       p.tipo,
       p.porcentaje_com,
       p.estado,
       count(h.id_historial)                          as servicios_realizados,
       coalesce(sum(h.costo_cobrado), 0)              as facturado,
       coalesce(sum(pp.monto) filter (where pp.estado = 'pendiente'), 0) as comision_pendiente,
       coalesce(sum(pp.monto) filter (where pp.estado = 'liquidado'), 0) as comision_liquidada,
       count(distinct h.id_cliente)                   as clientes_distintos,
       max(h.fecha_realizacion)                       as ultimo_servicio
from public.profesionales p
left join public.historial_servicio h on h.id_profesional = p.id_profesional
left join public.pagos_profesional pp on pp.id_historial = h.id_historial
where not p.deleted
group by p.id_profesional, p.nombre, p.especialidad, p.tipo,
         p.porcentaje_com, p.estado;

comment on view public.v_profesionales_resumen is
    'CU-004. Por barbero: servicios, facturacion, comisiones y clientes atendidos.';


-- ===========================================================================
-- MODULO 4 - AGENDA
-- ===========================================================================

-- La jornada completa: un turno por fila, con sus servicios agregados y la
-- hora de finalizacion ya calculada.
create or replace view public.v_agenda_dia
with (security_invoker = true) as
select c.id_cita,
       c.fecha_hora,
       c.fecha_hora::date as dia,
       c.estado,
       c.total,
       c.observaciones,
       cl.id_cliente,
       cl.nombre   as nombre_cliente,
       cl.telefono as telefono_cliente,
       (select string_agg(distinct pr.nombre, ', ')
          from public.detalle_cita d
          join public.profesionales pr on pr.id_profesional = d.id_profesional
         where d.id_cita = c.id_cita) as barberos,
       (select string_agg(sv.nombre, ', ' order by sv.nombre)
          from public.detalle_cita d
          join public.servicios sv on sv.id_servicio = d.id_servicio
         where d.id_cita = c.id_cita) as servicios,
       (select coalesce(sum(d.duracion_min), 0)
          from public.detalle_cita d where d.id_cita = c.id_cita) as duracion_total_min,
       -- El cast a int es obligatorio: sum() devuelve bigint y make_interval
       -- no acepta ese tipo.
       c.fecha_hora
         + make_interval(mins => (select coalesce(sum(d.duracion_min), 0)::int
                                    from public.detalle_cita d
                                   where d.id_cita = c.id_cita)) as fecha_hora_fin
from public.citas c
join public.clientes cl on cl.id_cliente = c.id_cliente
where not c.deleted;

comment on view public.v_agenda_dia is
    'CU-006. Un turno por fila con cliente, servicios, barberos y hora de fin.';


-- Cuanto tiempo tiene ocupado cada barbero, por dia.
create or replace view public.v_ocupacion_por_barbero
with (security_invoker = true) as
select p.id_profesional,
       p.nombre as nombre_profesional,
       c.fecha_hora::date as dia,
       count(distinct c.id_cita) as turnos,
       sum(d.duracion_min)       as minutos_ocupados,
       sum(d.subtotal)           as facturacion_agendada
from public.detalle_cita d
join public.citas c on c.id_cita = d.id_cita
join public.profesionales p on p.id_profesional = d.id_profesional
where not c.deleted
  and not p.deleted
  and c.estado in ('pendiente', 'confirmado', 'en_proceso', 'completado')
group by p.id_profesional, p.nombre, c.fecha_hora::date;

comment on view public.v_ocupacion_por_barbero is
    'Minutos ocupados y turnos por barbero y dia. Se compara contra '
    'v_horarios_semana.minutos_abierta para obtener el porcentaje de ocupacion.';


-- Turnos de las proximas 24 horas. Alimenta el recordatorio de la RN-050.
create or replace view public.v_proximos_turnos
with (security_invoker = true) as
select c.id_cita,
       c.fecha_hora,
       c.estado,
       cl.nombre        as nombre_cliente,
       cl.telefono,
       cl.email,
       (select string_agg(sv.nombre, ', ' order by sv.nombre)
          from public.detalle_cita d
          join public.servicios sv on sv.id_servicio = d.id_servicio
         where d.id_cita = c.id_cita) as servicios,
       -- Si ya se le mando el recordatorio, para no repetirlo
       exists (
           select 1 from public.notificaciones n
            where n.id_cita = c.id_cita
              and n.tipo = 'recordatorio'
              and n.estado_envio = 'enviado'
       ) as recordatorio_enviado
from public.citas c
join public.clientes cl on cl.id_cliente = c.id_cliente
where not c.deleted
  and not cl.deleted
  and c.estado in ('pendiente', 'confirmado')
  and c.fecha_hora between now() and now() + interval '24 hours';

comment on view public.v_proximos_turnos is
    'RN-050. Turnos dentro de las proximas 24 horas, con el dato de si ya se '
    'envio el recordatorio.';


-- Cancelaciones y ausencias, para medir la tasa que pide el TCC.
create or replace view public.v_citas_canceladas
with (security_invoker = true) as
select c.id_cita,
       c.fecha_hora,
       c.fecha_hora::date as dia,
       c.estado,
       cl.nombre as nombre_cliente,
       cl.telefono,
       c.observaciones,
       c.total as monto_perdido,
       c.updated_at as fecha_cancelacion
from public.citas c
join public.clientes cl on cl.id_cliente = c.id_cliente
where not c.deleted
  and c.estado in ('cancelado', 'no_asistio');

comment on view public.v_citas_canceladas is
    'Cancelaciones y ausencias con el monto que se dejo de facturar.';


-- ===========================================================================
-- MODULO 5 - COBROS Y PAGOS
-- ===========================================================================

-- Cada cobro con su cliente, metodo y turno resueltos.
create or replace view public.v_cobros_detalle
with (security_invoker = true) as
select co.id_cobro,
       co.id_cita,
       co.monto,
       co.estado,
       co.fecha_pago,
       co.comprobante_url,
       mp.nombre as metodo_pago,
       cl.id_cliente,
       cl.nombre as nombre_cliente,
       c.fecha_hora as fecha_turno,
       c.total      as total_turno,
       -- Cuanto falta cobrar de ese turno
       c.total - co.monto as saldo
from public.cobros_cliente co
join public.citas c on c.id_cita = co.id_cita
join public.clientes cl on cl.id_cliente = c.id_cliente
join public.metodos_pago mp on mp.id_metodo = co.id_metodo_pago
where not co.deleted
  and not c.deleted;

comment on view public.v_cobros_detalle is
    'CU-008. Cobros con cliente, metodo, turno y saldo pendiente.';


-- Servicios completados que todavia no se cobraron. RN-024.
create or replace view public.v_cobros_pendientes
with (security_invoker = true) as
select c.id_cita,
       c.fecha_hora,
       cl.nombre as nombre_cliente,
       cl.telefono,
       c.total,
       coalesce(sum(co.monto) filter (where co.estado in ('pagado', 'parcial')), 0) as cobrado,
       c.total - coalesce(sum(co.monto) filter (where co.estado in ('pagado', 'parcial')), 0) as saldo
from public.citas c
join public.clientes cl on cl.id_cliente = c.id_cliente
left join public.cobros_cliente co on co.id_cita = c.id_cita and not co.deleted
where not c.deleted
  and c.estado = 'completado'
group by c.id_cita, c.fecha_hora, cl.nombre, cl.telefono, c.total
having c.total > coalesce(sum(co.monto) filter (where co.estado in ('pagado', 'parcial')), 0);

comment on view public.v_cobros_pendientes is
    'Turnos completados con saldo sin cobrar. RN-024 y RN-025.';


-- Cuanto entra por cada medio de pago.
create or replace view public.v_ingresos_por_metodo
with (security_invoker = true) as
select mp.id_metodo,
       mp.nombre as metodo_pago,
       extract(year from co.fecha_pago)::int  as anio,
       extract(month from co.fecha_pago)::int as mes,
       count(*)          as cantidad_cobros,
       sum(co.monto)     as total,
       round(avg(co.monto), 2) as promedio
from public.cobros_cliente co
join public.metodos_pago mp on mp.id_metodo = co.id_metodo_pago
where not co.deleted
  and co.estado in ('pagado', 'parcial')
  and co.fecha_pago is not null
group by mp.id_metodo, mp.nombre,
         extract(year from co.fecha_pago), extract(month from co.fecha_pago);

comment on view public.v_ingresos_por_metodo is
    'Ingresos por medio de pago y mes. Sirve para arqueo de caja.';


-- Ticket promedio de cada barbero.
create or replace view public.v_ticket_promedio_barbero
with (security_invoker = true) as
select p.id_profesional,
       p.nombre as nombre_profesional,
       count(h.id_historial)             as servicios,
       sum(h.costo_cobrado)              as facturado,
       round(avg(h.costo_cobrado), 2)    as ticket_promedio,
       min(h.costo_cobrado)              as minimo,
       max(h.costo_cobrado)              as maximo
from public.profesionales p
join public.historial_servicio h on h.id_profesional = p.id_profesional
where not p.deleted
group by p.id_profesional, p.nombre;

comment on view public.v_ticket_promedio_barbero is
    'Ticket promedio, minimo y maximo por barbero.';


-- Historico de comisiones ya pagadas.
create or replace view public.v_comisiones_liquidadas
with (security_invoker = true) as
select pp.id_pago_prof,
       p.id_profesional,
       p.nombre as nombre_profesional,
       s.nombre as nombre_servicio,
       h.fecha_realizacion,
       h.costo_cobrado,
       p.porcentaje_com,
       pp.monto as comision,
       pp.fecha_liquid as fecha_liquidacion
from public.pagos_profesional pp
join public.profesionales p on p.id_profesional = pp.id_profesional
join public.historial_servicio h on h.id_historial = pp.id_historial
join public.servicios s on s.id_servicio = h.id_servicio
where pp.estado = 'liquidado';

comment on view public.v_comisiones_liquidadas is
    'CU-009. Comisiones ya pagadas. Un pago liquidado no se puede revertir (RN-027).';


-- ===========================================================================
-- MODULO 6 - INVENTARIO Y COMPRAS
-- ===========================================================================

-- Cuanto dinero hay inmovilizado en stock.
create or replace view public.v_inventario_valorizado
with (security_invoker = true) as
select p.id_producto,
       p.nombre,
       cp.nombre as categoria,
       p.stock_actual,
       p.stock_minimo,
       p.stock_maximo,
       p.precio_unitario,
       round(greatest(p.stock_actual, 0) * p.precio_unitario, 2) as valor_stock,
       case
           when p.stock_actual <= 0                    then 'sin_stock'
           when p.stock_actual <= p.stock_minimo       then 'critico'
           when p.stock_actual <= p.stock_minimo * 1.5 then 'bajo'
           when p.stock_maximo is not null
                and p.stock_actual > p.stock_maximo    then 'sobrestock'
           else 'disponible'
       end as nivel
from public.productos p
join public.categorias_producto cp on cp.id_categoria_p = p.id_categoria_p
where not p.deleted
  and p.estado;

comment on view public.v_inventario_valorizado is
    'Stock con su valorizacion y el nivel calculado. El nivel replica la '
    'logica de la seccion 10.5 del sistema de diseno.';


-- Que se gasta mas rapido, para anticipar la compra.
create or replace view public.v_productos_mas_consumidos
with (security_invoker = true) as
select p.id_producto,
       p.nombre,
       cp.nombre as categoria,
       p.stock_actual,
       p.unidad_uso,
       count(pu.id_uso)                     as veces_usado,
       coalesce(sum(pu.cantidad_usada), 0)  as cantidad_total,
       count(*) filter (where pu.excepcion_stock) as usos_con_excepcion,
       max(pu.fecha_uso)                    as ultimo_uso
from public.productos p
join public.categorias_producto cp on cp.id_categoria_p = p.id_categoria_p
left join public.productos_utilizados pu on pu.id_producto = p.id_producto
where not p.deleted
group by p.id_producto, p.nombre, cp.nombre, p.stock_actual, p.unidad_uso;

comment on view public.v_productos_mas_consumidos is
    'Consumo por producto. `usos_con_excepcion` cuenta las veces que se '
    'completo un servicio con stock insuficiente (CU-007 A1, RN-031).';


-- Movimientos con producto y usuario resueltos.
create or replace view public.v_movimientos_detalle
with (security_invoker = true) as
select m.id_movimiento,
       m.fecha,
       m.tipo,
       m.cantidad,
       m.motivo,
       p.id_producto,
       p.nombre as nombre_producto,
       u.nombre as nombre_usuario
from public.movimientos_inventario m
join public.productos p on p.id_producto = m.id_producto
left join public.usuarios u on u.id_usuario = m.id_usuario;

comment on view public.v_movimientos_detalle is
    'Entradas, salidas y ajustes con producto y usuario resueltos.';


-- Cuanto se le compro a cada proveedor.
create or replace view public.v_compras_por_proveedor
with (security_invoker = true) as
select pr.id_proveedor,
       pr.nombre,
       pr.telefono,
       pr.email,
       count(pe.id_pedido)                                          as pedidos,
       count(*) filter (where pe.estado in ('recibido', 'completado')) as recibidos,
       count(*) filter (where pe.estado = 'cancelado')              as cancelados,
       coalesce(sum(pe.total), 0)                                   as total_comprado,
       max(pe.fecha_pedido)                                         as ultimo_pedido
from public.proveedores pr
left join public.pedidos pe on pe.id_proveedor = pr.id_proveedor and not pe.deleted
where not pr.deleted
group by pr.id_proveedor, pr.nombre, pr.telefono, pr.email;

comment on view public.v_compras_por_proveedor is
    'CU-011. Volumen y frecuencia de compra por proveedor.';


-- ===========================================================================
-- MODULO 7 - REPORTES
-- ===========================================================================

-- Resumen mes a mes: la vista que sostiene el panel de indicadores.
create or replace view public.v_resumen_mensual
with (security_invoker = true) as
with meses as (
    select distinct date_trunc('month', c.fecha_hora)::date as mes
    from public.citas c
    where not c.deleted
)
select m.mes,
       extract(year from m.mes)::int  as anio,
       extract(month from m.mes)::int as numero_mes,
       (select count(*) from public.citas c
         where not c.deleted and date_trunc('month', c.fecha_hora)::date = m.mes) as turnos,
       (select count(*) from public.citas c
         where not c.deleted and c.estado = 'completado'
           and date_trunc('month', c.fecha_hora)::date = m.mes) as completados,
       (select count(*) from public.citas c
         where not c.deleted and c.estado in ('cancelado', 'no_asistio')
           and date_trunc('month', c.fecha_hora)::date = m.mes) as cancelados,
       (select count(distinct h.id_cliente) from public.historial_servicio h
         where date_trunc('month', h.fecha_realizacion)::date = m.mes) as clientes_atendidos,
       (select coalesce(sum(co.monto), 0) from public.cobros_cliente co
         where not co.deleted and co.estado in ('pagado', 'parcial')
           and date_trunc('month', co.fecha_pago)::date = m.mes) as ingresos,
       (select coalesce(sum(pp.monto), 0)
          from public.pagos_profesional pp
          join public.historial_servicio h on h.id_historial = pp.id_historial
         where date_trunc('month', h.fecha_realizacion)::date = m.mes) as comisiones
from meses m;

comment on view public.v_resumen_mensual is
    'Modulo 7. Turnos, cancelaciones, clientes, ingresos y comisiones por mes. '
    'Base de los indicadores del TCC.';


-- Auditoria con el nombre del usuario resuelto.
create or replace view public.v_auditoria_detalle
with (security_invoker = true) as
select a.id_auditoria,
       a.fecha_accion,
       a.tabla_afectada,
       a.accion,
       a.registro_id,
       a.detalle,
       u.id_usuario,
       coalesce(u.nombre, 'Sistema') as nombre_usuario,
       r.nombre as rol_usuario
from public.auditoria a
left join public.usuarios u on u.id_usuario = a.id_usuario
left join public.roles r on r.id_rol = u.id_rol;

comment on view public.v_auditoria_detalle is
    'CU-022. Registro de auditoria con el usuario y su rol resueltos.';
