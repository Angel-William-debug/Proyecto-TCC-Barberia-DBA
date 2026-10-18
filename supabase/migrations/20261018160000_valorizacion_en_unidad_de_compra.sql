-- =============================================================================
-- Valorizacion del inventario en la unidad en que se compra (18/10/2026)
-- =============================================================================
--
-- El stock se lleva en la unidad de USO (ml, g, unidades: lo que descuenta
-- cada servicio) y el precio es el de la unidad de COMPRA (el frasco de 1 L,
-- el pote de 100 g). Las dos vistas multiplicaban una cosa por la otra: 4.500
-- ml de shampoo por Gs. 85.000 el litro daba Gs. 382 millones. Con pocos
-- datos y productos de una sola unidad no se notaba; con la carga completa
-- la valorizacion daba Gs. 2.776 millones.
--
-- Ahora el stock se convierte a unidades de compra con
-- cantidad_uso_estandar (cuantas unidades de uso trae cada una), que es el
-- mismo dato que usa fn_trg_pedido_recibido para sumar al recibir una orden.
-- Sin equivalencia cargada, vale 1: el producto se compra y se usa por unidad.
-- Las columnas no cambian.
-- =============================================================================

create or replace view public.v_valorizacion_inventario as
select p.id_producto,
       p.nombre as nombre_producto,
       cp.nombre as categoria,
       p.stock_actual,
       p.precio_unitario,
       round(p.stock_actual / coalesce(nullif(p.cantidad_uso_estandar, 0), 1) * p.precio_unitario, 2) as valor_total
from public.productos p
join public.categorias_producto cp on cp.id_categoria_p = p.id_categoria_p
where p.estado;

create or replace view public.v_inventario_valorizado as
select p.id_producto,
       p.nombre,
       cp.nombre as categoria,
       p.stock_actual,
       p.stock_minimo,
       p.stock_maximo,
       p.precio_unitario,
       round(greatest(p.stock_actual, 0) / coalesce(nullif(p.cantidad_uso_estandar, 0), 1) * p.precio_unitario, 2) as valor_stock,
       case
         when p.stock_actual <= 0 then 'sin_stock'
         when p.stock_actual <= p.stock_minimo then 'critico'
         when p.stock_actual <= p.stock_minimo * 1.5 then 'bajo'
         when p.stock_maximo is not null and p.stock_actual > p.stock_maximo then 'sobrestock'
         else 'disponible'
       end as nivel
from public.productos p
join public.categorias_producto cp on cp.id_categoria_p = p.id_categoria_p
where not p.deleted and p.estado;
