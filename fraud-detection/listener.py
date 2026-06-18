"""
fraud-detection — STOMP message listener
Receives messages from fraud.score.queue, scores each transaction,
and logs a structured result record.
"""

import json
import logging
import os

import stomp

from scorer import score

# ── DATADOG APM — CUSTOM SPANS ────────────────────────────────────────
# Uncomment to create a manual span around each fraud.score operation.
# This gives you a dedicated span in the APM Trace view that you can
# tag with Finance-domain attributes for slice-and-dice analysis.
# Requires: ddtrace installed + patch_all() called in main.py first.
# Docs: https://docs.datadoghq.com/tracing/trace_collection/custom_instrumentation/python/
#
# from ddtrace import tracer
# ─────────────────────────────────────────────────────────────────────

# ── DATADOG DATA STREAMS MONITORING ──────────────────────────────────
# Uncomment to instrument this consumer for DSM pipeline visibility.
# DSM will track end-to-end latency from the JMS producer (account-service
# or transaction-service) through to this consumer, expose consumer lag,
# and surface the pathway in the Data Streams map.
# Requires: ddtrace[data_streams] installed + DD_DATA_STREAMS_ENABLED=true.
# Docs: https://docs.datadoghq.com/data_streams/python/
#
# from ddtrace.data_streams import set_consume_checkpoint
# ─────────────────────────────────────────────────────────────────────

# ── DATADOG DOGSTATSD — CUSTOM METRICS ───────────────────────────────
# Uncomment to emit a DogStatsD gauge for every scored message.
# finance.fraud.score is tagged by score_bucket (low/medium/high) — NOT
# by the raw float score, which would be unbounded high-cardinality.
# HIGH-CARDINALITY WARNING: never use the raw fraud score float as a tag
# value. Always bucket first. See: https://docs.datadoghq.com/tagging/assigning_tags/
# Requires: datadog package installed + DOGSTATSD_HOST env var set.
# Docs: https://docs.datadoghq.com/developers/dogstatsd/
#
# from datadog import initialize as dd_initialize, statsd
# dd_initialize(
#     statsd_host=os.environ.get("DOGSTATSD_HOST", os.environ.get("DD_AGENT_HOST", "datadog-agent")),
#     statsd_port=int(os.environ.get("DOGSTATSD_PORT", "8125")),
# )
# ─────────────────────────────────────────────────────────────────────

logger = logging.getLogger("fraud_detection.listener")


class FraudScoreListener(stomp.ConnectionListener):
    """
    STOMP ConnectionListener that handles messages on fraud.score.queue.

    Each message body is expected to be a JSON object with at least:
      {
        "transaction_id": "txn-8f3a2c",
        "amount":         1500.00,
        "currency":       "EUR",
        "transaction_type": "payment",
        "account_id":     "acc-001"
      }
    """

    def on_error(self, frame: stomp.utils.Frame) -> None:
        logger.error(
            "Received STOMP error frame",
            extra={"stomp.error": frame.body},
        )

    def on_message(self, frame: stomp.utils.Frame) -> None:
        """
        Main message handler. Called once per inbound STOMP frame.

        Processing order:
          1. DSM consume checkpoint (commented)   — records pipeline ingress timestamp
          2. Parse JSON body
          3. Call scorer.score()
          4. Custom APM span (commented)          — wraps scoring work
          5. DogStatsD gauge emit (commented)
          6. Structured log of the result
          7. ACK the frame so the broker removes it from the queue
        """
        subscription_id = frame.headers.get("subscription", "unknown")
        message_id = frame.headers.get("message-id", "unknown")
        correlation_id = frame.headers.get("correlation-id", "")

        # ── DATADOG DATA STREAMS — CONSUME CHECKPOINT ─────────────────
        # Call this BEFORE processing so that DSM records the ingress
        # timestamp and can calculate producer-to-consumer latency.
        # The headers dict carries the DSM pathway context injected by
        # the Java producer (account-service / transaction-service).
        # Docs: https://docs.datadoghq.com/data_streams/python/
        #
        # set_consume_checkpoint("jms", "fraud.score.queue", frame.headers)
        # ─────────────────────────────────────────────────────────────

        try:
            body = json.loads(frame.body)
        except (json.JSONDecodeError, TypeError) as exc:
            logger.error(
                "Failed to parse message body",
                extra={
                    "message_id": message_id,
                    "error": str(exc),
                },
            )
            # ACK even on parse failure to avoid poison-pill infinite redelivery.
            frame.connection.ack(message_id, subscription_id)
            return

        transaction_id = body.get("transaction_id", "unknown")
        transaction_type = body.get("transaction_type", "unknown")
        amount = float(body.get("amount", 0.0))
        currency = body.get("currency", "UNKNOWN")

        # ── DATADOG APM — CUSTOM SPAN ─────────────────────────────────
        # Wrap the scoring call in a manual span named "fraud.score".
        # Tag with Finance-domain attributes so you can filter traces
        # in APM > Services > fraud-detection by score_bucket or
        # transaction_type without touching log search.
        #
        # HIGH-CARDINALITY WARNING: do NOT add transaction_id or
        # message_id as span tags — those are unbounded.
        # Use correlation_id only if your broker reuses a bounded set.
        # Docs: https://docs.datadoghq.com/tracing/trace_collection/custom_instrumentation/python/
        #
        # with tracer.trace("fraud.score", service="fraud-detection", resource=transaction_type) as span:
        #     result = score({"transaction_id": transaction_id, "amount": amount})
        #     span.set_tag("transaction.type", transaction_type)
        #     span.set_tag("payment.currency", currency)
        #     span.set_tag("fraud.score_bucket", result["bucket"])
        #     span.set_tag("messaging.destination", "fraud.score.queue")
        #     # HIGH-CARDINALITY WARNING: messaging.message_id is per-message —
        #     # tag only when debugging a specific incident, not in production.
        #     # span.set_tag("messaging.message_id", message_id)
        #     if result["bucket"] == "high":
        #         span.error = 1
        #         span.set_tag("error.message", "High-risk transaction flagged")
        # ─────────────────────────────────────────────────────────────

        result = score({"transaction_id": transaction_id, "amount": amount})

        # ── DATADOG DOGSTATSD — GAUGE ─────────────────────────────────
        # Emit a gauge for each scored message. The value is the raw
        # score float (useful for aggregation in Datadog metrics), but
        # the BUCKET tag is what you use for alerting and dashboards.
        # Never create a metric whose tag value IS the raw float —
        # that produces one time series per unique float value.
        # Docs: https://docs.datadoghq.com/developers/dogstatsd/
        #
        # statsd.gauge(
        #     "finance.fraud.score",
        #     value=result["score"],
        #     tags=[
        #         f"fraud.score_bucket:{result['bucket']}",
        #         f"transaction.type:{transaction_type}",
        #         f"payment.currency:{currency}",
        #         f"env:{os.environ.get('DD_ENV', 'local')}",
        #         f"service:{os.environ.get('DD_SERVICE', 'fraud-detection')}",
        #     ],
        # )
        # ─────────────────────────────────────────────────────────────

        logger.info(
            "Fraud score computed",
            extra={
                # Business context
                "transaction_id": transaction_id,
                "transaction.type": transaction_type,
                "payment.currency": currency,
                "fraud.score": result["score"],
                "fraud.score_bucket": result["bucket"],
                # Messaging context
                "messaging.destination": "fraud.score.queue",
                "jms.correlation_id": correlation_id,
                # Omit message_id from logs in production to avoid
                # high-cardinality log index bloat.
            },
        )

        frame.connection.ack(message_id, subscription_id)
