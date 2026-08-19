-- ============================================================================
-- CONVERSION DE UNIDADES AL RECIBIR UNA COMPRA
--
-- `productos.unidad_medida` es la unidad en la que se compra (ej. "frasco");
-- `productos.unidad_uso` es la unidad en la que se consume (ej. "ml"), y es la
-- misma en que ya se descuenta el stock desde `productos_utilizados.cantidad_usada`
-- (RN-021). `cantidad_uso_estandar` es cuantas unidades de uso trae una unidad
-- de medida (ej. 1 frasco = 500 ml).
--
-- `fn_trg_pedido_recibido` sumaba `detalle_pedido.cantidad` directamente al
-- stock, sin convertir: una orden de "3" quedaba como 3 unidades de stock
-- aunque el producto se consumiera de a mililitros. El stock terminaba
-- mezclando dos unidades distintas en el mismo numero.
--
-- Esta migracion NO toca `detalle_pedido.cantidad`: sigue siendo "cuantas
-- unidades de medida se pidieron" (3 frascos), que es como lo carga el
-- formulario de la orden. La conversion se aplica una sola vez, al recibir el
-- pedido, para que `stock_actual` y `movimientos_inventario.cantidad` queden
-- siempre en unidad de uso -la misma unidad en la que despues se descuentan-.
--
-- Productos sin `cantidad_uso_estandar` (el campo es opcional: hay productos
-- simples donde la unidad de compra y la de uso coinciden, ej. "unidad") no se
-- convierten: se usa 1 como factor, que es el comportamiento de siempre.
-- ============================================================================

create or replace function public.fn_trg_pedido_recibido()
returns trigger
language plpgsql
set search_path = public
as $$
declare
    r_detalle record;
    v_cantidad_stock numeric(12, 2);
begin
    for r_detalle in
        select dp.id_producto, dp.cantidad, p.cantidad_uso_estandar
        from public.detalle_pedido dp
        join public.productos p on p.id_producto = dp.id_producto
        where dp.id_pedido = new.id_pedido
    loop
        v_cantidad_stock := r_detalle.cantidad * coalesce(r_detalle.cantidad_uso_estandar, 1);

        update public.productos
        set stock_actual = stock_actual + v_cantidad_stock
        where id_producto = r_detalle.id_producto;

        insert into public.movimientos_inventario (id_producto, id_usuario, tipo, cantidad, motivo)
        values (
            r_detalle.id_producto,
            new.id_usuario,
            'entrada',
            v_cantidad_stock,
            case
                when r_detalle.cantidad_uso_estandar is not null then
                    format('Recepcion de pedido %s (%s unidades de compra x %s)',
                           new.id_pedido, r_detalle.cantidad, r_detalle.cantidad_uso_estandar)
                else
                    format('Recepcion de pedido %s', new.id_pedido)
            end
        );
    end loop;

    -- Alertas resueltas: el reabastecimiento saco al producto del minimo
    update public.alertas_stock a
    set resuelta = true
    from public.productos p
    where a.id_producto = p.id_producto
      and not a.resuelta
      and p.stock_actual > p.stock_minimo;

    perform public.fn_registrar_auditoria(
        'pedidos', 'UPDATE', new.id_pedido, 'Pedido recibido: stock actualizado'
    );

    return null;
end;
$$;

comment on function public.fn_trg_pedido_recibido() is
    'Al recibir un pedido, convierte cantidad (unidad de medida) a unidad de uso '
    'con cantidad_uso_estandar antes de sumarla al stock. Sin ese dato, factor 1.';

comment on column public.productos.cantidad_uso_estandar is
    'Cuantas unidades de uso trae una unidad de medida (ej. 1 frasco = 500 ml). '
    'La usa fn_trg_pedido_recibido() para convertir la compra al recibirla.';
