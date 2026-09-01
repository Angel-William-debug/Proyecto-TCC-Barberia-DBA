-- ============================================================================
-- PORTAL DEL CLIENTE - VINCULO, CONTEXTO Y ACCESO
--
-- El rol `cliente` existe en `roles` desde la migracion de datos iniciales,
-- pero hasta hoy no tenia una sola politica RLS: la migracion 9
-- (`rls_por_rol`) lo dejo escrito como "el rol queda reservado". Esa decision
-- se revierte: el portal del cliente pasa a ser parte del alcance.
--
-- POR QUE NO ALCANZABA CON AGREGAR POLITICAS
--
-- No habia forma de escribir "el cliente ve sus citas". `clientes` no guarda
-- a que cuenta pertenece: su unica columna hacia `usuarios` es
-- `id_usuario_reg`, que identifica a QUIEN LO REGISTRO -la recepcionista-, no
-- al cliente. Sin el vinculo, cualquier politica del rol seria imposible de
-- expresar. Por eso esta migracion empieza por la columna y no por las
-- politicas.
--
-- ADEMAS SE CORRIGE UN DEFECTO QUE HOY DEJA ENTRAR SOLO AL ADMINISTRADOR
--
-- `usuarioActual()` -la funcion que resuelve la sesion en el frontend- lee
-- `public.usuarios` para obtener el rol del que inicia sesion. Pero `usuarios`
-- y `roles` quedaron en el grupo de tablas exclusivas del Administrador, con
-- `admin_total` como unica politica. Consecuencia: para una recepcionista o un
-- profesional esa consulta devuelve cero filas, `usuarioActual()` devuelve
-- null y el sistema los trata como si no tuvieran sesion. Nunca se detecto
-- porque la base en la nube no tiene usuarios reales cargados y el recorrido
-- de prueba se hizo en modo demostracion.
--
-- El portal del cliente choca contra la misma pared, asi que se arregla aca
-- para los cuatro roles: cada quien puede leer SU PROPIA ficha, y nada mas.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Cada usuario lee su propia ficha y el catalogo de roles
--
-- El alta, la baja y el cambio de rol siguen siendo exclusivos del
-- Administrador: estas politicas son de SELECT y estan acotadas a la fila
-- cuyo `auth_uid` es el del solicitante. Nadie ve la ficha de otro.
--
-- `roles` se abre entero a lectura porque son cuatro filas de catalogo
-- -nombre y descripcion- sin dato sensible, y `usuarioActual()` necesita
-- resolver el nombre del rol en el mismo `select`.
-- ---------------------------------------------------------------------------
create policy "usuario_ve_su_ficha" on public.usuarios
    for select to authenticated
    using (auth_uid = auth.uid());

create policy "lectura_de_roles" on public.roles
    for select to authenticated
    using (estado);

-- `usuarioActual()` tambien pide `profesionales(id_profesional)` en el mismo
-- select para saber si el usuario es ademas barbero. El profesional ya lee
-- `profesionales` por `consulta_operativa`, pero el cliente no, y sin esta
-- politica el join le devolveria null en vez de fallar: silencioso y
-- confuso. Se acota a la propia fila.
create policy "usuario_ve_su_ficha_profesional" on public.profesionales
    for select to authenticated
    using (id_usuario = (
        select u.id_usuario from public.usuarios u where u.auth_uid = auth.uid()
    ));

-- ---------------------------------------------------------------------------
-- 2. El vinculo que faltaba: la cuenta del cliente
--
-- Nullable a proposito. La barberia atiende gente que nunca va a abrir una
-- cuenta: la recepcionista la registra desde el mostrador y esa ficha se
-- queda sin `id_usuario`. Obligar la columna significaria crear una cuenta
-- de acceso por cada persona que pasa una vez, que es exactamente lo que no
-- se quiere.
--
-- El UNIQUE es un indice PARCIAL, por la misma razon que obligo a lo mismo en
-- la migracion de borrado logico: sin `where not deleted`, borrar logicamente
-- a un cliente deja su cuenta bloqueada para siempre y nadie puede volver a
-- vincularla.
-- ---------------------------------------------------------------------------
alter table public.clientes
    add column id_usuario int references public.usuarios (id_usuario) on delete set null;

comment on column public.clientes.id_usuario is
    'Cuenta con la que este cliente ingresa al portal. NULL si fue registrado '
    'en el mostrador y nunca abrio una cuenta. No confundir con id_usuario_reg, '
    'que es quien lo registro.';

create unique index uq_clientes_id_usuario on public.clientes (id_usuario)
    where id_usuario is not null and not deleted;

