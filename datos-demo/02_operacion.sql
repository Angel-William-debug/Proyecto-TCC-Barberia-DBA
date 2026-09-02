-- ============================================================================
-- DATOS DE DEMOSTRACION DE LA BARBERIA
--
-- NO es una migracion y no vive en el repositorio: son datos del negocio, no
-- del esquema. Aplicarlo en cada despliegue seria sembrar clientes inventados
-- en una base real.
--
-- POR QUE NO INSERTA historial_servicio NI pagos_profesional
--
-- Porque los genera la base sola. `trg_cita_completada_after_update` corre
-- AFTER UPDATE cuando una cita pasa a 'completado' y, por cada linea del
-- detalle, crea su fila de historial y calcula la comision del barbero con
-- `fn_calcular_comision`. Insertar esas filas a mano daria numeros que no se
-- corresponden con el porcentaje de cada barbero y, sobre todo, dejaria sin
-- probar el disparador que importa.
--
-- Por eso cada turno del pasado recorre el ciclo real:
--     insert cita 'en_proceso'  ->  insert detalle  ->  update a 'completado'
--
-- El estado intermedio es 'en_proceso' y no 'pendiente' a proposito:
-- `trg_cita_validar` solo aplica las validaciones de tiempo -no agendar en el
-- pasado, respetar el horario de atencion- a las citas en 'pendiente' o
-- 'confirmado'. Un turno historico entra en 'en_proceso' y las esquiva, que
-- es exactamente para lo que esta escrita esa excepcion.
--
-- Es idempotente: si ya hay turnos cargados, no hace nada.
-- ============================================================================

do $demo$
declare
    v_id_recepcion  int;
    v_barberos      int[];
    v_servicios     int[];
    v_clientes      int[];
    v_metodos       int[];
    v_id_cliente    int;
    v_id_barbero    int;
    v_id_servicio   int;
    v_id_cita       int;
    v_id_cobro      int;
    v_id_factura    int;
    v_fecha         timestamptz;
    v_dia           date;
    -- La barberia vive en America/Asuncion y `trg_cita_validar` compara el
    -- horario de atencion contra la hora LOCAL. Construir las fechas en UTC
    -- -que es la zona de esta sesion- las corre tres horas y el disparador
    -- rechaza turnos que en local caen perfectamente dentro del horario.
    v_zona          constant text := 'America/Asuncion';
    v_total         numeric(10, 2);
    v_estado        text;
    v_i             int;
    v_n             int;
    v_dow           int;
    v_hora          int;
    v_creadas       int := 0;
    v_pesos         int[] := '{}';
    v_j             int;
