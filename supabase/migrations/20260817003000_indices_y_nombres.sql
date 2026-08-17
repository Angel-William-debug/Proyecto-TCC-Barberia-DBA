-- ============================================================================
-- INDICES FALTANTES Y CORRECCION DE NOMBRES
--
-- Los detalles menores del informe de auditoria. Ninguno rompia nada, pero
-- son el tipo de observacion que un evaluador senala en la defensa.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. La unica clave foranea sin indice
--
-- De las 36 claves foraneas del esquema, 35 estaban cubiertas -algunas por su
-- propia restriccion unique-. Esta quedaba sin indice, de modo que borrar o
-- actualizar un usuario obligaba a recorrer la tabla de movimientos entera.
-- ---------------------------------------------------------------------------
create index if not exists idx_movimientos_id_usuario
    on public.movimientos_inventario (id_usuario)
    where id_usuario is not null;

-- ---------------------------------------------------------------------------
-- 2. Nombre truncado
--
-- `fecha_liquid` era una abreviatura sin motivo. Se renombra a
-- `fecha_liquidacion`, que es como la llama el CU-009.
--
-- El renombrado NO rompe la vista v_comisiones_liquidadas creada en la
-- migracion anterior: PostgreSQL guarda las vistas por identificador interno
-- de columna, no por nombre, y actualiza la definicion sola. Igual se recrea
-- mas abajo para que el texto de la vista quede legible.
-- ---------------------------------------------------------------------------
do $$
begin
    if exists (
        select 1 from information_schema.columns
         where table_schema = 'public'
           and table_name = 'pagos_profesional'
           and column_name = 'fecha_liquid'
    ) then
        alter table public.pagos_profesional
            rename column fecha_liquid to fecha_liquidacion;
    end if;
end;
$$;

comment on column public.pagos_profesional.fecha_liquidacion is
    'CU-009. Fecha en que se pago la comision al barbero.';

-- Se recrea con el nombre nuevo para que la definicion almacenada sea legible.
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
       pp.fecha_liquidacion
from public.pagos_profesional pp
join public.profesionales p on p.id_profesional = pp.id_profesional
join public.historial_servicio h on h.id_historial = pp.id_historial
join public.servicios s on s.id_servicio = h.id_servicio
where pp.estado = 'liquidado';

comment on view public.v_comisiones_liquidadas is
    'CU-009. Comisiones ya pagadas. Un pago liquidado no se puede revertir (RN-027).';

-- ---------------------------------------------------------------------------
-- 3. Indices para los filtros que el frontend usa a diario
--
-- La seccion 9.9 del sistema de diseno fija que toda tabla filtra por estado
-- y por rango de fechas. Estos indices sostienen esos filtros cuando las
-- tablas crezcan.
-- ---------------------------------------------------------------------------
create index if not exists idx_cobros_estado       on public.cobros_cliente (estado);
create index if not exists idx_cobros_fecha_pago   on public.cobros_cliente (fecha_pago desc nulls last);
create index if not exists idx_pagos_prof_estado   on public.pagos_profesional (estado);
create index if not exists idx_movimientos_tipo    on public.movimientos_inventario (tipo);
create index if not exists idx_auditoria_accion    on public.auditoria (accion);
create index if not exists idx_historial_fecha_cli on public.historial_servicio (id_cliente, fecha_realizacion desc);

-- El ultimo sostiene v_clientes_resumen, que agrupa el historial por cliente
-- y es la base de las tres vistas de fidelizacion.
