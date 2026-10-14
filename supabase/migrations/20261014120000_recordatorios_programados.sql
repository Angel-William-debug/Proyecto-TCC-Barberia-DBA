-- ============================================================================
-- RECORDATORIOS POR CORREO, PROGRAMADOS (RN-050)
--
-- La Edge Function `recordatorios` estaba escrita desde el 19/8/2026 pero nunca
-- se activo: mandaba por Resend, que sin dominio propio solo entrega a la
-- direccion del dueño. Desde el 14/10/2026 manda por la API de Brevo (ver
-- functions/recordatorios/index.ts) y esta desplegada.
--
-- Esta migracion la pone a correr sola: `pg_cron` la llama cada 10 minutos por
-- `pg_net`. Cada corrida manda los recordatorios de los turnos que ya entraron
-- en la ventana de `configuracion_sistema.minutos_antes_recordatorio` (hoy 24
-- horas) y no se mandaron todavia; un turno ya avisado no se vuelve a avisar.
--
-- EL SECRETO. La funcion no exige la sesion de Supabase (verify_jwt = false) y
-- se protege con la cabecera `x-avisos-secreto`, el mismo secreto que usa
-- `avisos-push`, leido del Vault en cada corrida. Si el secreto no esta, la
-- funcion responde 401 y no manda nada: no se rompe nada.
-- ============================================================================

create extension if not exists pg_cron;

-- Si la tarea ya existia (otra corrida de esta migracion), se reemplaza.
select cron.unschedule(jobid) from cron.job where jobname = 'recordatorios-turnos';

select cron.schedule(
    'recordatorios-turnos',
    '*/10 * * * *',
    $tarea$
    select net.http_post(
        url     := 'https://tmuntxynyopzbhzmulux.supabase.co/functions/v1/recordatorios',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'x-avisos-secreto', (select decrypted_secret from vault.decrypted_secrets
                                  where name = 'avisos_push_secreto')
        ),
        body    := '{}'::jsonb
    );
    $tarea$
);
