import nodemailer from "nodemailer";

let transporter: nodemailer.Transporter | null = null;
let transporterKey = "";

/** SMTP login user (Gmail = full email address). */
function smtpUser(): string {
  return (
    process.env.TRANSPORTER_EMAIL?.trim() ||
    process.env.SMTP_USER?.trim() ||
    process.env.SMTP_LOGIN?.trim() ||
    process.env.GMAIL_USER?.trim() ||
    process.env.EMAIL_USER?.trim() ||
    ""
  );
}

/** SMTP password (Gmail = app password). */
function smtpPass(): string {
  return (
    process.env.TRANSPORTER_PASSWORD?.trim() ||
    process.env.SMTP_PASS?.trim() ||
    process.env.SMTP_PASSWORD?.trim() ||
    process.env.GMAIL_APP_PASSWORD?.trim() ||
    process.env.EMAIL_PASSWORD?.trim() ||
    ""
  );
}

/** From header; defaults to the SMTP user when unset. */
function smtpFrom(): string {
  return (
    process.env.TRANSPORTER_FROM?.trim() ||
    process.env.SMTP_FROM?.trim() ||
    process.env.MAIL_FROM?.trim() ||
    smtpUser()
  );
}

export function isMailConfigured(): boolean {
  return !!(smtpUser() && smtpPass());
}

function getTransport() {
  const host = process.env.TRANSPORTER_SMTP_HOST?.trim() || process.env.SMTP_HOST?.trim() || "smtp.gmail.com";
  const port = Number(process.env.TRANSPORTER_SMTP_PORT ?? process.env.SMTP_PORT) || 465;
  const user = smtpUser();
  const pass = smtpPass();
  if (!user || !pass) {
    return null;
  }
  const key = `${host}|${port}|${user}|${pass}`;
  if (!transporter || transporterKey !== key) {
    transporter = nodemailer.createTransport({
      host,
      port,
      secure: port === 465,
      auth: { user, pass },
    });
    transporterKey = key;
  }
  return transporter;
}

/** Sends email; skips quietly if SMTP is not configured (non-critical notifications). */
export async function sendMailSafe(to: string, subject: string, text: string): Promise<void> {
  const from = smtpFrom();
  const t = getTransport();
  if (!t || !from) {
    console.warn(
      "Email not configured; set TRANSPORTER_EMAIL + TRANSPORTER_PASSWORD (or SMTP_USER + SMTP_PASS / GMAIL_USER + GMAIL_APP_PASSWORD); skipping send.",
    );
    return;
  }
  await t.sendMail({ from, to, subject, text });
}

/** Throws if SMTP is missing or delivery fails — use for OTP and must-deliver flows. */
export async function sendMailRequired(to: string, subject: string, text: string): Promise<void> {
  const from = smtpFrom();
  const t = getTransport();
  if (!t || !from) {
    throw new Error(
      "SMTP not configured: set TRANSPORTER_EMAIL and TRANSPORTER_PASSWORD (or SMTP_USER + SMTP_PASS, or GMAIL_USER + GMAIL_APP_PASSWORD)",
    );
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
  const from = smtpFrom();
  const t = getTransport();
  if (!t || !from) {
    console.warn(
      "Email not configured; set TRANSPORTER_EMAIL + TRANSPORTER_PASSWORD (or SMTP_USER + SMTP_PASS); skipping send.",
    );
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

/** PDF attachment — throws if SMTP is missing or send fails (order-summary emails). */
export async function sendMailWithPdfRequired(
  to: string,
  subject: string,
  text: string,
  pdfFilename: string,
  pdfBuffer: Buffer,
): Promise<void> {
  const from = smtpFrom();
  const t = getTransport();
  if (!t || !from) {
    throw new Error(
      "SMTP not configured: set TRANSPORTER_EMAIL and TRANSPORTER_PASSWORD (or SMTP_USER + SMTP_PASS, or GMAIL_USER + GMAIL_APP_PASSWORD)",
    );
  }
  await t.sendMail({
    from,
    to,
    subject,
    text,
    attachments: [{ filename: pdfFilename, content: pdfBuffer }],
  });
}
