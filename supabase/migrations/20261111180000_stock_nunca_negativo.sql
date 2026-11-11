-- =============================================================================
-- El stock nunca queda negativo (re-prueba de la Fase 2 de QA, 11/11/2026)
-- =============================================================================
--
-- Hasta hoy el cierre de un servicio podia consumir mas de lo cargado, como
-- "excepcion de stock" (CU-007 A1, CU-011 A1, migracion 20260812210000), y el
-- producto quedaba en negativo. En la re-prueba de F2-02 se decidio lo
-- contrario: un producto no puede tener menos de cero unidades. Si se uso
-- mas de lo que figura, falta registrar una entrada o un ajuste, y eso se
-- hace ANTES de confirmar el consumo.
--
-- 1. Los productos que hoy estan en negativo pasan a 0 con un ajuste por
--    conteo, que queda en movimientos_inventario como cualquier otro.
-- 2. fn_trg_stock_no_negativo ya no tiene el permiso de excepcion: rechaza
--    siempre (RN-031). Y vuelve el CHECK stock_actual >= 0, por si algun
--    camino desactiva los disparadores.
-- 3. fn_actualizar_stock conserva su firma (la usa fn_trg_producto_utilizado)
--    pero ignora p_permitir_negativo.
-- 4. productos_utilizados.excepcion_stock queda solo para los consumos
--    viejos: un consumo nuevo no puede marcarse como excepcion.
-- =============================================================================

-- 1 ---------------------------------------------------------------------------
insert into public.movimientos_inventario (id_producto, id_usuario, tipo, cantidad, motivo)
select p.id_producto,
       (select u.id_usuario
        from public.usuarios u
        join public.roles r on r.id_rol = u.id_rol
        where r.nombre = 'administrador' and u.estado and not u.deleted
        order by u.id_usuario
        limit 1),
       'ajuste',
       -p.stock_actual,
       format('Corrección: el stock no puede ser negativo (conteo: de %s a 0)', trim_scale(p.stock_actual))
from public.productos p
where p.stock_actual < 0;

update public.productos
set stock_actual = 0
where stock_actual < 0;

-- 2 ---------------------------------------------------------------------------
create or replace function public.fn_trg_stock_no_negativo()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if new.stock_actual < 0 then
        raise exception
            'RN-031: no alcanza el stock de "%" (hay %, faltan %)',
            new.nombre, trim_scale(old.stock_actual), trim_scale(-new.stock_actual);
    end if;

    return new;
end;
$$;

alter table public.productos
    add constraint productos_stock_actual_check check (stock_actual >= 0);

-- 3 ---------------------------------------------------------------------------
create or replace function public.fn_actualizar_stock(
    p_id_producto       int,
    p_cantidad          numeric,
    p_permitir_negativo boolean default false
)
returns void
language plpgsql
set search_path = public
as $$
begin
    -- p_permitir_negativo se ignora desde el 11/11/2026: el stock nunca
    -- queda negativo (RN-031). Se mantiene para no cambiar la firma.
    update public.productos
    set stock_actual = stock_actual - p_cantidad
    where id_producto = p_id_producto;

    if not found then
        raise exception 'Producto % inexistente', p_id_producto;
    end if;
end;
$$;

comment on function public.fn_actualizar_stock(int, numeric, boolean) is
    'Descuenta stock. RN-031: si no alcanza, lo rechaza trg_stock_no_negativo; p_permitir_negativo ya no tiene efecto.';

-- 4 ---------------------------------------------------------------------------
alter table public.productos_utilizados
    add constraint productos_utilizados_sin_excepcion check (not excepcion_stock) not valid;

comment on column public.productos_utilizados.excepcion_stock is
    'Historico: consumos que dejaron el stock en negativo antes del 11/11/2026. Ya no se admite uno nuevo.';
