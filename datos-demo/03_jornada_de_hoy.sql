-- ============================================================================
-- LA JORNADA DE HOY
--
-- El seed general reparte turnos entre los ultimos tres meses y los proximos
-- siete dias, y en el medio se salteo el dia en curso. Justo el que la agenda
-- muestra al abrirse: la recepcionista entraba y veia «Turnos del dia 0».
--
-- Se cargan como completados, con el mismo ciclo que el resto -en_proceso y
-- despues completado- para que los disparadores generen historial y comision.
-- Van en horas ya pasadas del dia porque `trg_cita_validar` rechaza agendar
-- en el pasado solo cuando el estado es pendiente o confirmado; un turno que
-- ya se atendio no atraviesa esa validacion, que es para lo que existe la
-- excepcion.
-- ============================================================================

do $hoy$
declare
    v_id_recepcion int;
    v_barberos     int[];
    v_servicios    int[];
    v_clientes     int[];
    v_metodos      int[];
    v_id_cita      int;
    v_id_cobro     int;
    v_total        numeric(10, 2);
    v_fecha        timestamptz;
    v_i            int;
    v_n            int;
    v_zona         constant text := 'America/Asuncion';
begin
    select count(*) into v_n from public.citas
     where (fecha_hora at time zone v_zona)::date = (now() at time zone v_zona)::date;
    if v_n > 0 then
        raise notice 'Hoy ya tiene % turnos. No se hace nada.', v_n;
        return;
    end if;

    select id_usuario into v_id_recepcion
      from public.usuarios where email = 'recepcion@barbershop.com.py';

    select array_agg(id_profesional order by id_profesional) into v_barberos
      from public.profesionales where estado and not deleted;
    select array_agg(id_servicio order by id_servicio) into v_servicios
      from public.servicios where estado and not deleted;
    select array_agg(id_cliente order by id_cliente) into v_clientes
      from public.clientes where estado and not deleted;
    select array_agg(id_metodo order by id_metodo) into v_metodos
      from public.metodos_pago where estado and not deleted;

    for v_i in 1..7 loop
        v_fecha := ((now() at time zone v_zona)::date
                    + make_interval(hours => 7 + v_i, mins => ((v_i * 3) % 4) * 15))
                   at time zone v_zona;

        -- Solo lo que ya ocurrio: un turno «completado» en el futuro seria
        -- mentira, y uno «confirmado» en el pasado lo rechaza el disparador.
        continue when v_fecha >= now();

        insert into public.citas (id_cliente, id_usuario, fecha_hora, estado)
        values (v_clientes[1 + ((v_i * 7) % array_length(v_clientes, 1))],
                v_id_recepcion, v_fecha, 'en_proceso')
        returning id_cita into v_id_cita;

        insert into public.detalle_cita
             (id_cita, id_servicio, id_profesional, duracion_min, precio_unit, subtotal)
        select v_id_cita, s.id_servicio,
               v_barberos[1 + (v_i % array_length(v_barberos, 1))],
               s.duracion_min, s.precio_base, s.precio_base
          from public.servicios s
         where s.id_servicio = v_servicios[1 + ((v_i * 2) % array_length(v_servicios, 1))];

        update public.citas set estado = 'completado' where id_cita = v_id_cita;

        select total into v_total from public.citas where id_cita = v_id_cita;

        insert into public.cobros_cliente (id_cita, id_metodo_pago, monto, estado, fecha_pago)
        values (v_id_cita, v_metodos[1 + (v_i % array_length(v_metodos, 1))],
                v_total, 'pagado', v_fecha + interval '40 minutes')
        returning id_cobro into v_id_cobro;
    end loop;

    raise notice 'Jornada de hoy cargada.';
end;
$hoy$;
