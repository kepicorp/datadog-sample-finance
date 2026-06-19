"""
fraud-detection — main entry point
Connects to ActiveMQ Artemis via STOMP and listens on fraud.score.queue.
"""

import os
import time
import logging

from pythonjsonlogger import jsonlogger

#
from ddtrace import patch_all
from ddtrace.contrib.logging import patch as patch_logging
patch_all()
patch_logging()

#
import ddtrace.profiling.auto  # noqa: F401  — side-effect import, keep at top

import stomp

from listener import FraudScoreListener

# ── LOGGING SETUP ─────────────────────────────────────────────────────
# Structured JSON logging so that Datadog Log Management can parse
# every field without a custom pipeline processor.
# When ddtrace log injection is enabled (see block above), dd.trace_id
# and dd.span_id are automatically added to every log record.
# ─────────────────────────────────────────────────────────────────────
logger = logging.getLogger("fraud_detection")
logger.setLevel(logging.INFO)

_handler = logging.StreamHandler()
_formatter = jsonlogger.JsonFormatter(
    fmt="%(asctime)s %(levelname)s %(name)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
_handler.setFormatter(_formatter)
logger.addHandler(_handler)


def _broker_host() -> str:
    return os.environ.get("STOMP_HOST", "activemq-artemis")


def _broker_port() -> int:
    return int(os.environ.get("STOMP_PORT", "61613"))


def _queue() -> str:
    return os.environ.get("FRAUD_QUEUE", "fraud.score.queue")


def main() -> None:
    host = _broker_host()
    port = _broker_port()
    queue = _queue()

    logger.info(
        "Starting fraud-detection service",
        extra={
            "broker.host": host,
            "broker.port": port,
            "queue": queue,
            "service": os.environ.get("DD_SERVICE", "fraud-detection"),
            "env": os.environ.get("DD_ENV", "local"),
            "version": os.environ.get("DD_VERSION", "dev"),
        },
    )

    conn = stomp.Connection(host_and_ports=[(host, port)])
    conn.set_listener("fraud_score_listener", FraudScoreListener())

    while True:
        try:
            conn.connect(
                username=os.environ.get("STOMP_USER", "admin"),
                passcode=os.environ.get("STOMP_PASS", "admin"),
                wait=True,
            )
            conn.subscribe(
                destination=f"/queue/{queue}",
                id=1,
                ack="client-individual",
            )
            logger.info("Subscribed to queue", extra={"queue": queue})

            # Block until disconnected, then attempt reconnect.
            while conn.is_connected():
                time.sleep(1)

        except stomp.exception.ConnectFailedException:
            logger.warning(
                "Could not connect to broker — retrying in 5 s",
                extra={"broker.host": host, "broker.port": port},
            )
            time.sleep(5)

        except KeyboardInterrupt:
            logger.info("Shutting down fraud-detection service")
            if conn.is_connected():
                conn.disconnect()
            break


if __name__ == "__main__":
    main()