-- ---------------------------------------------------------------------------
-- 3. Contexto del cliente autenticado
--
-- SECURITY DEFINER por la misma razon que `fn_id_profesional_actual`: la
-- funcion tiene que poder leer `usuarios` y `clientes` para resolver la
-- identidad, y es justamente ese resultado el que despues decide que filas
-- puede leer. Sin DEFINER la politica se llamaria a si misma.
-- ---------------------------------------------------------------------------
create or replace function public.fn_id_cliente_actual()
returns int
language sql
stable
security definer
set search_path = public
as $fn$
    select c.id_cliente
    from public.clientes c
    join public.usuarios u on u.id_usuario = c.id_usuario
    where u.auth_uid = auth.uid()
      and u.estado
      and c.estado
      and not c.deleted
      and not u.deleted
    limit 1;
$fn$;

comment on function public.fn_id_cliente_actual is
    'Ficha de cliente del usuario autenticado. NULL si no tiene una vinculada, '
    'si esta desactivado o si fue borrado.';

-- ---------------------------------------------------------------------------
-- 4. El cliente no puede tocar los campos de control de su propia ficha
--
-- La politica de UPDATE de mas abajo lo deja editar su ficha, que es lo que
-- se quiere: telefono, direccion, nombre. Pero RLS decide FILAS, no columnas,
-- y sobre su propia fila esa misma politica lo habilitaria a ponerse
-- `deleted = true`, a desactivarse, o a soltar el vinculo con su cuenta.
-- Ninguna de las tres es una edicion de perfil; son operaciones de
-- administracion sobre una fila que resulta ser la suya.
-- ---------------------------------------------------------------------------
create or replace function public.fn_trg_cliente_campos_de_control()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
begin
    -- El administrador y la recepcionista si administran estos campos.
    if public.fn_rol_actual() in ('administrador', 'recepcionista') then
        return new;
    end if;

    if new.id_usuario        is distinct from old.id_usuario
       or new.estado         is distinct from old.estado
       or new.deleted        is distinct from old.deleted
       or new.deleted_at     is distinct from old.deleted_at
       or new.id_usuario_reg is distinct from old.id_usuario_reg then
        raise exception
            'Un cliente no puede modificar los campos de control de su ficha.';
    end if;

    return new;
end;
$fn$;

create trigger trg_cliente_campos_de_control
    before update on public.clientes
    for each row
    execute function public.fn_trg_cliente_campos_de_control();

-- ---------------------------------------------------------------------------
-- 5. Lo que el cliente ve y hace
--
-- Toda politica cuelga de `fn_id_cliente_actual()`. Si devuelve NULL -alguien
-- con rol cliente pero sin ficha vinculada- ninguna comparacion se cumple y
-- el resultado es cero filas, que es el comportamiento correcto.
-- ---------------------------------------------------------------------------

-- Su ficha: la ve y la edita. El alta la hace el registro publico con la
-- clave de servicio, no el propio cliente.
create policy "cliente_ve_su_ficha" on public.clientes
    for select to authenticated
    using (id_cliente = public.fn_id_cliente_actual());

create policy "cliente_edita_su_ficha" on public.clientes
    for update to authenticated
    using (id_cliente = public.fn_id_cliente_actual())
    with check (id_cliente = public.fn_id_cliente_actual());

-- Sus turnos. Puede agendar y puede cancelar.
create policy "cliente_ve_sus_citas" on public.citas
    for select to authenticated
    using (id_cliente = public.fn_id_cliente_actual());

-- El estado se fuerza a 'pendiente': quien agenda no confirma su propio
-- turno. La confirmacion es del mostrador (CU-004).
create policy "cliente_agenda_su_cita" on public.citas
    for insert to authenticated
    with check (
        id_cliente = public.fn_id_cliente_actual()
        and estado = 'pendiente'
    );

-- Cancelar y nada mas. `trg_cita_inmutable` ya impide tocar una cita
-- completada o cancelada (RN-018); esto agrega que el cliente tampoco pueda
-- reagendarse solo ni darse por confirmado.
create policy "cliente_cancela_su_cita" on public.citas
    for update to authenticated
    using (
        id_cliente = public.fn_id_cliente_actual()
        and estado in ('pendiente', 'confirmado')
    )
    with check (
        id_cliente = public.fn_id_cliente_actual()
        and estado = 'cancelado'
    );

