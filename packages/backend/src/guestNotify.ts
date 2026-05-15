import { getPool } from "./db.js";
import { sendMailSafe, sendMailWithAttachmentsSafe } from "./mail.js";
import { sendSmsSafe } from "./sms.js";

export function isGuestUserEmail(email: string): boolean {
  return email.trim().toLowerCase().endsWith("@guest.curatering.internal");
}

export async function nextGuestCustomerId(): Promise<string> {
  const { rows } = await getPool().query(
    `SELECT COALESCE(MAX(CAST(REPLACE(customer_id, 'GUEST-', '') AS INT)), 0) AS m
     FROM restaurant_orders WHERE customer_id ~ '^GUEST-[0-9]+$'`,
  );
  const m = Number((rows[0] as { m: string }).m) || 0;
  return `GUEST-${String(m + 1).padStart(4, "0")}`;
}

export type ParsedRestaurantLine = {
  item_name: string;
  dip: string;
  dip_qty: number;
  qty: number;
  price: number;
};

const RESTAURANT_ADDON_EXTRA_PHP = 25;

export function restaurantLineSubtotal(line: ParsedRestaurantLine): number {
  const hasDip = line.dip.length > 0;
  const extra = hasDip ? Math.max(0, line.dip_qty - 1) * RESTAURANT_ADDON_EXTRA_PHP * line.qty : 0;
  return Math.round((line.qty * line.price + extra) * 100) / 100;
}

export function formatOrderLinesText(lines: ParsedRestaurantLine[], total: number): string {
  const rows = lines.map((l) => {
    const sub = restaurantLineSubtotal(l);
    const dipPart = l.dip.trim() ? ` — ${l.dip} (add-on ×${l.dip_qty})` : "";
    return `• ${l.item_name}${dipPart} ×${l.qty} @ ₱${l.price.toFixed(2)} = ₱${sub.toFixed(2)}`;
  });
  return `${rows.join("\n")}\n\nTotal: ₱${total.toFixed(2)}`;
}

export type GuestOrderReach = {
  userEmail: string | null;
  guestContactEmail: string | null;
  deliveryContact: string | null;
};

export function guestReachFromRow(row: {
  user_email?: string | null;
  guest_contact_email?: string | null;
  delivery_contact?: string | null;
}): GuestOrderReach {
  return {
    userEmail: row.user_email ?? null,
    guestContactEmail: row.guest_contact_email ?? null,
    deliveryContact: row.delivery_contact ?? null,
  };
}

/** Email + SMS for guest orders; email + in-app for registered customers. */
export async function notifyRestaurantOrderCustomer(
  reach: GuestOrderReach,
  subject: string,
  body: string,
  options?: { inAppMessage?: string; orderNo?: string },
): Promise<void> {
  const ue = String(reach.userEmail ?? "").trim().toLowerCase();
  if (isGuestUserEmail(ue)) {
    const em = String(reach.guestContactEmail ?? "").trim().toLowerCase();
    if (em) void sendMailSafe(em, subject, body);
    const phone = String(reach.deliveryContact ?? "").trim();
    if (phone) {
      const smsBody = body.length > 1400 ? `${body.slice(0, 1390)}…` : body;
      void sendSmsSafe(phone, smsBody);
    }
    return;
  }
  if (ue) {
    void sendMailSafe(ue, subject, body);
    const msg = options?.inAppMessage ?? `[${options?.orderNo ?? "Order"}] ${subject}`;
    try {
      await getPool().query(`INSERT INTO notifications (user_id, message) VALUES ($1, $2)`, [ue, msg]);
    } catch (err) {
      console.warn("[notify] in-app notification skipped:", err instanceof Error ? err.message : err);
    }
  }
}

export async function sendGuestOrderProofConfirmation(opts: {
  orderNo: string;
  guestContactEmail: string;
  deliveryContact: string;
  lines: ParsedRestaurantLine[];
  total: number;
  note: string;
  paymentProofBase64: string;
}): Promise<void> {
  const linesText = formatOrderLinesText(opts.lines, opts.total);
  const emailBody =
    `Thank you for your order with Macrina's Kitchen and Catering.\n\n` +
    `Order: ${opts.orderNo}\n` +
    (opts.note.trim() ? `Note: ${opts.note.trim()}\n\n` : "\n") +
    `Items:\n${linesText}\n\n` +
    `Your payment proof is attached to this email.\n\n` +
    `Our team will review your payment and contact you by email or text if anything else is needed.`;

  const smsBody =
    `Macrina's: We received your order ${opts.orderNo}.\n` +
    `Total: ₱${opts.total.toFixed(2)}.\n` +
    `${linesText.replace(/\n/g, " ")}\n\n` +
    `Payment proof was sent to your email — please check your inbox. ` +
    `We will email or text you about payment confirmation and delivery updates.`;

  let proofBuf: Buffer | null = null;
  const raw = opts.paymentProofBase64.trim();
  if (raw.length > 0) {
    try {
      proofBuf = Buffer.from(raw, "base64");
    } catch {
      proofBuf = null;
    }
  }

  if (proofBuf && proofBuf.length > 0) {
    void sendMailWithAttachmentsSafe(opts.guestContactEmail, `${opts.orderNo} — order received`, emailBody, [
      { filename: "payment-proof.jpg", content: proofBuf, contentType: "image/jpeg" },
    ]);
  } else {
    void sendMailSafe(opts.guestContactEmail, `${opts.orderNo} — order received`, emailBody);
  }

  if (opts.deliveryContact.trim()) {
    void sendSmsSafe(opts.deliveryContact, smsBody);
  }
}
