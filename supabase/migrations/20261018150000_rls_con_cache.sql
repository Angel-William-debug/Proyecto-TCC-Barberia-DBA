-- =============================================================================
-- RLS 200 veces mas rapido: las funciones de las politicas, una vez por consulta
-- (18/10/2026)
-- =============================================================================
--
-- Con la carga de seis meses aparecio lo que con pocos datos no se veia:
-- Reportes y Ranking fallaban por el limite de 8 segundos del rol
-- authenticated. La misma vista tardaba 0,007 s sin RLS y 1,5 s con RLS.
--
-- La causa: 73 de las 80 politicas llaman a fn_es_admin(), fn_rol_actual(),
-- fn_id_profesional_actual(), fn_id_cliente_actual() o auth.uid() tal cual,
-- y Postgres las evalua FILA POR FILA. Cada llamada es una consulta a
-- usuarios. Escritas como (select fn_es_admin()), Postgres las calcula una
-- sola vez por consulta (un «initPlan») y reusa el resultado. Es la forma que
-- recomienda Supabase en su guia de rendimiento de RLS.
--
-- QUE CAMBIA: solo la forma de la expresion. Las condiciones son las mismas,
-- con los mismos roles, las mismas tablas y las mismas columnas: lo que cada
-- rol puede ver y escribir no se toca. Se verifico contando, para cada rol y
-- cada tabla, las filas visibles antes y despues: dieron iguales.
--
-- Se hace sobre lo que hay en pg_policies, en vez de reescribir a mano 73
-- politicas repartidas en 20 migraciones: ALTER POLICY cambia la expresion
-- sin tocar el nombre, el comando ni los roles.
-- =============================================================================

do $$
declare
  p record;
  v_qual text;
  v_check text;
  v_sql text;
  -- La funcion sin envolver; las que ya estan dentro de un SELECT se dejan.
  v_funcion constant text :=
    '(?<!select )(?<!select public\.)\m(public\.)?(fn_es_admin|fn_rol_actual|fn_id_profesional_actual|fn_id_cliente_actual)\(\)';
  v_uid constant text := '(?<!select )\mauth\.uid\(\)';
begin
  for p in
    select schemaname, tablename, policyname, qual, with_check
    from pg_policies
    where schemaname = 'public'
  loop
    v_qual := regexp_replace(regexp_replace(p.qual, v_funcion, '(select public.\2())', 'gi'), v_uid, '(select auth.uid())', 'gi');
    v_check := regexp_replace(regexp_replace(p.with_check, v_funcion, '(select public.\2())', 'gi'), v_uid, '(select auth.uid())', 'gi');

    if v_qual is distinct from p.qual or v_check is distinct from p.with_check then
      v_sql := format('alter policy %I on %I.%I', p.policyname, p.schemaname, p.tablename);
      if v_qual is not null then v_sql := v_sql || format(' using (%s)', v_qual); end if;
      if v_check is not null then v_sql := v_sql || format(' with check (%s)', v_check); end if;
      execute v_sql;
    end if;
  end loop;
end $$;
