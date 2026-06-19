// ── DATADOG INSTRUMENTATION ──────────────────────────────────────────
// Step 3 — APM initialisation. dd-trace MUST be required before any
// other module — including express, pino, or your own files.
// Requiring it later will miss auto-instrumentation of already-loaded
// modules (e.g. http, net) and produce incomplete traces.
//
// Prerequisites:
//   npm install dd-trace --save
//   Set DD_ENV, DD_SERVICE, DD_VERSION, DD_AGENT_HOST in your environment.
//
// const tracer = require('dd-trace').init({
//   service:  process.env.DD_SERVICE  || 'transaction-service',
//   env:      process.env.DD_ENV      || 'development',
//   version:  process.env.DD_VERSION  || '0.0.0',
//   hostname: process.env.DD_AGENT_HOST || 'datadog-agent',
//
//   // ── Log injection ────────────────────────────────────────────────
//   // Injects dd.trace_id and dd.span_id into every pino log record.
//   // Step 4 — verify trace_id appears in Datadog Log Management.
//   // logInjection: true,
//
//   // ── Runtime metrics ──────────────────────────────────────────────
//   // Step 6 — emit Node.js V8/GC/event-loop metrics to DogStatsD.
//   // runtimeMetrics: true,
//
//   // ── Profiler ─────────────────────────────────────────────────────
//   // Step 7 — continuous CPU + heap profiling. Correlate flame graphs
//   // with slow payment traces in APM > Profiling.
//   // profiling: true,
// });
// ─────────────────────────────────────────────────────────────────────

'use strict';

const express = require('express');
const pino    = require('pino');
const pinoHttp = require('pino-http');

const paymentsRouter = require('./routes/payments');

// ── STRUCTURED LOGGING ───────────────────────────────────────────────
// Always use structured JSON logs — raw console.log is never acceptable
// in production Finance services (no trace correlation, no log parsing).
// When dd-trace logInjection is enabled (Step 4), dd.trace_id and
// dd.span_id are automatically appended to every log record, enabling
// the "View in APM" button inside Datadog Log Management.
// ─────────────────────────────────────────────────────────────────────
const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  base: {
    service: process.env.DD_SERVICE  || 'transaction-service',
    env:     process.env.DD_ENV      || 'development',
    version: process.env.DD_VERSION  || '0.0.0',
  },
});

const app  = express();
const PORT = parseInt(process.env.PORT || '8082', 10);

// Parse JSON request bodies
app.use(express.json());

// HTTP request logging via pino-http (structured, not morgan)
app.use(pinoHttp({ logger }));

// ── HEALTH ENDPOINT ──────────────────────────────────────────────────
// Step 12 — target this endpoint with a Datadog Synthetic API test.
// Docs: https://docs.datadoghq.com/synthetics/
// ─────────────────────────────────────────────────────────────────────
app.get('/health', (_req, res) => {
  res.json({
    status:  'ok',
    service: process.env.DD_SERVICE || 'transaction-service',
    version: process.env.DD_VERSION || '0.0.0',
  });
});

// Mount the payments router under the versioned prefix
app.use('/v1/payments', paymentsRouter);

// Global error handler — always log with structured fields
app.use((err, req, res, _next) => {
  req.log.error({ err, route: req.path }, 'Unhandled error in transaction-service');
  res.status(500).json({ error: 'internal_server_error' });
});

app.listen(PORT, () => {
  logger.info({ port: PORT }, 'transaction-service listening');
});

module.exports = app; // exported for testing
