'use strict';

const pino = require('pino');

const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  base: {
    service:   process.env.DD_SERVICE || 'transaction-service',
    env:       process.env.DD_ENV     || 'development',
    version:   process.env.DD_VERSION || '0.0.0',
    component: 'ledger',
  },
});

// ── DATADOG INSTRUMENTATION ──────────────────────────────────────────
// Step 5 — custom span for ledger.commit.
// This wraps the database write so the APM flame graph shows ledger
// latency separately from fraud-queue publishing. Without this span,
// both operations are folded into the parent payment.authorize span
// and you cannot distinguish DB slowness from broker slowness.
//
// const tracer = require('dd-trace');
// ─────────────────────────────────────────────────────────────────────

/**
 * Writes a payment record to the ledger (PostgreSQL in production).
 *
 * In this stub the write is simulated with a fixed delay.
 * Replace with a real pg/knex/typeorm query when wiring to PostgreSQL.
 *
 * @param {object} params
 * @param {string} params.payment_id
 * @param {number} params.amount
 * @param {string} params.currency
 * @param {string} params.account_id
 * @returns {Promise<{committed: boolean}>}
 */
async function commit({ payment_id, amount, currency, account_id }) {
  // ── DATADOG INSTRUMENTATION ────────────────────────────────────────
  // Step 5 — open a ledger.commit child span.
  // Tags:
  //   db.instance    → 'postgres-ledger' (matches DBM Agent config — enables
  //                    the "View in DBM" button on this span in APM)
  //   db.type        → 'postgresql'
  //   db.statement   → parameterised SQL only (never interpolate values —
  //                    prevents PII leakage into trace tags)
  //
  // Docs: https://docs.datadoghq.com/database_monitoring/connect_dbm_and_apm/
  //
  // const span = tracer.startSpan('ledger.commit', {
  //   childOf: tracer.scope().active(),
  //   tags: {
  //     'db.instance':   'postgres-ledger',
  //     'db.type':       'postgresql',
  //     'db.statement':  'INSERT INTO transactions (id, amount, currency, account_id, status) VALUES ($1,$2,$3,$4,$5)',
  //     'resource.name': 'ledger.commit',
  //     'payment.currency': currency,
  //   },
  // });
  // ─────────────────────────────────────────────────────────────────────

  try {
    // Simulated async DB write — replace with real query:
    //
    // const { Pool } = require('pg');
    // const pool = new Pool({ connectionString: process.env.POSTGRES_URL });
    // await pool.query(
    //   'INSERT INTO transactions (id, amount, currency, account_id, status) VALUES ($1,$2,$3,$4,$5)',
    //   [payment_id, amount, currency, account_id, 'pending']
    // );
    await new Promise((resolve) => setTimeout(resolve, 10));

    logger.info(
      {
        payment_id,
        amount,
        currency,
        account_id,
        'db.instance': 'postgres-ledger',
        'db.operation': 'INSERT',
      },
      'ledger.commit'
    );

    // ── DATADOG INSTRUMENTATION ──────────────────────────────────────
    // Step 5 — close the span on success.
    // span.finish();
    // ─────────────────────────────────────────────────────────────────

    return { committed: true };
  } catch (err) {
    logger.error(
      { err, payment_id, 'db.instance': 'postgres-ledger' },
      'ledger.commit.failed'
    );

    // ── DATADOG INSTRUMENTATION ──────────────────────────────────────
    // Step 5 — mark span as error so it appears in APM Error Tracking.
    // Step 6 — increment the ledger commit error counter so monitors
    //           and dashboards can alert before the on-call engineer
    //           notices via logs.
    //
    // const { ERROR_MESSAGE, ERROR_TYPE, ERROR_STACK } = require('dd-trace/ext/tags');
    // span.setTag(ERROR_TYPE,    err.constructor.name);
    // span.setTag(ERROR_MESSAGE, err.message);
    // span.setTag(ERROR_STACK,   err.stack);
    // span.finish();
    //
    // dogstatsd.increment('ledger.commit.errors', 1, {
    //   'db.instance': 'postgres-ledger',
    //   'payment.currency': currency,
    // });
    // Docs: https://docs.datadoghq.com/developers/dogstatsd/
    // ─────────────────────────────────────────────────────────────────

    throw err;
  }
}

module.exports = { commit };
