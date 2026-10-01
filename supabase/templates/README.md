# Correos de Supabase Auth

Los correos que manda Supabase Auth (confirmar la cuenta, restablecer la contraseña,
cambiar de correo, enlace de acceso), en español y con la identidad de Barber Shop.
Están activos desde el 1/10/2026.

| Archivo | Cuándo sale |
|---|---|
| `confirmacion.html` | Al crear una cuenta de cliente (`registrarCliente()` en el FRONTEND) |
| `recuperacion.html` | «¿Olvidó su contraseña?» |
| `cambio_correo.html` | Al cambiar el correo de una cuenta |
| `enlace_acceso.html` | Ingreso con enlace (hoy no se usa) |

Los cuatro salen de **una** plantilla base en `generar.mjs`: un cambio de diseño se hace
ahí y se regeneran todos.

```bash
node supabase/templates/generar.mjs
```

## Cómo se envían

Por **Brevo** (SMTP), en el plan gratuito: 300 correos por día, sin dominio propio. El
remitente es `Barber Shop <h50896455@gmail.com>`, verificado en Brevo.

| Dato | Valor |
|---|---|
| Host | `smtp-relay.brevo.com` |
| Puerto | `587` |
| Usuario | el «Login» de Brevo (`…@smtp-brevo.com`) |
| Contraseña | una clave SMTP de Brevo (`xsmtpsib-…`). **No está en git**: se carga en el panel de Supabase |

Se configura en el panel de Supabase, en **Authentication → Emails → SMTP Settings**.

**Trampa de Brevo:** por defecto Brevo bloquea el SMTP desde direcciones IP que no
estén autorizadas, y Supabase manda desde IPs suyas que cambian. Con el bloqueo puesto,
Supabase responde «Error sending confirmation email» y la clave en Brevo figura sin
usar. Se desactiva en **Brevo → Settings → Seguridad → Direcciones IP autorizadas**.

## Cómo se cargan en el proyecto real

`config.toml` las usa solo en el Supabase local. En el proyecto real se suben con la
API de administración, con el `SUPABASE_ACCESS_TOKEN` de `.env`:

```js
// PATCH https://api.supabase.com/v1/projects/tmuntxynyopzbhzmulux/config/auth
{
  site_url: 'https://proyecto-tcc-barberia-frontend-web.vercel.app',
  uri_allow_list: 'https://proyecto-tcc-barberia-frontend-web.vercel.app/**,http://localhost:3000/**',
  rate_limit_email_sent: 100,
  mailer_subjects_confirmation: CORREOS.confirmacion.asunto,
  mailer_templates_confirmation_content: CORREOS.confirmacion.html,
  // ...igual para recovery, email_change y magic_link
}
```

`CORREOS` se importa de `generar.mjs`. Las direcciones de `uri_allow_list` son
adonde puede volver el enlace del correo: la página `/cuenta-confirmada` de la web, en
Vercel o en local.
