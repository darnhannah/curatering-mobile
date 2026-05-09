import nodemailer from "nodemailer";

let transporter: nodemailer.Transporter | null = null;

export function isMailConfigured(): boolean {
  return !!(process.env.TRANSPORTER_EMAIL?.trim() && process.env.TRANSPORTER_PASSWORD?.trim());
}

function getTransport() {
  const host = process.env.TRANSPORTER_SMTP_HOST?.trim() || "smtp.gmail.com";
  const port = Number(process.env.TRANSPORTER_SMTP_PORT) || 465;
  const user = process.env.TRANSPORTER_EMAIL?.trim();
  const pass = process.env.TRANSPORTER_PASSWORD?.trim();
  if (!user || !pass) {
    return null;
  }
  if (!transporter) {
    transporter = nodemailer.createTransport({
      host,
      port,
      secure: port === 465,
      auth: { user, pass },
    });
  }
  return transporter;
}

/** Sends email; skips quietly if SMTP is not configured (non-critical notifications). */
export async function sendMailSafe(to: string, subject: string, text: string): Promise<void> {
  const from = process.env.TRANSPORTER_EMAIL?.trim();
  const t = getTransport();
  if (!t || !from) {
    console.warn("Email not configured (TRANSPORTER_EMAIL / TRANSPORTER_PASSWORD); skipping send.");
    return;
  }
  await t.sendMail({ from, to, subject, text });
}

/** Throws if SMTP is missing or delivery fails — use for OTP and must-deliver flows. */
export async function sendMailRequired(to: string, subject: string, text: string): Promise<void> {
  const from = process.env.TRANSPORTER_EMAIL?.trim();
  const t = getTransport();
  if (!t || !from) {
    throw new Error("SMTP not configured: set TRANSPORTER_EMAIL and TRANSPORTER_PASSWORD");
  }
  await t.sendMail({ from, to, subject, text });
}

/** PDF attachment (Buffer) — same SMTP config as [sendMailSafe]. */
export async function sendMailWithPdfAttachment(
  to: string,
  subject: string,
  text: string,
  pdfFilename: string,
  pdfBuffer: Buffer,
): Promise<void> {
  const from = process.env.TRANSPORTER_EMAIL?.trim();
  const t = getTransport();
  if (!t || !from) {
    console.warn("Email not configured (TRANSPORTER_EMAIL / TRANSPORTER_PASSWORD); skipping send.");
    return;
  }
  await t.sendMail({
    from,
    to,
    subject,
    text,
    attachments: [{ filename: pdfFilename, content: pdfBuffer }],
  });
}
