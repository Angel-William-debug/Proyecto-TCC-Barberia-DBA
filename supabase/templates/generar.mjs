// ============================================================================
// CORREOS DE SUPABASE AUTH, con la identidad de Barber Shop
//
// Genera los .html de esta carpeta a partir de UNA plantilla base, para que
// los cuatro correos se vean iguales y un cambio de diseno se haga una vez:
//
//   node supabase/templates/generar.mjs
//
// Los .html generados son los que usan config.toml (Supabase local) y los que
// se suben al proyecto real con la API de administracion (ver README.md).
//
// POR QUE ASI Y NO COMO LA WEB
//
// Un correo no es una pagina: Gmail, Outlook y la app de correo del telefono
// ignoran las hojas de estilo, las variables CSS y la mayoria del diseno
// moderno. Por eso: tablas para la estructura, estilos escritos en cada
// etiqueta, colores con su valor hexadecimal (los mismos tokens de
// `packages/ui/src/tokens/colores.css`) y tipografias de sistema como
// respaldo de Oswald e Inter, que casi ningun cliente de correo descarga.
//
// Fondo claro (hueso) y franja carbon arriba: un correo entero oscuro, Gmail
// en modo claro lo muestra bien, pero algunos clientes lo invierten a medias
// y queda ilegible. El ambar de laton va en el boton y en «SHOP».
//
// Variables de Supabase: {{ .ConfirmationURL }} es el enlace, {{ .Email }}
// el correo y {{ .Data.nombre }} el nombre que se guardo al registrarse.
// ============================================================================

import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const AQUI = dirname(fileURLToPath(import.meta.url));
const SITIO = 'https://proyecto-tcc-barberia-frontend-web.vercel.app';

const C = {
  carbon900: '#14110F',
  carbon700: '#2B2521',
  ambar500: '#C9922B',
  ambar50: '#FBF4E4',
  ambar700: '#855B19',
  crema50: '#F7F3EC',
  crema300: '#BCB3A5',
  hueso: '#FAF7F2',
  borde: '#E7E1D7',
  texto: '#14110F',
  textoSecundario: '#5C544B',
  textoTerciario: '#6B6257',
};

const DISPLAY = "'Oswald','Arial Narrow',Arial,sans-serif";
const SANS = "'Inter','Segoe UI',Roboto,Helvetica,Arial,sans-serif";

const SALUDO = '{{ if .Data.nombre }}Hola, {{ .Data.nombre }}{{ else }}Hola{{ end }}';

function correo({ preencabezado, etiqueta, titulo, parrafos, boton, aviso, pie }) {
  const cuerpo = parrafos
    .map(
      (p) =>
        `<p style="margin:0 0 16px;font-family:${SANS};font-size:16px;line-height:24px;color:${C.textoSecundario};">${p}</p>`,
    )
    .join('\n                ');

  return `<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light">
<meta name="supported-color-schemes" content="light">
<title>${titulo} · Barber Shop</title>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;600&family=Oswald:wght@600;700&display=swap" rel="stylesheet">
</head>
<body style="margin:0;padding:0;background-color:${C.hueso};">
  <!-- Lo que se lee en la bandeja junto al asunto, antes de abrir el correo. -->
  <div style="display:none;max-height:0;overflow:hidden;opacity:0;color:${C.hueso};">${preencabezado}</div>

  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:${C.hueso};">
    <tr>
      <td align="center" style="padding:32px 16px;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:560px;">

          <!-- Franja de marca -->
          <tr>
            <td style="background-color:${C.carbon900};border-radius:12px 12px 0 0;padding:28px 32px;" align="center">
              <img src="${SITIO}/icon.png" width="56" height="56" alt="" style="display:block;border:0;border-radius:12px;margin:0 auto 12px;">
              <div style="font-family:${DISPLAY};font-size:28px;line-height:32px;font-weight:700;letter-spacing:2px;color:${C.crema50};">
                BARBER<span style="color:${C.ambar500};">SHOP</span>
              </div>
            </td>
          </tr>
          <!-- Filete de laton bajo la franja -->
          <tr><td style="background-color:${C.ambar500};height:4px;line-height:4px;font-size:0;">&nbsp;</td></tr>

          <!-- Contenido -->
          <tr>
            <td style="background-color:#FFFFFF;border:1px solid ${C.borde};border-top:0;border-radius:0 0 12px 12px;padding:36px 32px 32px;">
              <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">
                <tr><td>
                <p style="margin:0 0 8px;font-family:${SANS};font-size:12px;line-height:16px;font-weight:600;letter-spacing:1.5px;text-transform:uppercase;color:${C.ambar700};">${etiqueta}</p>
                <h1 style="margin:0 0 20px;font-family:${DISPLAY};font-size:26px;line-height:32px;font-weight:600;color:${C.texto};">${titulo}</h1>
                ${cuerpo}
                </td></tr>

                <!-- Boton. Tabla con fondo y no solo el enlace: Outlook ignora el relleno de un <a>. -->
                <tr>
                  <td align="center" style="padding:12px 0 28px;">
                    <table role="presentation" cellpadding="0" cellspacing="0" border="0">
                      <tr>
                        <td align="center" bgcolor="${C.ambar500}" style="border-radius:8px;">
                          <a href="{{ .ConfirmationURL }}" target="_blank"
                             style="display:inline-block;padding:14px 32px;font-family:${SANS};font-size:16px;line-height:20px;font-weight:600;color:${C.carbon900};text-decoration:none;border-radius:8px;">${boton}</a>
                        </td>
                      </tr>
                    </table>
                  </td>
                </tr>

                <!-- Aviso -->
                <tr>
                  <td style="background-color:${C.ambar50};border-left:3px solid ${C.ambar500};border-radius:4px;padding:14px 16px;">
                    <p style="margin:0;font-family:${SANS};font-size:14px;line-height:20px;color:${C.textoSecundario};">${aviso}</p>
                  </td>
                </tr>

                <!-- Enlace en texto, para cuando el boton no se ve -->
                <tr>
                  <td style="padding-top:24px;">
                    <p style="margin:0 0 6px;font-family:${SANS};font-size:13px;line-height:18px;color:${C.textoTerciario};">¿El botón no funciona? Copie esta dirección en su navegador:</p>
                    <p style="margin:0;font-family:${SANS};font-size:12px;line-height:18px;word-break:break-all;"><a href="{{ .ConfirmationURL }}" style="color:${C.ambar700};">{{ .ConfirmationURL }}</a></p>
                  </td>
                </tr>
              </table>
            </td>
          </tr>

          <!-- Pie -->
          <tr>
            <td align="center" style="padding:24px 16px 0;">
              <p style="margin:0 0 6px;font-family:${SANS};font-size:12px;line-height:18px;color:${C.textoTerciario};">${pie}</p>
              <p style="margin:0;font-family:${SANS};font-size:12px;line-height:18px;color:${C.textoTerciario};">Barber Shop · Asunción, Paraguay · Este es un correo automático, no hace falta responderlo.</p>
            </td>
          </tr>

        </table>
      </td>
    </tr>
  </table>
</body>
</html>
`;
}

