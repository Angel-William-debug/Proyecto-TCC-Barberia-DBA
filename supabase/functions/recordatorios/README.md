# Edge Function: recordatorios (RN-050)

**Activa desde el 14/10/2026.** Manda por correo el recordatorio de cada turno,
`minutos_antes_recordatorio` antes de la hora (configuración del sistema; hoy 1440,
un día antes). La llama `pg_cron` cada 10 minutos (migración `20261014120000`).

## Cómo envía

Por la **API transaccional de Brevo**: la misma cuenta que manda los correos de Auth
(por SMTP) y los reportes del panel (por API). Se escribió para Resend el 19/8/2026,
pero Resend sin dominio propio solo entrega a la dirección del dueño, así que nunca se
activó.

Secretos del proyecto (Supabase → Edge Functions → Secrets). **No van en git:**

| Secreto | Qué es |
|---|---|
| `BREVO_API_KEY` | API key de Brevo (`xkeysib-…`), la misma que `apps/web/.env.local` del FRONTEND |
| `CORREO_REMITENTE` | el remitente verificado en Brevo |
| `AVISOS_PUSH_SECRETO` | el secreto compartido con la base, el mismo que `avisos-push` |

## Quién la llama

Solo la base, con la cabecera `x-avisos-secreto`, que el `pg_cron` lee del Vault
(`avisos_push_secreto`). Tiene `verify_jwt = false` en `config.toml`, porque la clave
anónima es un JWT válido y con ella cualquiera podría disparar la corrida. Sin el
secreto responde 401.

## Qué hace en cada corrida

1. Lee `v_proximos_turnos`: turnos pendientes o confirmados de las próximas 24 horas,
   sin recordatorio enviado.
2. Se queda con los que ya entraron en la ventana de aviso.
3. Por cada uno:
   - Sin correo: anota `sin_email` y no reintenta.
   - Con correo: lo manda y anota `enviado`, o `fallido` con reintento hasta
     `max_reintentos_notif` (RN-042).

Devuelve un resumen: `{ revisados, dentro_del_umbral, enviados, sin_email, fallidos }`.

El correo tiene la identidad de Barber Shop (la misma franja y tarjeta que las
plantillas de Auth): saludo, día y hora destacados, servicios, y cómo cancelar si no
puede venir.

## Desplegar y probar

```powershell
npx supabase functions deploy recordatorios --project-ref tmuntxynyopzbhzmulux --no-verify-jwt
```

Para probarla a mano hay que mandar la cabecera `x-avisos-secreto` con el valor del
Vault. **Ojo: manda correos de verdad** a los clientes con turno dentro de la ventana.

Probada el 14/10/2026 con un turno de prueba a nombre de `h50896455+recordatorio@gmail.com`,
ya borrado. Se enviaron dos recordatorios por Brevo y los dos quedaron como `enviado`.