-- Los servicios de sus turnos. El INSERT es necesario para que agendar
-- funcione: una cita sin detalle no tiene ni servicios ni total.
create policy "cliente_ve_el_detalle_de_sus_citas" on public.detalle_cita
    for select to authenticated
    using (exists (
        select 1 from public.citas c
        where c.id_cita = detalle_cita.id_cita
          and c.id_cliente = public.fn_id_cliente_actual()
    ));

create policy "cliente_carga_el_detalle_de_su_cita" on public.detalle_cita
    for insert to authenticated
    with check (exists (
        select 1 from public.citas c
        where c.id_cita = detalle_cita.id_cita
          and c.id_cliente = public.fn_id_cliente_actual()
          and c.estado = 'pendiente'
    ));

-- Su historial de servicios recibidos.
create policy "cliente_ve_su_historial" on public.historial_servicio
    for select to authenticated
    using (id_cliente = public.fn_id_cliente_actual());

-- Sus cobros. Solo lectura: el cliente consulta cuanto pago y como, pero el
-- cobro lo registra el mostrador (CU-008).
create policy "cliente_ve_sus_cobros" on public.cobros_cliente
    for select to authenticated
    using (exists (
        select 1 from public.citas c
        where c.id_cita = cobros_cliente.id_cita
          and c.id_cliente = public.fn_id_cliente_actual()
    ));

-- Sus facturas, con sus lineas.
create policy "cliente_ve_sus_facturas" on public.facturas
    for select to authenticated
    using (id_cliente = public.fn_id_cliente_actual());

create policy "cliente_ve_el_detalle_de_sus_facturas" on public.detalle_factura
    for select to authenticated
    using (exists (
        select 1 from public.facturas f
        where f.id_factura = detalle_factura.id_factura
          and f.id_cliente = public.fn_id_cliente_actual()
    ));

-- Sus recomendaciones (CU-013), que es lo que el portal le sugiere agendar.
create policy "cliente_ve_sus_recomendaciones" on public.recomendaciones_ml
    for select to authenticated
    using (id_cliente = public.fn_id_cliente_actual());

-- ---------------------------------------------------------------------------
-- 6. El catalogo publico
--
-- El cliente necesita ver servicios, barberos y horarios ANTES de agendar, y
-- conviene que la portada tambien pueda mostrarlos sin obligar a iniciar
-- sesion.
--
-- POR QUE VISTAS Y NO POLITICAS DE LECTURA SOBRE LAS TABLAS
--
-- Porque RLS filtra filas, no columnas. Abrir `profesionales` a lectura le
-- daria al cliente `porcentaje_com`, que es cuanto cobra de comision cada
-- barbero. Una politica no puede esconder esa columna; una vista si.
--
-- Estas tres vistas se declaran SIN `security_invoker`, al reves que las 31
-- existentes. Es deliberado: al ejecutarse con los permisos de su dueno
-- atraviesan RLS, y lo que se publica es exactamente la lista de columnas
-- escrita aca -precio, duracion, nombre, horario-, nada mas.
-- ---------------------------------------------------------------------------
create view public.v_publico_servicios as
select s.id_servicio,
       s.nombre,
       s.descripcion,
       cs.nombre      as categoria,
       s.duracion_min,
       s.precio_base
from public.servicios s
join public.categorias_servicio cs on cs.id_categoria = s.id_categoria
where s.estado
  and not s.deleted
  and cs.estado
  and not cs.deleted;

comment on view public.v_publico_servicios is
    'Catalogo de servicios visible sin iniciar sesion. Sin receta ni costo: '
    'solo lo que el cliente necesita para elegir.';

create view public.v_publico_barberos as
select p.id_profesional,
       p.nombre,
       p.especialidad
from public.profesionales p
where p.estado
  and not p.deleted;

comment on view public.v_publico_barberos is
    'Barberos activos. Excluye porcentaje_com a proposito: la comision no es '
    'informacion del cliente.';

create view public.v_publico_horarios as
select h.dia_semana,
       h.hora_apertura,
       h.hora_cierre,
       h.activo
from public.horarios_atencion h;

comment on view public.v_publico_horarios is
    'Horario de atencion por dia, para que el portal muestre cuando se puede '
    'agendar.';

grant select on public.v_publico_servicios to anon, authenticated;
grant select on public.v_publico_barberos  to anon, authenticated;
grant select on public.v_publico_horarios  to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 7. El rol deja de estar reservado
-- ---------------------------------------------------------------------------
update public.roles
   set descripcion = 'Agenda y consulta sus propios turnos, historial y facturas'
 where nombre = 'cliente';

comment on table public.roles is
    'Roles del sistema: administrador, recepcionista, profesional y cliente. '
    'Los tres primeros usan el panel; el cliente usa el portal.';