// Asunto de cada correo, y el texto. Se usa «usted», como en todo el sistema.
export const CORREOS = {
  confirmacion: {
    asunto: 'Confirme su correo para activar su cuenta de Barber Shop',
    html: correo({
      preencabezado: 'Un paso más: confirme su correo y ya puede reservar su turno.',
      etiqueta: 'Bienvenido',
      titulo: `${SALUDO}, ¡gracias por registrarse!`,
      parrafos: [
        'Creó una cuenta en <strong style="color:#14110F;">Barber Shop</strong> con el correo <strong style="color:#14110F;">{{ .Email }}</strong>.',
        'Para activarla, confirme que este correo es suyo. Después podrá reservar turnos, ver su historial y recibir recomendaciones, desde la web o desde la app.',
      ],
      boton: 'Confirmar mi correo',
      aviso: '⏱ El enlace vence en <strong>una hora</strong>. Si venció, intente ingresar y toque «Reenviar el correo».',
      pie: 'Si usted no creó esta cuenta, ignore este correo: sin confirmar, la cuenta no se activa.',
    }),
  },
  recuperacion: {
    asunto: 'Restablezca su contraseña de Barber Shop',
    html: correo({
      preencabezado: 'Recibimos un pedido para cambiar la contraseña de su cuenta.',
      etiqueta: 'Seguridad de la cuenta',
      titulo: `${SALUDO}`,
      parrafos: [
        'Recibimos un pedido para restablecer la contraseña de la cuenta <strong style="color:#14110F;">{{ .Email }}</strong>.',
        'Toque el botón para elegir una contraseña nueva.',
      ],
      boton: 'Elegir una contraseña nueva',
      aviso: '⏱ El enlace vence en <strong>una hora</strong> y sirve una sola vez.',
      pie: 'Si usted no lo pidió, ignore este correo: su contraseña sigue siendo la misma.',
    }),
  },
  cambio_correo: {
    asunto: 'Confirme su nuevo correo en Barber Shop',
    html: correo({
      preencabezado: 'Confirme el cambio de correo de su cuenta.',
      etiqueta: 'Seguridad de la cuenta',
      titulo: `${SALUDO}`,
      parrafos: [
        'Se pidió cambiar el correo de su cuenta de Barber Shop de <strong style="color:#14110F;">{{ .Email }}</strong> a <strong style="color:#14110F;">{{ .NewEmail }}</strong>.',
        'Toque el botón para confirmar el cambio.',
      ],
      boton: 'Confirmar el cambio',
      aviso: '⏱ El enlace vence en <strong>una hora</strong>.',
      pie: 'Si usted no pidió este cambio, ignore este correo y avise a la barbería.',
    }),
  },
  enlace_acceso: {
    asunto: 'Su enlace para ingresar a Barber Shop',
    html: correo({
      preencabezado: 'Ingrese a su cuenta con un toque.',
      etiqueta: 'Ingreso',
      titulo: `${SALUDO}`,
      parrafos: ['Toque el botón para ingresar a su cuenta de Barber Shop sin escribir la contraseña.'],
      boton: 'Ingresar',
      aviso: '⏱ El enlace vence en <strong>una hora</strong> y sirve una sola vez.',
      pie: 'Si usted no lo pidió, ignore este correo.',
    }),
  },
};

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  for (const [nombre, { html }] of Object.entries(CORREOS)) {
    writeFileSync(join(AQUI, `${nombre}.html`), html);
    console.log(`supabase/templates/${nombre}.html`);
  }
}
