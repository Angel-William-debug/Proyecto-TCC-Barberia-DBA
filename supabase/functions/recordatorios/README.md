# Edge Function: recordatorios (RN-050)

Código listo, **sin desplegar todavía** — decisión del equipo el 18/8/2026: activarla
requiere una API key real de Resend que no estaba disponible en esta sesión.

## Qué hace

Manda el recordatorio de un turno por correo, `minutos_antes_recordatorio` antes de
la hora de la cita. Ver el comentario al inicio de `index.ts` para el detalle del
flujo (RN-050, RN-042).

## Para activarla

1. **Conseguir una API key de Resend** — [resend.com](https://resend.com), plan
   gratuito alcanza para probar. Verificar un dominio propio antes de mandar a
   destinatarios reales, o usar `onboarding@resend.dev` solo para pruebas.

2. **Configurar los secretos del proyecto** (no van en ningún `.env` versionado):

   ```powershell
   supabase secrets set RESEND_API_KEY=re_xxxxxxxx --project-ref tmuntxynyopzbhzmulux
   supabase secrets set RESEND_FROM_EMAIL="Barber Shop <notificaciones@tudominio.com>" --project-ref tmuntxynyopzbhzmulux
   ```

   `SUPABASE_URL` y `SUPABASE_SERVICE_ROLE_KEY` los inyecta Supabase solo en toda
   Edge Function: no hace falta configurarlos.

3. **Desplegar**:

   ```powershell
   supabase functions deploy recordatorios --project-ref tmuntxynyopzbhzmulux
   ```

4. **Probarla a mano** antes de programarla, para ver el resultado sin esperar:

   ```powershell
   curl -X POST "https://tmuntxynyopzbhzmulux.supabase.co/functions/v1/recordatorios" `
     -H "Authorization: Bearer $env:SUPABASE_SERVICE_ROLE_KEY"
   ```

   Devuelve un resumen: `{ revisados, dentro_del_umbral, enviados, sin_email, fallidos }`.

5. **Programarla** cada 5-10 minutos. La forma más simple es el panel de Supabase
   (*Edge Functions → recordatorios → Cron*), sin escribir SQL. La alternativa por
   SQL, con `pg_cron` y `pg_net` (las dos extensiones deben estar habilitadas
   primero, *Database → Extensions*):

   ```sql
   -- NO APLICAR sin haber hecho los pasos 1-3 primero: sin la funcion
   -- desplegada y el secreto configurado, esto llamaria a una URL que
   -- todavia no hace nada util.
   select cron.schedule(
     'recordatorios-turnos',
     '*/10 * * * *',
     $$
     select net.http_post(
       url := 'https://tmuntxynyopzbhzmulux.supabase.co/functions/v1/recordatorios',
       headers := jsonb_build_object(
         'Authorization', 'Bearer ' || current_setting('app.settings.service_role_key', true)
       )
     );
     $$
   );
   ```

   Esto **no se agregó como migración a propósito**: aplicarla sin la función
   desplegada dejaría un cron llamando a una URL inexistente cada 10 minutos, sin
   ningún beneficio. Cuando decidan activarla, conviene agregarla como una
   migración nueva (nunca editar una ya pusheada), con la clave de servicio
   guardada como secreto de base de datos, no en texto plano dentro del SQL.

## Verificación

Sin datos reales cargados en la base todavía (ver CLAUDE.md, sección 0), no hay
turnos próximos contra los que probar el flujo completo end-to-end. Una vez que
haya citas reales en las próximas 24 horas, la llamada manual del paso 4 es la
forma más rápida de confirmar que el correo llega.
