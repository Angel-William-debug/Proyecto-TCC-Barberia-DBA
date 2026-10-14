-- =============================================================================
-- Movimientos manuales de inventario (vistas 66 y 67 del anexo, 15/10/2026)
-- =============================================================================
--
-- Hasta ahora el stock solo cambiaba por dos caminos automaticos: la
-- recepcion de un pedido (entrada) y el cierre de un servicio (salida). No
-- habia forma de cargar mercaderia que llego sin orden, de dar de baja un
-- frasco roto, ni de corregir el stock despues de contar la estanteria.
--
-- fn_movimiento_manual hace las dos cosas juntas -cambiar el stock y dejar el
-- movimiento- en una sola transaccion, para que nunca quede una sin la otra:
--
--   entrada  suma p_cantidad.
--   salida   resta p_cantidad (merma, rotura, uso interno). No deja el stock
--            negativo: lo impide trg_stock_no_negativo (RN-031).
--   ajuste   p_cantidad es lo que se CONTO. Se registra la diferencia con el
--            stock del sistema; el motivo guarda de cuanto a cuanto se paso,
--            porque movimientos_inventario.cantidad es siempre positiva.
--
-- Es security invoker: corre con los permisos de quien llama, asi que la
-- regla de quien puede tocar el stock sigue siendo la de RLS (administrador y
-- recepcionista).
-- =============================================================================

create or replace function public.fn_movimiento_manual(
    p_id_producto integer,
    p_tipo        text,
    p_cantidad    numeric,
    p_motivo      text
)
returns numeric
language plpgsql
security invoker
set search_path = public
as $$
declare
    v_actual   numeric;
    v_nuevo    numeric;
    v_mov      numeric;
    v_motivo   text := nullif(btrim(coalesce(p_motivo, '')), '');
    v_usuario  integer;
begin
    if p_tipo not in ('entrada', 'salida', 'ajuste') then
        raise exception 'Tipo de movimiento invalido: %', p_tipo;
    end if;
    if v_motivo is null then
        raise exception 'MOV-001: indique el motivo del movimiento';
    end if;
    if p_cantidad is null or p_cantidad < 0 or (p_tipo <> 'ajuste' and p_cantidad = 0) then
        raise exception 'MOV-002: la cantidad debe ser mayor a cero';
    end if;

    select stock_actual into v_actual
    from public.productos
    where id_producto = p_id_producto and not deleted
    for update;

    if not found then
        raise exception 'Producto % inexistente', p_id_producto;
    end if;

    v_nuevo := case p_tipo
        when 'entrada' then v_actual + p_cantidad
        when 'salida'  then v_actual - p_cantidad
        else p_cantidad
    end;
    v_mov := abs(v_nuevo - v_actual);

    if v_mov = 0 then
        raise exception 'MOV-003: el conteo coincide con el stock del sistema; no hay nada que ajustar';
    end if;

    if p_tipo = 'ajuste' then
        v_motivo := format('%s (conteo: de %s a %s)', v_motivo, trim_scale(v_actual), trim_scale(v_nuevo));
    end if;

    select u.id_usuario into v_usuario from public.usuarios u where u.auth_uid = auth.uid();

    update public.productos set stock_actual = v_nuevo where id_producto = p_id_producto;

    insert into public.movimientos_inventario (id_producto, id_usuario, tipo, cantidad, motivo)
    values (p_id_producto, v_usuario, p_tipo, v_mov, left(v_motivo, 500));

    return v_nuevo;
end;
$$;

comment on function public.fn_movimiento_manual(integer, text, numeric, text) is
    'Entrada, salida o ajuste por conteo cargado a mano. Cambia el stock y deja el movimiento en la misma transaccion.';

grant execute on function public.fn_movimiento_manual(integer, text, numeric, text) to authenticated;
