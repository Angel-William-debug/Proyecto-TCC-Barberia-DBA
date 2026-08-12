-- ============================================================================
-- VISTAS DE CONSULTA
--
-- Todas con security_invoker: se ejecutan con los permisos de quien consulta,
-- de modo que las politicas RLS de las tablas base siguen aplicando.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- v_citas_activas: agenda vigente
-- ---------------------------------------------------------------------------
create view public.v_citas_activas
with (security_invoker = true) as
select c.id_cita,
       c.fecha_hora,
       c.estado,
       cl.nombre as nombre_cliente,
       s.nombre  as nombre_servicio,
       p.nombre  as nombre_profesional,
       d.duracion_min
from public.citas c
join public.clientes cl on cl.id_cliente = c.id_cliente
join public.detalle_cita d on d.id_cita = c.id_cita
join public.servicios s on s.id_servicio = d.id_servicio
join public.profesionales p on p.id_profesional = d.id_profesional
where c.estado in ('pendiente', 'confirmada', 'en_proceso');

-- ---------------------------------------------------------------------------
-- v_historial_completo_cliente: que se le hizo a cada cliente y con que
-- ---------------------------------------------------------------------------
create view public.v_historial_completo_cliente
with (security_invoker = true) as
select h.id_historial,
       cl.nombre as nombre_cliente,
       s.nombre  as nombre_servicio,
       p.nombre  as nombre_profesional,
       h.fecha_realizacion,
       h.costo_cobrado,
       (select string_agg(pr.nombre || ' (' || pu.cantidad_usada || ')', ', ' order by pr.nombre)
        from public.productos_utilizados pu
        join public.productos pr on pr.id_producto = pu.id_producto
        where pu.id_historial = h.id_historial) as productos_utilizados
from public.historial_servicio h
join public.clientes cl on cl.id_cliente = h.id_cliente
join public.servicios s on s.id_servicio = h.id_servicio
join public.profesionales p on p.id_profesional = h.id_profesional;

-- ---------------------------------------------------------------------------
-- v_stock_critico: productos en o por debajo del minimo
-- ---------------------------------------------------------------------------
create view public.v_stock_critico
with (security_invoker = true) as
select p.id_producto,
       p.nombre as nombre_producto,
       p.stock_minimo,
       p.stock_maximo,
       p.stock_actual,
       p.stock_minimo - p.stock_actual as diferencia
from public.productos p
where p.estado
  and p.stock_actual <= p.stock_minimo;

comment on view public.v_stock_critico is
    'diferencia = cuanto falta para volver al stock minimo.';

-- ---------------------------------------------------------------------------
-- v_comisiones_pendientes: lo que se le debe a cada profesional
-- ---------------------------------------------------------------------------
create view public.v_comisiones_pendientes
with (security_invoker = true) as
select pp.id_pago_prof,
       p.nombre  as nombre_profesional,
       s.nombre  as nombre_servicio,
       pp.monto  as monto_comision,
       h.fecha_realizacion,
       pp.estado
from public.pagos_profesional pp
join public.profesionales p on p.id_profesional = pp.id_profesional
join public.historial_servicio h on h.id_historial = pp.id_historial
join public.servicios s on s.id_servicio = h.id_servicio
where pp.estado = 'pendiente';

-- ---------------------------------------------------------------------------
-- v_ingresos_por_periodo: facturacion mensual
-- ---------------------------------------------------------------------------
create view public.v_ingresos_por_periodo
with (security_invoker = true) as
select extract(year from cc.fecha_pago)::int  as anio,
       extract(month from cc.fecha_pago)::int as mes,
       sum(cc.monto)                          as total_ingresos,
       count(*)                               as cantidad_servicios,
       round(avg(cc.monto), 2)                as ticket_promedio
from public.cobros_cliente cc
where cc.estado = 'pagado'
  and cc.fecha_pago is not null
group by 1, 2;

-- ---------------------------------------------------------------------------
-- v_pedidos_estado: seguimiento de compras
-- ---------------------------------------------------------------------------
create view public.v_pedidos_estado
with (security_invoker = true) as
select pe.id_pedido,
       pr.nombre as nombre_proveedor,
       pe.estado,
       pe.fecha_pedido,
       pe.total,
       (select string_agg(p.nombre || ' x' || dp.cantidad, ', ' order by p.nombre)
        from public.detalle_pedido dp
        join public.productos p on p.id_producto = dp.id_producto
        where dp.id_pedido = pe.id_pedido) as productos_incluidos
from public.pedidos pe
join public.proveedores pr on pr.id_proveedor = pe.id_proveedor;
