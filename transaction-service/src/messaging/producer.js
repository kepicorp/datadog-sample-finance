"use strict";

const stompit = require("stompit");
const pino = require("pino");

const logger = pino({
  level: process.env.LOG_LEVEL || "info",
  base: {
    service: process.env.DD_SERVICE || "transaction-service",
    env: process.env.DD_ENV || "development",
    version: process.env.DD_VERSION || "0.0.0",
    component: "messaging.producer",
  },
});

// ActiveMQ Artemis connection parameters.
// ACTIVEMQ_STOMP_URL format: stomp://host:61613 (set via app-config ConfigMap,
// matching the key used in deploy/kubernetes/base/01-config.yaml and the
// transaction-service Deployment env block).
const ACTIVEMQ_URL =
  process.env.ACTIVEMQ_STOMP_URL || "stomp://localhost:61613";
const [host, portStr] = ACTIVEMQ_URL.replace("stomp://", "").split(":");
const BROKER_PORT = parseInt(portStr || "61613", 10);

// ── DATADOG DATA STREAMS MONITORING ──────────────────────────────────
// Step 10 — enable DSM to get end-to-end pipeline visibility across
// the payment → fraud.score.queue → fraud-detection pathway.
//
// dd-trace automatically instruments STOMP connections when the tracer
// is initialised (see src/index.js). No manual checkpoint call is
// needed for Node.js — the auto-instrumentation injects the DSM
// pathway context into STOMP message headers.
//
// To verify DSM is working:
//   1. Set DD_DATA_STREAMS_ENABLED=true in the environment.
//   2. Deploy and send a test payment via POST /v1/payments.
//   3. Open Datadog > APM > Data Streams and look for the
//      transaction-service → fraud.score.queue → fraud-detection pathway.
//
// If you are using a JMS bridge or a bespoke STOMP client that does
// not carry headers automatically, add a manual producer checkpoint:
//
// const { DataStreams } = require('dd-trace/ext');
// const checkpointer = require('dd-trace').dataStreams;
// // Before calling client.send():
// checkpointer.setProduceCheckpoint('stomp', destination, headers);
//
// Docs: https://docs.datadoghq.com/data_streams/nodejs/
//
// Finance use-cases enabled by DSM on this queue:
//   - Consumer lag on fraud.score.queue → detect scoring backlog before
//     it delays payment confirmations to customers.
//   - End-to-end latency (producer → consumer) → SLA breach alerting.
//   - Queue depth trends → capacity planning for peak periods.
// ─────────────────────────────────────────────────────────────────────

/**
 * Publishes a JSON payload to the given STOMP destination on ActiveMQ.
 *
 * @param {string} destination  Queue name, e.g. 'fraud.score.queue'
 * @param {object} payload      Serialisable object (no PII in values —
 *                              use IDs only; resolve PII in the consumer)
 * @returns {Promise<void>}
 */
function send(destination, payload) {
  return new Promise((resolve, reject) => {
    const connectOptions = {
      host: host || "localhost",
      port: BROKER_PORT,
      // stompit requires login/passcode/heart-beat nested under
      // connectHeaders (NOT top-level) — see node_modules/stompit/README.md.
      // Sending them top-level is silently ignored by the client, which
      // then connects with an empty username and Artemis rejects it with
      // "Security Error occurred: User name [null] or password is invalid".
      connectHeaders: {
        host: "/",
        login: process.env.ACTIVEMQ_USER || "guest",
        passcode: process.env.ACTIVEMQ_PASSWORD || "guest",
        // STOMP v1.2 — required by ActiveMQ Artemis
        "heart-beat": "0,0",
      },
    };

    stompit.connect(connectOptions, (connectErr, client) => {
      if (connectErr) {
        logger.error(
          {
            err: connectErr,
            destination,
            "messaging.destination": destination,
          },
          "jms.produce.connect_failed",
        );
        return reject(connectErr);
      }

      // Guard against uncaught 'error' events on the connection after
      // connect (e.g. broker-side protocol errors, idle disconnects raced
      // with our own client.disconnect() below). stompit's Client extends
      // EventEmitter — an unhandled 'error' event crashes the whole Node
      // process, which previously caused this service to crash-loop.
      client.on("error", (err) => {
        logger.error(
          {
            err,
            destination,
            "messaging.destination": destination,
          },
          "jms.produce.connection_error",
        );
      });

      const body = JSON.stringify(payload);

      // ── JMS / STOMP MESSAGE HEADERS ──────────────────────────────────
      // HIGH-CARDINALITY WARNING: messaging.message_id is unbounded.
      // Use it on spans and logs only — never as a DogStatsD metric tag.
      // Docs: https://docs.datadoghq.com/tagging/assigning_tags/
      //
      // jms.correlation_id carries the payment_id as a business-level
      // correlation key so the consumer can link its logs to the
      // originating payment without querying a database.
      // ─────────────────────────────────────────────────────────────────
      const headers = {
        destination: `/queue/${destination}`,
        "content-type": "application/json",
        "content-length": Buffer.byteLength(body),
        "jms-correlation-id": payload.payment_id || "",
        // DSM context is injected here automatically by dd-trace when
        // DD_DATA_STREAMS_ENABLED=true (Step 10).
      };

      const frame = client.send(headers);
      frame.write(body);
      frame.end();

      logger.info(
        {
          destination,
          payment_id: payload.payment_id,
          "messaging.destination": destination,
          "jms.correlation_id": payload.payment_id,
          // messaging.message_id is set by the broker after send —
          // log it from the consumer ACK if needed, not here.
        },
        "jms.produce",
      );

      client.disconnect();
      resolve();
    });
  });
}

module.exports = { send };
