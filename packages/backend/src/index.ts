import "dotenv/config";
import crypto from "node:crypto";
import bcrypt from "bcrypt";
import cors from "cors";
import express from "express";
import { isMailConfigured, sendMailRequired, sendMailSafe } from "./mail.js";
import { getPool, initDb } from "./db.js";
import { resolveMenuSql, resolveSetMenusSql } from "./webMenu.js";

const app = express();
const port = Number(process.env.PORT) || 8080;
const otpExpiryMinutes = Number(process.env.MOBILE_OTP_EXPIRY_MINUTES) || 15;

app.use(cors());
app.use(express.json({ limit: "15mb" }));

function parseJsonTextArray(raw: unknown): string[] {
  if (raw == null) return [];
  const s = String(raw).trim();
  if (!s) return [];
  try {
    const v = JSON.parse(s);
    return Array.isArray(v) ? v.map((x) => String(x)) : [];
  } catch {
    return [];
  }
}

app.get("/health", (_req, res) => {
  res.json({ ok: true });
});

app.get("/api/items", async (_req, res) => {
  try {
    const { rows } = await getPool().query(
      "SELECT id, title, created_at FROM items ORDER BY id DESC",
    );
    res.json(rows);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.post("/api/items", async (req, res) => {
  const title = typeof req.body?.title === "string" ? req.body.title.trim() : "";
  if (!title) {
    res.status(400).json({ error: "title is required" });
    return;
  }
  try {
    const { rows } = await getPool().query(
      "INSERT INTO items (title) VALUES ($1) RETURNING id, title, created_at",
      [title],
    );
    res.status(201).json(rows[0]);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.get("/api/mobile/menu", async (_req, res) => {
  const sql = resolveMenuSql();
  if (!sql) {
    res.status(503).json({
      error:
        "Menu query disabled or not configured. Remove DISABLE_DEFAULT_PUBLIC_MENU or set WEB_MENU_SQL / WEB_MENU_TABLE — see .env.example.",
    });
    return;
  }
  try {
    const { rows } = await getPool().query(sql);
    res.json(
      rows.map((r) => ({
        id: String((r as Record<string, unknown>).id ?? ""),
        name: String((r as Record<string, unknown>).name ?? ""),
        description: String((r as Record<string, unknown>).description ?? ""),
        price: Number((r as Record<string, unknown>).price ?? 0),
        dips: parseJsonTextArray((r as Record<string, unknown>).dips),
        category: String((r as Record<string, unknown>).category ?? ""),
        image_base64: (r as Record<string, unknown>).image_base64 != null
          ? String((r as Record<string, unknown>).image_base64)
          : null,
      })),
    );
  } catch (err) {
    console.error(err);
    res.status(500).json({
      error: "menu query failed — check WEB_MENU_SQL / WEB_MENU_* env matches your existing tables",
    });
  }
});

app.get("/api/mobile/set-menus", async (_req, res) => {
  const sql = resolveSetMenusSql();
  if (!sql) {
    res.json([]);
    return;
  }
  try {
    const { rows } = await getPool().query(sql);
    res.json(
      rows.map((r) => ({
        name: String((r as Record<string, unknown>).name ?? ""),
        description: String((r as Record<string, unknown>).description ?? ""),
        dishes: parseJsonTextArray((r as Record<string, unknown>).dishes),
      })),
    );
  } catch (err) {
    console.error(err);
    res.status(500).json({
      error: "set menu query failed — check WEB_SET_MENUS_SQL / WEB_SET_MENU_* env",
    });
  }
});

app.post("/api/mobile/auth/signup/request-otp", async (req, res) => {
  const email = String(req.body?.email ?? "").trim().toLowerCase();
  if (!email || !email.includes("@")) {
    res.status(400).json({ error: "valid email is required" });
    return;
  }
  if (!isMailConfigured()) {
    res.status(503).json({ error: "SMTP not configured — set TRANSPORTER_EMAIL and TRANSPORTER_PASSWORD" });
    return;
  }
  const code = String(crypto.randomInt(100000, 1000000));
  const expiresAt = new Date(Date.now() + otpExpiryMinutes * 60 * 1000);
  try {
    const existing = await getPool().query("SELECT id FROM mobile_users WHERE email = $1", [email]);
    if (existing.rows[0]) {
      res.status(409).json({ error: "account already exists — log in instead" });
      return;
    }
    await getPool().query(
      `INSERT INTO mobile_otp_codes (email, code, expires_at)
       VALUES ($1, $2, $3)
       ON CONFLICT (email) DO UPDATE SET code = EXCLUDED.code, expires_at = EXCLUDED.expires_at, created_at = NOW()`,
      [email, code, expiresAt.toISOString()],
    );
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
    return;
  }
  try {
    await sendMailRequired(
      email,
      "Your Curatering signup code",
      `Your one-time code is: ${code}\n\nIt expires in ${otpExpiryMinutes} minutes.`,
    );
  } catch (err) {
    console.error(err);
    res.status(503).json({
      error: err instanceof Error ? err.message : "failed to send OTP email",
    });
    return;
  }
  res.json({ ok: true });
});

app.post("/api/mobile/auth/signup/complete", async (req, res) => {
  const email = String(req.body?.email ?? "").trim().toLowerCase();
  const otp = String(req.body?.otp ?? "").trim();
  const password = String(req.body?.password ?? "");
  if (!email || !otp || password.length < 8) {
    res.status(400).json({ error: "email, otp, and password (min 8 chars) are required" });
    return;
  }
  try {
    const { rows } = await getPool().query(
      "SELECT code, expires_at FROM mobile_otp_codes WHERE email = $1",
      [email],
    );
    const row = rows[0] as { code: string; expires_at: Date } | undefined;
    if (!row || row.code !== otp || new Date(row.expires_at) < new Date()) {
      res.status(400).json({ error: "invalid or expired code" });
      return;
    }
    const hash = await bcrypt.hash(password, 10);
    try {
      await getPool().query("INSERT INTO mobile_users (email, password_hash) VALUES ($1, $2)", [email, hash]);
    } catch (e: unknown) {
      const err = e as { code?: string };
      if (err.code === "23505") {
        res.status(409).json({ error: "account already exists" });
        return;
      }
      throw e;
    }
    await getPool().query("DELETE FROM mobile_otp_codes WHERE email = $1", [email]);
    const ts = new Date().toISOString();
    await sendMailSafe(email, "Welcome to Curatering", `Your account ${email} was created at ${ts}.`);
    res.json({ ok: true });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.post("/api/mobile/auth/login", async (req, res) => {
  const email = String(req.body?.email ?? "").trim().toLowerCase();
  const password = String(req.body?.password ?? "");
  if (!email || !password) {
    res.status(400).json({ error: "email and password are required" });
    return;
  }
  try {
    const { rows } = await getPool().query(
      "SELECT password_hash, role, display_name FROM mobile_users WHERE email = $1",
      [email],
    );
    const row = rows[0] as { password_hash: string; role: string; display_name: string } | undefined;
    const hash = row?.password_hash ?? "";
    if (!hash || !(await bcrypt.compare(password, hash))) {
      res.status(401).json({ error: "invalid email or password" });
      return;
    }
    const ts = new Date().toISOString();
    await sendMailSafe(
      email,
      "Macrina's Kitchen login notice",
      `A login was completed for ${email} at ${ts}. If this was not you, change your password.`,
    );
    const role = String(row?.role ?? "customer").trim() || "customer";
    const displayName = String(row?.display_name ?? "").trim();
    res.json({ ok: true, email, role, display_name: displayName });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

async function verifyCashier(email: string, password: string): Promise<boolean> {
  const e = email.trim().toLowerCase();
  const { rows } = await getPool().query(`SELECT password_hash, role FROM mobile_users WHERE email = $1`, [e]);
  const row = rows[0] as { password_hash: string; role: string } | undefined;
  if (!row || String(row.role).trim() !== "cashier") return false;
  return bcrypt.compare(password, row.password_hash);
}

/** All mobile-app customer orders for cashier review (not walk-in POS). */
app.post("/api/mobile/pos/online-orders/list", async (req, res) => {
  const cashierEmail = String(req.body?.cashier_email ?? "").trim().toLowerCase();
  const cashierPassword = String(req.body?.cashier_password ?? "");
  if (!cashierEmail || !cashierPassword) {
    res.status(400).json({ error: "cashier_email and cashier_password are required" });
    return;
  }
  if (!(await verifyCashier(cashierEmail, cashierPassword))) {
    res.status(403).json({ error: "invalid cashier credentials" });
    return;
  }
  try {
    const { rows } = await getPool().query(
      `SELECT id, user_email, order_no, status, note, payment_mode, payment_uploaded, payment_proof,
              delivery_name, delivery_contact, delivery_address, delivery_time, total, created_at,
              order_source, pos_customer_label, cashier_amount_received, cashier_change,
              fulfillment_stage, delivery_tracking_url, order_lines_snapshot,
              supplemental_payment_proof, cashier_secondary_amount_received, balance_proof_pending_review
       FROM mobile_orders
       WHERE order_source = 'MOBILE_APP' AND user_email IS NOT NULL
       ORDER BY created_at DESC`,
    );
    const out = await attachOrderItems(rows as Array<Record<string, unknown>>);
    res.json(out);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.patch("/api/mobile/pos/online-orders/:id/review", async (req, res) => {
  const id = Number(req.params.id);
  const cashierEmail = String(req.body?.cashier_email ?? "").trim().toLowerCase();
  const cashierPassword = String(req.body?.cashier_password ?? "");
  const action = String(req.body?.action ?? "").trim().toLowerCase();
  const amountReceived = Number(req.body?.amount_received ?? NaN);
  const supplementalAmtIn = Number(req.body?.supplemental_amount_received ?? NaN);
  if (!id || !cashierEmail || !cashierPassword || !action) {
    res.status(400).json({ error: "id, cashier credentials, and action are required" });
    return;
  }
  if (!(await verifyCashier(cashierEmail, cashierPassword))) {
    res.status(403).json({ error: "invalid cashier credentials" });
    return;
  }
  if (!["confirm", "insufficient", "overpayment"].includes(action)) {
    res.status(400).json({ error: "action must be confirm, insufficient, or overpayment" });
    return;
  }
  try {
    const { rows: orows } = await getPool().query(
      `SELECT id, user_email, order_no, status, total, order_source,
              cashier_amount_received, supplemental_payment_proof, balance_proof_pending_review
       FROM mobile_orders WHERE id = $1`,
      [id],
    );
    type OrdRow = {
      id: number;
      user_email: string | null;
      order_no: string;
      status: string;
      total: string;
      order_source: string;
      cashier_amount_received: string | null;
      supplemental_payment_proof: string | null;
      balance_proof_pending_review: boolean;
    };
    const ord = orows[0] as OrdRow | undefined;
    if (!ord || ord.order_source !== "MOBILE_APP" || !ord.user_email) {
      res.status(404).json({ error: "online order not found" });
      return;
    }
    const total = Number(ord.total);
    let newStatus = ord.status;
    let mailSubject = "";
    let mailBody = "";
    let cashReceived: number | null = null;
    let changeAmt: number | null = null;

    if (action === "confirm") {
      const proof2 =
        ord.supplemental_payment_proof != null && String(ord.supplemental_payment_proof).trim().length > 0;
      const pendingReview = ord.balance_proof_pending_review === true;
      const statusUp = String(ord.status).toUpperCase();

      if (pendingReview && proof2) {
        if (!Number.isFinite(supplementalAmtIn) || supplementalAmtIn < 0) {
          res.status(400).json({ error: "supplemental_amount_received is required (balance payment amount)" });
          return;
        }
        const first = Number(ord.cashier_amount_received) || 0;
        const combined = first + supplementalAmtIn;
        if (combined + 1e-9 < total) {
          res.status(400).json({
            error: `Recorded payments are still below the order total (need at least ₱${(total - first).toFixed(2)} more).`,
          });
          return;
        }
        newStatus = "ORDER CONFIRMED";
        mailSubject = `Order ${ord.order_no} confirmed`;
        mailBody = `Good news — your order ${ord.order_no} has been confirmed.\nTotal: ₱${total.toFixed(2)}\nThank you for choosing Macrina's Kitchen and Catering.`;
        changeAmt = Math.round((combined - total) * 100) / 100;

        await getPool().query(
          `UPDATE mobile_orders
           SET status = $2,
               cashier_secondary_amount_received = $3,
               cashier_change = $4,
               balance_proof_pending_review = FALSE,
               fulfillment_stage = 'IN_PREPARATION',
               updated_at = NOW()
           WHERE id = $1`,
          [id, newStatus, supplementalAmtIn, changeAmt],
        );

        void sendMailSafe(String(ord.user_email), mailSubject, mailBody);
        res.json({ ok: true, status: newStatus });
        return;
      }

      if (statusUp.includes("INSUFFICIENT") && !proof2) {
        res.status(400).json({
          error: "Customer must upload balance payment proof before you can confirm.",
        });
        return;
      }

      newStatus = "ORDER CONFIRMED";
      mailSubject = `Order ${ord.order_no} confirmed`;
      mailBody = `Good news — your order ${ord.order_no} has been confirmed.\nTotal: ₱${total.toFixed(2)}\nThank you for choosing Macrina's Kitchen and Catering.`;
      if (!Number.isNaN(amountReceived) && amountReceived >= 0) {
        cashReceived = amountReceived;
        changeAmt = Math.round((amountReceived - total) * 100) / 100;
      }
    } else if (action === "insufficient") {
      newStatus = "PAYMENT INSUFFICIENT — PAY REMAINDER OR CANCEL ORDER";
      mailSubject = `Action needed: payment for ${ord.order_no}`;
      mailBody =
        `Our team reviewed your payment for order ${ord.order_no}.\n\n` +
        `The amount received was not enough to cover your order total of ₱${total.toFixed(2)}.\n\n` +
        `Please pay the remaining balance through the payment channel we use for your order, or cancel the order from the app if you prefer not to proceed.\n\n` +
        `Upload your additional payment proof in the app under your order.`;
      if (!Number.isNaN(amountReceived) && amountReceived >= 0) {
        cashReceived = amountReceived;
        changeAmt = Math.round((amountReceived - total) * 100) / 100;
      }
    } else {
      newStatus = "ORDER CONFIRMED — OVERPAYMENT (EXCESS REFUND ON DELIVERY)";
      mailSubject = `Order ${ord.order_no} confirmed — overpayment notice`;
      mailBody =
        `Your order ${ord.order_no} has been confirmed.\n\n` +
        `We detected an overpayment relative to your order total of ₱${total.toFixed(2)}. ` +
        `The excess amount will be returned to you when your order is delivered (or per our coordinator's instructions).\n\n` +
        `Thank you for choosing Macrina's Kitchen and Catering.`;
      if (!Number.isNaN(amountReceived) && amountReceived >= 0) {
        cashReceived = amountReceived;
        changeAmt = Math.round((amountReceived - total) * 100) / 100;
      }
    }

    const nextStage =
      action === "insufficient" ? "PENDING_CASHIER" : "IN_PREPARATION";
    await getPool().query(
      `UPDATE mobile_orders
       SET status = $2,
           cashier_amount_received = COALESCE($3, cashier_amount_received),
           cashier_change = COALESCE($4, cashier_change),
           fulfillment_stage = $5,
           updated_at = NOW()
       WHERE id = $1`,
      [id, newStatus, cashReceived, changeAmt, nextStage],
    );

    void sendMailSafe(String(ord.user_email), mailSubject, mailBody);
    res.json({ ok: true, status: newStatus });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.patch("/api/mobile/pos/online-orders/:id/fulfillment", async (req, res) => {
  const id = Number(req.params.id);
  const cashierEmail = String(req.body?.cashier_email ?? "").trim().toLowerCase();
  const cashierPassword = String(req.body?.cashier_password ?? "");
  const stage = String(req.body?.fulfillment_stage ?? "").trim().toUpperCase();
  const tracking = String(req.body?.delivery_tracking_url ?? "").trim();
  if (!id || !cashierEmail || !cashierPassword || !stage) {
    res.status(400).json({ error: "id, cashier credentials, and fulfillment_stage are required" });
    return;
  }
  if (!(await verifyCashier(cashierEmail, cashierPassword))) {
    res.status(403).json({ error: "invalid cashier credentials" });
    return;
  }
  const allowed = ["PENDING_CASHIER", "IN_PREPARATION", "OUT_FOR_DELIVERY", "DELIVERED"];
  if (!allowed.includes(stage)) {
    res.status(400).json({ error: "invalid fulfillment_stage" });
    return;
  }
  try {
    const { rows } = await getPool().query(
      `UPDATE mobile_orders
       SET fulfillment_stage = $2,
           delivery_tracking_url = $3,
           updated_at = NOW()
       WHERE id = $1 AND order_source = 'MOBILE_APP' AND user_email IS NOT NULL
       RETURNING id`,
      [id, stage, tracking],
    );
    if (!rows[0]) {
      res.status(404).json({ error: "online order not found" });
      return;
    }
    res.json({ ok: true });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

/** Walk-in sale from cashier POS (no customer app account). */
app.post("/api/mobile/pos/walkin-order", async (req, res) => {
  const cashierEmail = String(req.body?.cashier_email ?? "").trim().toLowerCase();
  const cashierPassword = String(req.body?.cashier_password ?? "");
  const paymentMethod = String(req.body?.payment_method ?? "").trim().toUpperCase();
  const note = String(req.body?.note ?? "");
  const customerLabel = String(req.body?.pos_customer_label ?? "").trim();
  const amountReceivedRaw = req.body?.amount_received;
  const paymentProof = String(req.body?.payment_proof ?? "").trim();
  const items: unknown[] = Array.isArray(req.body?.items) ? (req.body.items as unknown[]) : [];
  if (!cashierEmail || !cashierPassword) {
    res.status(400).json({ error: "cashier_email and cashier_password are required" });
    return;
  }
  if (!(await verifyCashier(cashierEmail, cashierPassword))) {
    res.status(403).json({ error: "invalid cashier credentials" });
    return;
  }
  if (paymentMethod !== "CASH" && paymentMethod !== "GCASH") {
    res.status(400).json({ error: "payment_method must be CASH or GCASH" });
    return;
  }
  const parsedItems = items
    .map((i) => ({
      item_name: String((i as Record<string, unknown>)?.item_name ?? ""),
      dip: String((i as Record<string, unknown>)?.dip ?? ""),
      qty: Number((i as Record<string, unknown>)?.qty ?? 0),
      price: Number((i as Record<string, unknown>)?.price ?? 0),
    }))
    .filter((i) => i.item_name && i.qty > 0 && i.price >= 0);
  if (parsedItems.length === 0) {
    res.status(400).json({ error: "valid items are required" });
    return;
  }
  const total = parsedItems.reduce((sum, i) => sum + i.qty * i.price, 0);
  const amountReceived = Number(amountReceivedRaw);
  const changeDue =
    !Number.isNaN(amountReceived) && amountReceived >= 0 ? Math.round((amountReceived - total) * 100) / 100 : null;

  if (paymentMethod === "GCASH" && !paymentProof) {
    res.status(400).json({ error: "payment_proof is required for GCASH" });
    return;
  }

  const proofUploaded = paymentMethod === "GCASH";
  const proofVal = proofUploaded ? paymentProof : null;

  const client = await getPool().connect();
  try {
    await client.query("BEGIN");
    const { rows } = await client.query(
      `INSERT INTO mobile_orders
        (user_email, order_no, note, payment_mode, payment_uploaded, payment_proof, delivery_name, delivery_contact, delivery_address, delivery_time, total,
         order_source, pos_customer_label, cashier_amount_received, cashier_change, status, fulfillment_stage)
       VALUES
        (NULL, 'TEMP', $1, $2, $3, $4, '', '', '', 'NOW', $5,
         'POS', $6, $7, $8, 'ORDER CONFIRMED', 'IN_PREPARATION')
       RETURNING id`,
      [
        note,
        paymentMethod,
        proofUploaded,
        proofVal,
        total,
        customerLabel,
        !Number.isNaN(amountReceived) ? amountReceived : null,
        changeDue,
      ],
    );
    const orderId = Number(rows[0].id);
    const orderNo = `Order No. ${String(orderId).padStart(6, "0")}`;
    await client.query("UPDATE mobile_orders SET order_no = $1 WHERE id = $2", [orderNo, orderId]);
    for (const item of parsedItems) {
      await client.query(
        `INSERT INTO mobile_order_items (order_id, item_name, dip, qty, price)
         VALUES ($1, $2, $3, $4, $5)`,
        [orderId, item.item_name, item.dip, item.qty, item.price],
      );
    }
    await client.query(`UPDATE mobile_orders SET order_lines_snapshot = $2::jsonb WHERE id = $1`, [
      orderId,
      JSON.stringify(parsedItems),
    ]);
    await client.query("COMMIT");
    res.status(201).json({ id: orderId, order_no: orderNo, total, change: changeDue });
  } catch (err) {
    await client.query("ROLLBACK");
    console.error(err);
    res.status(500).json({ error: "database error" });
  } finally {
    client.release();
  }
});

function numOrNull(v: unknown): number | null {
  if (v === undefined || v === null || v === "") return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

async function attachOrderItems(rows: Array<Record<string, unknown>>): Promise<Array<Record<string, unknown>>> {
  const orderIds = rows.map((r) => Number(r.id));
  let itemRows: Array<{ order_id: number; item_name: string; dip: string; qty: number; price: string }> = [];
  if (orderIds.length > 0) {
    const { rows: ir } = await getPool().query(
      `SELECT order_id, item_name, dip, qty, price
       FROM mobile_order_items WHERE order_id = ANY($1::bigint[])`,
      [orderIds],
    );
    itemRows = ir as typeof itemRows;
  }
  const byOrder = new Map<number, typeof itemRows>();
  for (const item of itemRows) {
    const arr = byOrder.get(item.order_id) ?? [];
    arr.push(item);
    byOrder.set(item.order_id, arr);
  }
  type LineOut = { item_name: string; dip: string; qty: number; price: number };
  return rows.map((row) => {
    const idNum = Number(row.id);
    const rawList = byOrder.get(idNum) ?? [];
    let items: LineOut[] = rawList.map((it) => ({
      item_name: it.item_name,
      dip: it.dip,
      qty: Number(it.qty),
      price: Number(it.price),
    }));
    if (items.length === 0 && row.order_lines_snapshot != null) {
      const snap = row.order_lines_snapshot as unknown;
      const arr = Array.isArray(snap) ? snap : [];
      items = arr.map((it: Record<string, unknown>) => ({
        item_name: String(it.item_name ?? ""),
        dip: String(it.dip ?? ""),
        qty: Number(it.qty ?? 0),
        price: Number(it.price ?? 0),
      }));
    }
    return {
      ...row,
      items,
      total: Number(row.total),
    };
  });
}

/** Recent POS / online orders for cashier history screen — completed only (delivered online or claimed walk-in). */
app.post("/api/mobile/pos/order-history", async (req, res) => {
  const cashierEmail = String(req.body?.cashier_email ?? "").trim().toLowerCase();
  const cashierPassword = String(req.body?.cashier_password ?? "");
  if (!cashierEmail || !cashierPassword) {
    res.status(400).json({ error: "cashier_email and cashier_password are required" });
    return;
  }
  if (!(await verifyCashier(cashierEmail, cashierPassword))) {
    res.status(403).json({ error: "invalid cashier credentials" });
    return;
  }
  try {
    const { rows } = await getPool().query(
      `SELECT id, user_email, order_no, status, note, payment_mode, payment_uploaded, payment_proof,
              delivery_name, delivery_contact, delivery_address, delivery_time, total, created_at,
              order_source, pos_customer_label, cashier_amount_received, cashier_change,
              fulfillment_stage, delivery_tracking_url, order_lines_snapshot, pos_claimed,
              supplemental_payment_proof, cashier_secondary_amount_received, balance_proof_pending_review
       FROM mobile_orders
       WHERE (
         (order_source = 'MOBILE_APP' AND fulfillment_stage = 'DELIVERED')
         OR (order_source = 'POS' AND pos_claimed = TRUE)
       )
       ORDER BY created_at DESC
       LIMIT 250`,
    );
    const out = await attachOrderItems(rows as Array<Record<string, unknown>>);
    res.json(out);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

/** Walk-in POS queue: preparing (not claimed) vs claimed (picked up — still shown here until staff clears view). */
app.post("/api/mobile/pos/walkin-queue", async (req, res) => {
  const cashierEmail = String(req.body?.cashier_email ?? "").trim().toLowerCase();
  const cashierPassword = String(req.body?.cashier_password ?? "");
  const filter = String(req.body?.filter ?? "preparing").toLowerCase();
  if (!cashierEmail || !cashierPassword) {
    res.status(400).json({ error: "cashier_email and cashier_password are required" });
    return;
  }
  if (!(await verifyCashier(cashierEmail, cashierPassword))) {
    res.status(403).json({ error: "invalid cashier credentials" });
    return;
  }
  if (!["preparing", "claimed"].includes(filter)) {
    res.status(400).json({ error: "filter must be preparing or claimed" });
    return;
  }
  try {
    const claimed = filter === "claimed";
    const { rows } = await getPool().query(
      `SELECT id, user_email, order_no, status, note, payment_mode, payment_uploaded, payment_proof,
              delivery_name, delivery_contact, delivery_address, delivery_time, total, created_at,
              order_source, pos_customer_label, cashier_amount_received, cashier_change,
              fulfillment_stage, delivery_tracking_url, order_lines_snapshot, pos_claimed,
              supplemental_payment_proof, cashier_secondary_amount_received, balance_proof_pending_review
       FROM mobile_orders
       WHERE order_source = 'POS' AND pos_claimed = $1
       ORDER BY created_at DESC
       LIMIT 120`,
      [claimed],
    );
    const out = await attachOrderItems(rows as Array<Record<string, unknown>>);
    res.json(out);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.patch("/api/mobile/pos/walkin-orders/:id/claim", async (req, res) => {
  const id = Number(req.params.id);
  const cashierEmail = String(req.body?.cashier_email ?? "").trim().toLowerCase();
  const cashierPassword = String(req.body?.cashier_password ?? "");
  if (!id || !cashierEmail || !cashierPassword) {
    res.status(400).json({ error: "id and cashier credentials are required" });
    return;
  }
  if (!(await verifyCashier(cashierEmail, cashierPassword))) {
    res.status(403).json({ error: "invalid cashier credentials" });
    return;
  }
  try {
    const { rows } = await getPool().query(
      `UPDATE mobile_orders
       SET pos_claimed = TRUE, updated_at = NOW()
       WHERE id = $1 AND order_source = 'POS'
       RETURNING id`,
      [id],
    );
    if (!rows[0]) {
      res.status(404).json({ error: "walk-in order not found" });
      return;
    }
    res.json({ ok: true });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.get("/api/mobile/profile", async (req, res) => {
  const userEmail = String(req.query.user_email ?? "").trim().toLowerCase();
  if (!userEmail) {
    res.status(400).json({ error: "user_email is required" });
    return;
  }
  try {
    const { rows } = await getPool().query(
      `SELECT user_email, full_name, contact_number, delivery_address, delivery_map_confirmed,
              delivery_lat, delivery_lng
       FROM mobile_profiles WHERE user_email = $1`,
      [userEmail],
    );
    if (!rows[0]) {
      res.json({
        user_email: userEmail,
        full_name: "",
        contact_number: "",
        delivery_address: "",
        delivery_map_confirmed: false,
        delivery_lat: null,
        delivery_lng: null,
      });
      return;
    }
    res.json(rows[0]);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.put("/api/mobile/profile", async (req, res) => {
  const userEmail = String(req.body?.user_email ?? "").trim().toLowerCase();
  const fullName = String(req.body?.full_name ?? "").trim();
  const contactNumber = String(req.body?.contact_number ?? "").trim();
  const deliveryAddress = String(req.body?.delivery_address ?? "").trim();
  const mapConfirmed =
    typeof req.body?.delivery_map_confirmed === "boolean" ? req.body.delivery_map_confirmed : false;
  const latNum = numOrNull(req.body?.delivery_lat);
  const lngNum = numOrNull(req.body?.delivery_lng);
  if (!userEmail) {
    res.status(400).json({ error: "user_email is required" });
    return;
  }
  try {
    const { rows } = await getPool().query(
      `INSERT INTO mobile_profiles (user_email, full_name, contact_number, delivery_address, delivery_map_confirmed, delivery_lat, delivery_lng)
       VALUES ($1, $2, $3, $4, $5, $6, $7)
       ON CONFLICT (user_email)
       DO UPDATE SET full_name = EXCLUDED.full_name,
                     contact_number = EXCLUDED.contact_number,
                     delivery_address = EXCLUDED.delivery_address,
                     delivery_map_confirmed = EXCLUDED.delivery_map_confirmed,
                     delivery_lat = EXCLUDED.delivery_lat,
                     delivery_lng = EXCLUDED.delivery_lng,
                     updated_at = NOW()
       RETURNING user_email, full_name, contact_number, delivery_address, delivery_map_confirmed, delivery_lat, delivery_lng`,
      [userEmail, fullName, contactNumber, deliveryAddress, mapConfirmed, latNum, lngNum],
    );
    res.json(rows[0]);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.get("/api/mobile/orders", async (req, res) => {
  const userEmail = String(req.query.user_email ?? "").trim().toLowerCase();
  if (!userEmail) {
    res.status(400).json({ error: "user_email is required" });
    return;
  }
  try {
    const { rows } = await getPool().query(
      `SELECT id, user_email, order_no, status, note, payment_mode, payment_uploaded, payment_proof,
              delivery_name, delivery_contact, delivery_address, delivery_time, total, created_at,
              order_source, pos_customer_label, cashier_amount_received, cashier_change,
              fulfillment_stage, delivery_tracking_url, order_lines_snapshot,
              supplemental_payment_proof, cashier_secondary_amount_received, balance_proof_pending_review
       FROM mobile_orders
       WHERE user_email = $1
       ORDER BY created_at DESC`,
      [userEmail],
    );
    const orderIds = rows.map((r) => Number(r.id));
    let itemRows: Array<{ order_id: number; item_name: string; dip: string; qty: number; price: string }> = [];
    if (orderIds.length > 0) {
      const { rows: ir } = await getPool().query(
        `SELECT order_id, item_name, dip, qty, price
         FROM mobile_order_items WHERE order_id = ANY($1::bigint[])`,
        [orderIds],
      );
      itemRows = ir as typeof itemRows;
    }
    const byOrder = new Map<number, typeof itemRows>();
    for (const item of itemRows) {
      const arr = byOrder.get(item.order_id) ?? [];
      arr.push(item);
      byOrder.set(item.order_id, arr);
    }
    type LineOut = { item_name: string; dip: string; qty: number; price: number };
    res.json(
      rows.map((row) => {
        const idNum = Number(row.id);
        const rawList = byOrder.get(idNum) ?? [];
        let items: LineOut[] = rawList.map((it) => ({
          item_name: it.item_name,
          dip: it.dip,
          qty: Number(it.qty),
          price: Number(it.price),
        }));
        if (items.length === 0 && (row as { order_lines_snapshot?: unknown }).order_lines_snapshot != null) {
          const snap = (row as { order_lines_snapshot: unknown }).order_lines_snapshot;
          const arr = Array.isArray(snap) ? snap : [];
          items = arr.map((it: Record<string, unknown>) => ({
            item_name: String(it.item_name ?? ""),
            dip: String(it.dip ?? ""),
            qty: Number(it.qty ?? 0),
            price: Number(it.price ?? 0),
          }));
        }
        return {
          ...row,
          items,
          total: Number((row as { total: unknown }).total),
        };
      }),
    );
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.post("/api/mobile/orders", async (req, res) => {
  const userEmail = String(req.body?.user_email ?? "").trim().toLowerCase();
  const note = String(req.body?.note ?? "");
  const paymentMode = "GCASH ONLY";
  const deliveryName = String(req.body?.delivery_name ?? "");
  const deliveryContact = String(req.body?.delivery_contact ?? "");
  const deliveryAddress = String(req.body?.delivery_address ?? "");
  const deliveryTime = "NOW";
  const items: unknown[] = Array.isArray(req.body?.items) ? (req.body.items as unknown[]) : [];
  if (!userEmail || items.length === 0) {
    res.status(400).json({ error: "user_email and items are required" });
    return;
  }
  const parsedItems = items
    .map((i) => ({
      item_name: String((i as Record<string, unknown>)?.item_name ?? ""),
      dip: String((i as Record<string, unknown>)?.dip ?? ""),
      qty: Number((i as Record<string, unknown>)?.qty ?? 0),
      price: Number((i as Record<string, unknown>)?.price ?? 0),
    }))
    .filter((i) => i.item_name && i.qty > 0 && i.price >= 0);
  if (parsedItems.length === 0) {
    res.status(400).json({ error: "valid items are required" });
    return;
  }
  const total = parsedItems.reduce((sum, i) => sum + i.qty * i.price, 0);
  const client = await getPool().connect();
  try {
    await client.query("BEGIN");
    const { rows } = await client.query(
      `INSERT INTO mobile_orders
        (user_email, order_no, note, payment_mode, delivery_name, delivery_contact, delivery_address, delivery_time, total)
       VALUES
        ($1, 'TEMP', $2, $3, $4, $5, $6, $7, $8)
       RETURNING id`,
      [userEmail, note, paymentMode, deliveryName, deliveryContact, deliveryAddress, deliveryTime, total],
    );
    const orderId = Number(rows[0].id);
    const orderNo = `Order No. ${String(orderId).padStart(6, "0")}`;
    await client.query("UPDATE mobile_orders SET order_no = $1 WHERE id = $2", [orderNo, orderId]);
    for (const item of parsedItems) {
      await client.query(
        `INSERT INTO mobile_order_items (order_id, item_name, dip, qty, price)
         VALUES ($1, $2, $3, $4, $5)`,
        [orderId, item.item_name, item.dip, item.qty, item.price],
      );
    }
    await client.query(`UPDATE mobile_orders SET order_lines_snapshot = $2::jsonb WHERE id = $1`, [
      orderId,
      JSON.stringify(parsedItems),
    ]);
    await client.query("COMMIT");
    void sendMailSafe(
      userEmail,
      `Order ${orderNo} submitted`,
      `Your order ${orderNo} was submitted at ${new Date().toISOString()}.\nTotal: ₱${total.toFixed(2)}\nNote: ${note || "(none)"}`,
    );
    res.status(201).json({ id: orderId, order_no: orderNo, total });
  } catch (err) {
    await client.query("ROLLBACK");
    console.error(err);
    res.status(500).json({ error: "database error" });
  } finally {
    client.release();
  }
});

app.patch("/api/mobile/orders/:id/payment", async (req, res) => {
  const id = Number(req.params.id);
  const paymentProof = String(req.body?.payment_proof ?? "");
  if (!id || !paymentProof) {
    res.status(400).json({ error: "id and payment_proof are required" });
    return;
  }
  try {
    const { rows: found } = await getPool().query(
      `SELECT id, status, order_no FROM mobile_orders WHERE id = $1`,
      [id],
    );
    const row = found[0] as { id: number; status: string; order_no: string } | undefined;
    if (!row) {
      res.status(404).json({ error: "order not found" });
      return;
    }
    const insufficient = String(row.status).toUpperCase().includes("INSUFFICIENT");
    if (insufficient) {
      await getPool().query(
        `UPDATE mobile_orders
         SET supplemental_payment_proof = $2,
             balance_proof_pending_review = TRUE,
             payment_uploaded = TRUE,
             updated_at = NOW()
         WHERE id = $1`,
        [id, paymentProof],
      );
      const notify = process.env.CASHIER_BALANCE_NOTIFY_EMAIL?.trim();
      if (notify) {
        void sendMailSafe(
          notify,
          `Balance payment proof — ${row.order_no}`,
          `A customer uploaded supplemental payment proof for order ${row.order_no}. Open Online Orders in the cashier app to review and enter the amount received.`,
        );
      }
    } else {
      await getPool().query(
        `UPDATE mobile_orders
         SET payment_uploaded = TRUE, payment_proof = $2, updated_at = NOW()
         WHERE id = $1`,
        [id, paymentProof],
      );
    }
    const { rows } = await getPool().query(
      `SELECT id, order_no, payment_uploaded, balance_proof_pending_review FROM mobile_orders WHERE id = $1`,
      [id],
    );
    res.json(rows[0]);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.get("/api/mobile/inquiries", async (req, res) => {
  const userEmail = String(req.query.user_email ?? "").trim().toLowerCase();
  if (!userEmail) {
    res.status(400).json({ error: "user_email is required" });
    return;
  }
  try {
    const { rows } = await getPool().query(
      `SELECT id, inquiry_no, inquiry_type, event_title, event_type, customer, contact_person, contact_number,
              inquiry_email, date_of_event, note, curate_own_menu, selected_set_menu, selected_dishes,
              include_event_theme, guest_count, menu_suggestion_note, theme_suggestion_note, estimated_total,
              status, created_at,
              event_city, event_setting, service_included, formality_level, food_tasting_requested
       FROM mobile_inquiries
       WHERE user_email = $1
       ORDER BY created_at DESC`,
      [userEmail],
    );
    res.json(rows);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.post("/api/mobile/inquiries", async (req, res) => {
  const userEmail = String(req.body?.user_email ?? "").trim().toLowerCase();
  if (!userEmail) {
    res.status(400).json({ error: "user_email is required" });
    return;
  }
  const inquiryType = String(req.body?.inquiry_type ?? "CATERING");
  const eventTitle = String(req.body?.event_title ?? "");
  const eventType = String(req.body?.event_type ?? "");
  const customer = String(req.body?.customer ?? "");
  const contactPerson = String(req.body?.contact_person ?? "");
  const contactNumber = String(req.body?.contact_number ?? "");
  const inquiryEmail = String(req.body?.inquiry_email ?? "");
  const dateOfEvent = String(req.body?.date_of_event ?? "");
  const note = String(req.body?.note ?? "");
  const curateOwnMenu = Boolean(req.body?.curate_own_menu);
  const selectedSetMenu = String(req.body?.selected_set_menu ?? "");
  const selectedDishes = JSON.stringify(Array.isArray(req.body?.selected_dishes) ? req.body.selected_dishes : []);
  const includeEventTheme = Boolean(req.body?.include_event_theme);
  const guestCount = Math.max(0, Number(req.body?.guest_count ?? 0));
  const menuSuggestionNote = String(req.body?.menu_suggestion_note ?? "");
  const themeSuggestionNote = String(req.body?.theme_suggestion_note ?? "");
  const estimatedTotal = Number(req.body?.estimated_total ?? 0);
  const eventCity = String(req.body?.event_city ?? "");
  const eventSetting = String(req.body?.event_setting ?? "");
  const serviceIncluded = String(req.body?.service_included ?? "");
  const formalityLevel = String(req.body?.formality_level ?? "");
  const foodTastingRequested = Boolean(req.body?.food_tasting_requested);
  try {
    const { rows } = await getPool().query(
      `INSERT INTO mobile_inquiries
      (user_email, inquiry_no, inquiry_type, event_title, event_type, customer, contact_person, contact_number,
       inquiry_email, date_of_event, note, curate_own_menu, selected_set_menu, selected_dishes, include_event_theme,
       guest_count, menu_suggestion_note, theme_suggestion_note, estimated_total,
       event_city, event_setting, service_included, formality_level, food_tasting_requested)
     VALUES
      ($1, 'TEMP', $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20, $21, $22, $23)
     RETURNING id`,
      [
        userEmail,
        inquiryType,
        eventTitle,
        eventType,
        customer,
        contactPerson,
        contactNumber,
        inquiryEmail,
        dateOfEvent,
        note,
        curateOwnMenu,
        selectedSetMenu,
        selectedDishes,
        includeEventTheme,
        guestCount,
        menuSuggestionNote,
        themeSuggestionNote,
        estimatedTotal,
        eventCity,
        eventSetting,
        serviceIncluded,
        formalityLevel,
        foodTastingRequested,
      ],
    );
    const id = Number(rows[0].id);
    const inquiryNo = `INQ-${String(id).padStart(6, "0")}`;
    await getPool().query("UPDATE mobile_inquiries SET inquiry_no = $1 WHERE id = $2", [inquiryNo, id]);
    void sendMailSafe(
      userEmail,
      `Inquiry ${inquiryNo} received`,
      `Your catering inquiry ${inquiryNo} was submitted at ${new Date().toISOString()}.\nEvent: ${eventTitle || "(no title)"}`,
    );
    res.status(201).json({ id, inquiry_no: inquiryNo });
  } catch (err) {
    console.error(err);
    res.status(500).json({
      error: err instanceof Error ? err.message : "could not save inquiry — check database migrations",
    });
  }
});

app.post("/api/mobile/help", async (req, res) => {
  const userEmail = String(req.body?.user_email ?? "").trim().toLowerCase();
  const area = String(req.body?.area ?? "").trim();
  const problem = String(req.body?.problem ?? "").trim();
  const desiredOutcome = String(req.body?.desired_outcome ?? "").trim();
  if (!userEmail || !area || !problem || !desiredOutcome) {
    res.status(400).json({ error: "user_email, area, problem, and desired_outcome are required" });
    return;
  }
  try {
    await getPool().query(
      `INSERT INTO mobile_help_requests (user_email, area, problem, desired_outcome)
       VALUES ($1, $2, $3, $4)`,
      [userEmail, area, problem, desiredOutcome],
    );
    void sendMailSafe(
      userEmail,
      "Help request received",
      `We recorded your help request.\nArea: ${area}\nProblem: ${problem}\nWhat you'd like: ${desiredOutcome}`,
    );
    res.status(201).json({ ok: true });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

async function seedCashierAccount(): Promise<void> {
  const email = "rhannahdrex@yahoo.com";
  const displayName = "Drexyll Calibara";
  const hash = await bcrypt.hash("hannah24", 10);
  try {
    const pool = getPool();
    const { rows } = await pool.query(`SELECT id FROM mobile_users WHERE email = $1`, [email]);
    if (!rows[0]) {
      await pool.query(
        `INSERT INTO mobile_users (email, password_hash, role, display_name) VALUES ($1, $2, 'cashier', $3)`,
        [email, hash, displayName],
      );
      console.log("[db] seeded cashier:", email);
    } else {
      await pool.query(`UPDATE mobile_users SET role = 'cashier', display_name = $2 WHERE email = $1`, [
        email,
        displayName,
      ]);
      console.log("[db] cashier role/display ensured:", email);
    }
  } catch (e) {
    console.warn("[db] cashier seed skipped:", e);
  }
}

async function main() {
  await initDb();
  await seedCashierAccount();
  app.listen(port, () => {
    console.log(`curatering-backend listening on http://localhost:${port}`);
  });
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