begin
    -- Si ya hay operacion cargada no se toca nada.
    select count(*) into v_n from public.citas;
    if v_n > 1 then
        raise notice 'Ya hay % citas cargadas. No se hace nada.', v_n;
        return;
    end if;

    -- ------------------------------------------------------------------ 1
    -- Barberos: hasta llegar a seis
    -- ------------------------------------------------------------------ 1
    insert into public.profesionales (nombre, especialidad, tipo, porcentaje_com)
    select d.nombre, d.esp, d.tipo, d.com
      from (values
            ('Ramon Ferreira', 'Corte y color',         'barbero',        32),
            ('Julio Aquino',   'Afeitado clasico',      'barbero senior', 42)
           ) as d(nombre, esp, tipo, com)
     where not exists (select 1 from public.profesionales p
                        where p.nombre = d.nombre and not p.deleted);

    -- ------------------------------------------------------------------ 2
    -- Clientes del mostrador
    --
    -- Sin `id_usuario`: los registro la recepcionista y nunca abrieron cuenta
    -- en el portal, que es el caso mas comun en una barberia.
    -- ------------------------------------------------------------------ 2
    select id_usuario into v_id_recepcion
      from public.usuarios where email = 'recepcion@barbershop.com.py';

    insert into public.clientes (id_usuario_reg, nombre, email, telefono, direccion,
                                 fecha_nacimiento, fecha_registro)
    select v_id_recepcion, d.nombre, d.email, d.tel, d.dir, d.nac::date,
           now() - (d.antiguedad || ' days')::interval
      from (values
            ('Juan Carlos Gonzalez',  'jc.gonzalez@correo.com.py', '0981 234 111', 'San Lorenzo, Central',  '1988-04-12', 240),
            ('Pedro Benitez Caceres', 'pbenitez@correo.com.py',    '0982 345 222', 'Fernando de la Mora',   '1995-11-03', 215),
            ('Luis Alberto Cabrera',  null,                        '0971 456 333', null,                    '1979-07-22', 190),
            ('Carlos Vera Duarte',    'cvera@correo.com.py',       '0983 567 444', 'San Lorenzo, Central',  '1992-01-30', 175),
            ('Marco Antonio Duarte',  null,                        '0961 678 555', null,                    '2000-09-14', 160),
            ('Hugo Ramirez Sosa',     'hramirez@correo.com.py',    '0984 789 666', 'Capiata, Central',      '1985-03-08', 140),
            ('Sergio Villalba',       null,                        '0972 890 777', null,                    '1998-12-19', 120),
            ('Oscar Fernandez',       'ofernandez@correo.com.py',  '0985 901 888', 'San Lorenzo, Central',  '1990-06-25', 105),
            ('Nelson Aquino Riveros', null,                        '0973 012 999', null,                    '1983-02-11',  90),
            ('Rodrigo Martinez Ruiz', 'rmartinez@correo.com.py',   '0986 123 000', 'Luque, Central',        '1996-08-07',  75),
            ('Gustavo Espinola',      null,                        '0975 234 121', null,                    '1991-05-16',  60),
            ('Fernando Gimenez',      'fgimenez@correo.com.py',    '0987 345 232', 'San Lorenzo, Central',  '1987-10-29',  45),
            ('Alberto Nunez Ovelar',  null,                        '0976 456 343', null,                    '1994-03-04',  30),
            ('Ramon Insfran',         'rinsfran@correo.com.py',    '0988 567 454', 'Nemby, Central',        '1981-12-01',  20),
            ('Victor Hugo Acosta',    null,                        '0977 678 565', null,                    '1999-07-18',  10)
           ) as d(nombre, email, tel, dir, nac, antiguedad)
     where not exists (select 1 from public.clientes c
                        where c.nombre = d.nombre and not c.deleted);

    select array_agg(id_profesional order by id_profesional) into v_barberos
      from public.profesionales where estado and not deleted;
    select array_agg(id_servicio order by id_servicio) into v_servicios
      from public.servicios where estado and not deleted;
    select array_agg(id_cliente order by id_cliente) into v_clientes
      from public.clientes where estado and not deleted;
    select array_agg(id_metodo order by id_metodo) into v_metodos
      from public.metodos_pago where estado and not deleted;

    -- Reparto del trabajo entre barberos, con peso triangular: el primero
    -- aparece n veces, el segundo n-1, y asi. Da un ranking con diferencias
    -- reales en vez de todos iguales, y -a diferencia de `v_i * v_i % n`, que
    -- es lo que habia antes- alcanza a TODOS: los cuadrados modulo n solo
    -- toman unos pocos valores distintos, de modo que la mitad del equipo
    -- quedaba sin un solo turno.
    for v_i in 1..array_length(v_barberos, 1) loop
        for v_j in 1..(array_length(v_barberos, 1) - v_i + 1) loop
            v_pesos := v_pesos || v_i;
        end loop;
    end loop;

    -- ------------------------------------------------------------------ 3
    -- Noventa turnos de los ultimos tres meses, ya completados
    --
    -- La distribucion no es uniforme a proposito: los barberos senior toman
    -- mas turnos que los que recien entraron, para que el ranking muestre
    -- diferencias reales y no cuatro empatados.
    -- ------------------------------------------------------------------ 3
    for v_i in 1..90 loop
        v_dia := current_date - ((v_i * 89) % 88 + 1);

        -- La barberia cierra los domingos: ese turno se corre al lunes.
        if extract(isodow from v_dia) = 7 then
            v_dia := v_dia + 1;
        end if;

        v_hora  := 8 + ((v_i * 7) % 10);
        v_fecha := (v_dia + make_interval(hours => v_hora, mins => ((v_i * 15) % 4) * 15))
                   at time zone v_zona;

        v_id_barbero  := v_barberos[v_pesos[1 + (v_i % array_length(v_pesos, 1))]];
        v_id_servicio := v_servicios[1 + ((v_i * 3) % array_length(v_servicios, 1))];
        v_id_cliente  := v_clientes[1 + ((v_i * 5) % array_length(v_clientes, 1))];

        insert into public.citas (id_cliente, id_usuario, fecha_hora, estado, observaciones)
        values (v_id_cliente, v_id_recepcion, v_fecha, 'en_proceso', null)
        returning id_cita into v_id_cita;

        insert into public.detalle_cita
             (id_cita, id_servicio, id_profesional, duracion_min, precio_unit, subtotal)
        select v_id_cita, v_id_servicio, v_id_barbero, s.duracion_min, s.precio_base, s.precio_base
          from public.servicios s where s.id_servicio = v_id_servicio;

        -- Uno de cada cinco lleva un segundo servicio, con el mismo barbero.
        if v_i % 5 = 0 then
            insert into public.detalle_cita
                 (id_cita, id_servicio, id_profesional, duracion_min, precio_unit, subtotal)
            select v_id_cita, s.id_servicio, v_id_barbero, s.duracion_min, s.precio_base, s.precio_base
              from public.servicios s
             where s.id_servicio = v_servicios[1 + ((v_i * 2) % array_length(v_servicios, 1))]
               and s.id_servicio <> v_id_servicio;
        end if;

        -- Aca se disparan historial_servicio y pagos_profesional.
        update public.citas set estado = 'completado' where id_cita = v_id_cita;

        select total into v_total from public.citas where id_cita = v_id_cita;

        -- ---------------------------------------------------------- cobro
        -- Nueve de cada diez se cobran completos; uno queda parcial, que es
        -- el caso que habilita la RN-025.
        if v_i % 10 = 0 then
            insert into public.cobros_cliente (id_cita, id_metodo_pago, monto, estado, fecha_pago)
            values (v_id_cita, v_metodos[1 + (v_i % array_length(v_metodos, 1))],
                    round(v_total / 2, 2), 'parcial', v_fecha + interval '1 hour');
        else
            insert into public.cobros_cliente (id_cita, id_metodo_pago, monto, estado, fecha_pago)
            values (v_id_cita, v_metodos[1 + (v_i % array_length(v_metodos, 1))],
                    v_total, 'pagado', v_fecha + interval '1 hour')
            returning id_cobro into v_id_cobro;

            -- Uno de cada tres cobros pagados termina en comprobante.
            if v_i % 3 = 0 then
                insert into public.facturas (id_cliente, id_cita, id_cobro, fecha_emision,
                                             subtotal, total, estado)
                values (v_id_cliente, v_id_cita, v_id_cobro, v_fecha + interval '1 hour',
                        v_total, v_total, 'emitida')
                returning id_factura into v_id_factura;

                insert into public.detalle_factura
                     (id_factura, descripcion, cantidad, precio_unitario, subtotal)
                select v_id_factura, s.nombre, 1, d.precio_unit, d.subtotal
                  from public.detalle_cita d
                  join public.servicios s on s.id_servicio = d.id_servicio
                 where d.id_cita = v_id_cita;
            end if;
        end if;

        v_creadas := v_creadas + 1;
    end loop;

    -- ------------------------------------------------------------------ 3 bis
    -- Historial del cliente que usa el portal
    --
    -- Le toca por sorteo como a cualquiera, pero sin garantia: puede quedarse
    -- sin una sola visita y entonces su pantalla de Historial aparece vacia,
    -- que es justo lo que no sirve para mostrar el portal funcionando.
    -- ------------------------------------------------------------------ 3 bis
    select c.id_cliente into v_id_cliente
      from public.clientes c
      join public.usuarios u on u.id_usuario = c.id_usuario
     where u.email = 'cliente@correo.com.py' and not c.deleted;

    if v_id_cliente is not null then
        for v_i in 1..4 loop
            v_dia := current_date - (v_i * 23);
            if extract(isodow from v_dia) = 7 then
                v_dia := v_dia + 1;
            end if;
            v_fecha := (v_dia + make_interval(hours => 10 + v_i, mins => 30)) at time zone v_zona;

            insert into public.citas (id_cliente, id_usuario, fecha_hora, estado)
            values (v_id_cliente, v_id_recepcion, v_fecha, 'en_proceso')
            returning id_cita into v_id_cita;

            insert into public.detalle_cita
                 (id_cita, id_servicio, id_profesional, duracion_min, precio_unit, subtotal)
            select v_id_cita, s.id_servicio, v_barberos[1 + (v_i % array_length(v_barberos, 1))],
                   s.duracion_min, s.precio_base, s.precio_base
              from public.servicios s
             where s.id_servicio = v_servicios[1 + (v_i % array_length(v_servicios, 1))];

            update public.citas set estado = 'completado' where id_cita = v_id_cita;
            select total into v_total from public.citas where id_cita = v_id_cita;

            insert into public.cobros_cliente (id_cita, id_metodo_pago, monto, estado, fecha_pago)
            values (v_id_cita, v_metodos[1 + (v_i % array_length(v_metodos, 1))],
                    v_total, 'pagado', v_fecha + interval '1 hour')
            returning id_cobro into v_id_cobro;

            insert into public.facturas (id_cliente, id_cita, id_cobro, fecha_emision,
                                         subtotal, total, estado)
            values (v_id_cliente, v_id_cita, v_id_cobro, v_fecha + interval '1 hour',
                    v_total, v_total, 'emitida')
            returning id_factura into v_id_factura;

            insert into public.detalle_factura
                 (id_factura, descripcion, cantidad, precio_unitario, subtotal)
            select v_id_factura, s.nombre, 1, d.precio_unit, d.subtotal
              from public.detalle_cita d
              join public.servicios s on s.id_servicio = d.id_servicio
             where d.id_cita = v_id_cita;
        end loop;
    end if;

    -- ------------------------------------------------------------------ 4
    -- Turnos que no se concretaron
    -- ------------------------------------------------------------------ 4
    for v_i in 1..8 loop
        v_dia := current_date - (v_i * 9);
        if extract(isodow from v_dia) = 7 then
            v_dia := v_dia + 1;
        end if;
        v_fecha := (v_dia + make_interval(hours => 9 + (v_i % 8))) at time zone v_zona;

        v_estado := case when v_i % 2 = 0 then 'cancelado' else 'no_asistio' end;

        insert into public.citas (id_cliente, id_usuario, fecha_hora, estado, observaciones)
        values (v_clientes[1 + ((v_i * 4) % array_length(v_clientes, 1))],
                v_id_recepcion, v_fecha, 'en_proceso',
                case when v_estado = 'cancelado' then 'El cliente aviso por telefono' end)
        returning id_cita into v_id_cita;

        insert into public.detalle_cita
             (id_cita, id_servicio, id_profesional, duracion_min, precio_unit, subtotal)
        select v_id_cita, s.id_servicio,
               v_barberos[1 + (v_i % array_length(v_barberos, 1))],
               s.duracion_min, s.precio_base, s.precio_base
          from public.servicios s
         where s.id_servicio = v_servicios[1 + (v_i % array_length(v_servicios, 1))];

        update public.citas set estado = v_estado where id_cita = v_id_cita;
    end loop;

    -- ------------------------------------------------------------------ 5
    -- La agenda de los proximos dias
    -- ------------------------------------------------------------------ 5
    for v_i in 1..22 loop
        v_dia := current_date + ((v_i % 7) + 1);
        continue when extract(isodow from v_dia) = 7;

        v_fecha := (v_dia + make_interval(hours => 8 + ((v_i * 3) % 10),
                                          mins  => ((v_i * 2) % 4) * 15)) at time zone v_zona;

        insert into public.citas (id_cliente, id_usuario, fecha_hora, estado, observaciones)
        values (v_clientes[1 + ((v_i * 6) % array_length(v_clientes, 1))],
                v_id_recepcion, v_fecha,
                case when v_i % 3 = 0 then 'pendiente' else 'confirmado' end,
                null)
        returning id_cita into v_id_cita;

        begin
            insert into public.detalle_cita
                 (id_cita, id_servicio, id_profesional, duracion_min, precio_unit, subtotal)
            select v_id_cita, s.id_servicio,
                   v_barberos[1 + ((v_i * v_i) % array_length(v_barberos, 1))],
                   s.duracion_min, s.precio_base, s.precio_base
              from public.servicios s
             where s.id_servicio = v_servicios[1 + ((v_i * 4) % array_length(v_servicios, 1))];
        exception when others then
            -- Ese barbero ya estaba ocupado en esa franja (RN-015). Se
            -- descarta el turno entero en vez de dejar una cabecera sin
            -- detalle, que en la agenda apareceria como un hueco vacio.
            delete from public.citas where id_cita = v_id_cita;
        end;
    end loop;

    -- ------------------------------------------------------------------ 6
    -- Comisiones: se liquida el mes mas viejo
    -- ------------------------------------------------------------------ 6
    update public.pagos_profesional pp
       set estado = 'liquidado',
           fecha_liquidacion = current_date - 30
      from public.historial_servicio h
     where h.id_historial = pp.id_historial
       and h.fecha_realizacion < current_date - 60
       and pp.estado = 'pendiente';

    -- ------------------------------------------------------------------ 7
    -- Compras: dos ordenes, una recibida y otra en camino
    -- ------------------------------------------------------------------ 7
    declare
        v_id_pedido int;
        v_id_prov   int;
    begin
        select id_proveedor into v_id_prov from public.proveedores
         where not deleted order by id_proveedor limit 1;

        insert into public.pedidos (id_proveedor, id_usuario, fecha_pedido, estado)
        -- RN-036: los estados son pedido -> recibido -> completado | cancelado.
        -- No 'pendiente'/'enviado', que son los del esquema inicial y los
        -- reemplazo la migracion 7.
        values (v_id_prov, v_id_recepcion, now() - interval '20 days', 'pedido')
        returning id_pedido into v_id_pedido;

        insert into public.detalle_pedido (id_pedido, id_producto, cantidad, precio_unit, subtotal)
        select v_id_pedido, p.id_producto, 10, p.precio_unitario, 10 * p.precio_unitario
          from public.productos p where not p.deleted order by p.id_producto limit 3;

        -- Al pasar a 'recibido' el disparador suma el stock convirtiendo
        -- unidades de compra a unidades de uso.
        update public.pedidos set estado = 'recibido',
                                  fecha_recepcion = now() - interval '18 days'
         where id_pedido = v_id_pedido;

        insert into public.pagos_proveedor (id_pedido, id_metodo_pago, monto, fecha_pago, estado)
        select v_id_pedido, v_metodos[1], total, now() - interval '17 days', 'pagado'
          from public.pedidos where id_pedido = v_id_pedido;

        insert into public.pedidos (id_proveedor, id_usuario, fecha_pedido, estado)
        select id_proveedor, v_id_recepcion, now() - interval '3 days', 'pedido'
          from public.proveedores where not deleted order by id_proveedor desc limit 1
        returning id_pedido into v_id_pedido;

        insert into public.detalle_pedido (id_pedido, id_producto, cantidad, precio_unit, subtotal)
        select v_id_pedido, p.id_producto, 6, p.precio_unitario, 6 * p.precio_unitario
          from public.productos p where not p.deleted order by p.id_producto desc limit 2;
    end;

    raise notice 'Listo: % turnos completados generados.', v_creadas;
end;
$demo$;
