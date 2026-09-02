-- ============================================================================
-- LOS TURNOS DEL CLIENTE, RESUELTOS
--
-- EL PROBLEMA
--
-- El portal pedia los turnos con las relaciones embebidas de PostgREST:
--
--     citas?select=...,detalle_cita(...,servicios(nombre),profesionales(nombre))
--
-- y el nombre del servicio y el del barbero llegaban VACIOS. No es un error de
-- la consulta: una relacion embebida atraviesa RLS como cualquier lectura, y
-- el rol `cliente` no tiene politica de SELECT sobre `servicios` ni sobre
-- `profesionales`. PostgREST no falla -devuelve null y sigue-, de modo que la
-- tarjeta salia con la tijera y el precio, sin decir que servicio era ni quien
-- lo iba a atender.
--
-- POR QUE NO SE RESUELVE ABRIENDO ESAS DOS TABLAS
--
-- Por `profesionales.porcentaje_com`. RLS decide FILAS, no columnas: darle al
-- cliente lectura sobre la tabla le daria tambien cuanto cobra de comision
-- cada barbero. Los permisos por columna de PostgreSQL tampoco sirven aca,
-- porque todos los roles de la aplicacion comparten el mismo rol de base
-- -`authenticated`- y revocar la columna se la quitaria tambien al
-- administrador.
--
-- POR QUE TAMPOCO ALCANZAN LAS VISTAS `v_publico_*`
--
-- Porque publican solo lo vigente: `where estado and not deleted`. Es lo
-- correcto para el catalogo -no se puede reservar un servicio dado de baja-
-- pero deja sin nombre a los turnos viejos de un servicio discontinuado o de
-- un barbero que ya no trabaja ahi. El historial no puede depender de que el
-- catalogo de hoy siga conteniendo lo de ayer.
--
-- LA SOLUCION
--
-- Una funcion SECURITY DEFINER que arma el turno entero. El alcance no lo
-- pone quien llama sino la propia funcion, con `fn_id_cliente_actual()`: si
-- devuelve NULL la comparacion no se cumple para ninguna fila y el resultado
-- es vacio, que es el comportamiento correcto para alguien sin ficha.
-- ============================================================================

create or replace function public.fn_mis_turnos()
returns table (
    id_cita            int,
    fecha_hora         timestamptz,
    estado             varchar(50),
    observaciones      text,
    total              numeric(10, 2),
    reservado_en       timestamptz,
    duracion_total_min int,
    fecha_hora_fin     timestamptz,
    servicios          json
)
language sql
stable
security definer
set search_path = public
as $fn$
    select c.id_cita,
           c.fecha_hora,
           c.estado,
           c.observaciones,
           c.total,
           c.created_at as reservado_en,
           coalesce(sum(d.duracion_min), 0)::int as duracion_total_min,
           -- El cast a int es obligatorio: sum() devuelve bigint y
           -- make_interval no acepta ese tipo. Misma trampa que resolvio la
           -- migracion 12 en v_agenda_dia.
           c.fecha_hora + make_interval(
               mins => coalesce(sum(d.duracion_min), 0)::int
           ) as fecha_hora_fin,
           coalesce(
               json_agg(
                   json_build_object(
                       'idServicio',  d.id_servicio,
                       'nombre',      s.nombre,
                       'barbero',     p.nombre,
                       'duracionMin', d.duracion_min,
                       'precio',      d.precio_unit
                   )
                   order by d.id_detalle
               ) filter (where d.id_detalle is not null),
               '[]'::json
           ) as servicios
      from public.citas c
      -- LEFT JOIN y no JOIN: una cita a la que le fallo la carga del detalle
      -- igual tiene que aparecer, aunque sea vacia. Ocultarla haria que el
      -- cliente no pueda ni verla ni cancelarla.
      left join public.detalle_cita  d on d.id_cita = c.id_cita
      left join public.servicios     s on s.id_servicio = d.id_servicio
      left join public.profesionales p on p.id_profesional = d.id_profesional
     where c.id_cliente = public.fn_id_cliente_actual()
       and not c.deleted
     group by c.id_cita, c.fecha_hora, c.estado, c.observaciones, c.total, c.created_at
     order by c.fecha_hora desc;
$fn$;

comment on function public.fn_mis_turnos is
    'Turnos del cliente autenticado, con el nombre del servicio y del barbero '
    'ya resueltos. SECURITY DEFINER porque el cliente no lee `servicios` ni '
    '`profesionales`: el alcance lo pone fn_id_cliente_actual(), no quien '
    'llama. Solo expone nombre, duracion y precio; nunca porcentaje_com.';

grant execute on function public.fn_mis_turnos() to authenticated;
