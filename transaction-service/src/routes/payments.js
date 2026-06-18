"use strict";

const express = require("express");
const { v4: uuidv4 } = require("uuid");
const pino = require("pino");

const ledger = require("../services/ledger");
const producer = require("../messaging/producer");

const router = express.Router();

const logger = pino({
  level: process.env.LOG_LEVEL || "info",
  base: {
    service: process.env.DD_SERVICE || "transaction-service",
    env: process.env.DD_ENV || "development",
    version: process.env.DD_VERSION || "0.0.0",
  },
});

// ── DOGSTATSD CLIENT ─────────────────────────────────────────────────
// Step 6 — emit custom Finance metrics.
// Requires: npm install hot-shots --save (DogStatsD client for Node.js)
// Docs: https://docs.datadoghq.com/developers/dogstatsd/
//
// const StatsD = require('hot-shots');
// const dogstatsd = new StatsD({
//   host: process.env.DD_AGENT_HOST || 'datadog-agent',
//   port: 8125,
//   prefix: 'finance.',
//   globalTags: {
//     env:     process.env.DD_ENV     || 'development',
//     service: process.env.DD_SERVICE || 'transaction-service',
//     version: process.env.DD_VERSION || '0.0.0',
//   },
// });
// ─────────────────────────────────────────────────────────────────────

// In-memory payment store (replace with PostgreSQL in a real deployment)
const payments = new Map();

// ── POST /v1/payments ────────────────────────────────────────────────
// Initiates a payment: validates input, writes to ledger, publishes a
// fraud-scoring message to ActiveMQ, and returns a pending payment stub.
// ─────────────────────────────────────────────────────────────────────
router.post("/", async (req, res) => {
  const { amount, currency, account_id, payment_id: incoming_id } = req.body;

  if (!amount || !currency || !account_id) {
    return res.status(400).json({
      error: "missing_fields",
      required: ["amount", "currency", "account_id"],
    });
  }

  // Use the payment_id forwarded by the gateway, or generate one if called directly.
  const payment_id = incoming_id || uuidv4();
  const startTime = Date.now();

  // ── DATADOG INSTRUMENTATION ──────────────────────────────────────────
  // Step 5 — custom span for payment.authorize.
  // Wraps the core authorisation logic so the span duration matches the
  // actual business operation, not the full HTTP handler.
  //
  // Finance tags (transaction.type, payment.currency) let you slice APM
  // error rates and latency by transaction category and currency in the
  // APM Service page or a custom dashboard.
  //
  // HIGH-CARDINALITY WARNING: Do NOT tag with raw payment_id or account_id
  // at the metric level — use them only on spans/logs where trace sampling
  // already limits volume. See: https://docs.datadoghq.com/tagging/assigning_tags/
  //
  // const tracer = require('dd-trace');
  // const span = tracer.startSpan('payment.authorize', {
  //   tags: {
  //     'transaction.type':  'payment',
  //     'payment.currency':  currency,
  //     'account.id':        account_id,  // bounded: OK on spans, not on metrics
  //     'http.route':        '/v1/payments',
  //     'resource.name':     'payment.authorize',
  //   },
  // });
  // ─────────────────────────────────────────────────────────────────────

  // Store the payment immediately — persistence must not depend on JMS availability.
  const payment = {
    payment_id,
    amount,
    currency,
    account_id,
    status: "pending",
    created_at: new Date().toISOString(),
  };
  payments.set(payment_id, payment);

  // Step 1: write to ledger (best-effort — log failure, do not abort)
  try {
    await ledger.commit({ payment_id, amount, currency, account_id });
  } catch (err) {
    logger.warn({ err, payment_id }, "ledger.commit.failed");
  }

  // Step 2: publish fraud-scoring event (best-effort — JMS unavailability
  // must not cause payment loss; the payment is already stored above).
  try {
    await producer.send("fraud.score.queue", {
      payment_id,
      amount,
      currency,
      account_id,
    });
  } catch (err) {
    logger.warn({ err, payment_id }, "fraud-scoring.publish.failed");
  }

  try {
    logger.info(
      {
        payment_id,
        amount,
        currency,
        account_id,
        "transaction.type": "payment",
        "http.route": "/v1/payments",
      },
      "payment.initiated",
    );

    // ── DATADOG INSTRUMENTATION ──────────────────────────────────────
    // Step 6 — custom metrics for this payment.
    //
    // finance.payment.initiated: counter — how many payments were started.
    // Tag by currency and transaction type so you can alert on a drop in
    // EUR payments independently of USD payments.
    //
    // finance.payment.processing_time: histogram — end-to-end duration of
    // the initiation flow (ledger write + JMS publish). Use this to detect
    // P99 regressions before customers notice.
    //
    // dogstatsd.increment('payment.initiated', 1, {
    //   'transaction.type': 'payment',
    //   'payment.currency': currency,
    // });
    //
    // dogstatsd.histogram('payment.processing_time', Date.now() - startTime, {
    //   'transaction.type': 'payment',
    //   'payment.currency': currency,
    // });
    //
    // ── DATADOG INSTRUMENTATION ──────────────────────────────────────
    // Step 5 (continued) — close the span on success.
    // span.finish();
    // ─────────────────────────────────────────────────────────────────

    return res.status(201).json(payment);
  } catch (err) {
    // Logging failure should not fail the request — payment is already stored.
    logger.error({ err, payment_id }, "payment.log.failed");
    return res.status(201).json(payment);
  }
});

// ── GET /v1/payments ────────────────────────────────────────────────
// Returns all payments in the in-memory store as an array.
// Used by the gateway compliance endpoint to list payments for validation.
// ─────────────────────────────────────────────────────────────────────
router.get("/", (req, res) => {
  const list = Array.from(payments.values());
  logger.info(
    { count: list.length, "http.route": "/v1/payments" },
    "payments.list",
  );
  return res.json(list);
});

// ── PATCH /v1/payments/:id ───────────────────────────────────────────
// Updates a payment's status (approve / reject / flag).
// Called by the gateway after verifying the caller has finance-compliance
// or finance-admin role. The gateway owns role enforcement.
// ─────────────────────────────────────────────────────────────────────
router.patch("/:id", (req, res) => {
  const { id } = req.params;
  const { status, note } = req.body;

  const VALID_STATUSES = ["approved", "rejected", "flagged"];
  if (!status || !VALID_STATUSES.includes(status)) {
    return res.status(400).json({
      error: "invalid_status",
      allowed: VALID_STATUSES,
    });
  }

  const payment = payments.get(id);
  if (!payment) {
    logger.warn({ payment_id: id }, "payment.validate.not_found");
    return res.status(404).json({ error: "payment_not_found", payment_id: id });
  }

  payment.status = status;
  payment.note = note || null;
  payment.validated_at = new Date().toISOString();
  payments.set(id, payment);

  logger.info(
    {
      payment_id: id,
      status,
      "http.route": "/v1/payments/:id",
    },
    "payment.validated",
  );

  // ── DATADOG INSTRUMENTATION ────────────────────────────────────────
  // Step 6 — emit a counter for each validation action.
  // dogstatsd.increment('payment.validated', 1, {
  //   'payment.status':  status,
  //   'payment.currency': payment.currency,
  // });
  // ──────────────────────────────────────────────────────────────────

  return res.json(payment);
});

// ── GET /v1/payments/:id ─────────────────────────────────────────────
// Returns a payment by ID. In production this would query PostgreSQL.
// Step 9 — enable DBM to see the underlying SELECT query plan and
// correlate it with this APM span.
// Docs: https://docs.datadoghq.com/database_monitoring/connect_dbm_and_apm/
// ─────────────────────────────────────────────────────────────────────
router.get("/:id", (req, res) => {
  const { id } = req.params;
  const payment = payments.get(id);

  if (!payment) {
    logger.warn(
      { payment_id: id, "http.route": "/v1/payments/:id" },
      "payment.not_found",
    );
    return res.status(404).json({ error: "payment_not_found", payment_id: id });
  }

  logger.info(
    {
      payment_id: id,
      status: payment.status,
      "http.route": "/v1/payments/:id",
    },
    "payment.retrieved",
  );

  return res.json(payment);
});

module.exports = router;
