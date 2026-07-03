package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/url"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/DataDog/datadog-go/v5/statsd"
	"github.com/DataDog/dd-trace-go/v2/ddtrace/tracer"
	"github.com/DataDog/dd-trace-go/v2/profiler"
	"github.com/go-stomp/stomp/v3"
)

//
//
//

const (
	alertQueue       = "/queue/alert.queue"
	defaultBrokerURL = "stomp://localhost:61613"
)

// AlertMessage represents the payload received on alert.queue.
type AlertMessage struct {
	EventType     string `json:"event_type"` // e.g. "fraud_detected", "payment_failed"
	AccountID     string `json:"account_id"`
	Channel       string `json:"channel"`        // "email" or "sms"
	CorrelationID string `json:"correlation_id"` // jms.correlation_id — business-level trace key
	// ⚠️  HIGH CARDINALITY WARNING: do NOT log or tag raw account numbers, IBANs,
	// card numbers, or transaction amounts. Tag with IDs only.
	// Ref: https://docs.datadoghq.com/tagging/assigning_tags/#defining-tags
}

// statsdClient is created once at startup and reused for the lifetime of the
// process — see the comment in main() for why this matters.
var statsdClient *statsd.Client

func main() {
	// ── Structured JSON logging (stdlib log/slog) ─────────────────────────────
	// All log lines are JSON so Datadog Log Management can parse them without a
	// custom pipeline processor. The "dd.trace_id" and "dd.span_id" fields are
	// injected automatically once APM log correlation is enabled (Step 4).
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))
	slog.SetDefault(logger)

	//
	tracer.Start(
		tracer.WithService(getEnv("DD_SERVICE", "notification-service")),
		tracer.WithEnv(getEnv("DD_ENV", "local")),
		tracer.WithServiceVersion(getEnv("DD_VERSION", "dev")),
		tracer.WithAgentAddr(getEnv("DD_AGENT_HOST", "datadog-agent")+":8126"),
		tracer.WithRuntimeMetrics(),
	)
	defer tracer.Stop()

	//
	if err := profiler.Start(
		profiler.WithService(getEnv("DD_SERVICE", "notification-service")),
		profiler.WithEnv(getEnv("DD_ENV", "local")),
		profiler.WithVersion(getEnv("DD_VERSION", "dev")),
		profiler.WithProfileTypes(
			profiler.CPUProfile,
			profiler.HeapProfile,
			profiler.GoroutineProfile,
		),
	); err != nil {
		slog.Error("profiler failed to start", "error", err)
	}
	defer profiler.Stop()

	// BUG FIX — memory leak: statsd.New(...) used to be called inside
	// sendNotification(), i.e. once per message. Each call opens its own UDP
	// socket and spins up background buffering/flush goroutines that were
	// never closed, so every alert processed leaked a socket + goroutine set.
	// Under continuous traffic this produced a steady, unbounded memory climb
	// (observed: ~14MB -> 250MB+ within ~10 minutes) until the pod hit its
	// memory limit and got OOMKilled. The client is now created exactly once
	// here and reused for the life of the process; see the deferred Close().
	sc, err := statsd.New(getEnv("DD_AGENT_HOST", "datadog-agent") + ":8125")
	if err != nil {
		slog.Error("failed to create statsd client — metrics will be disabled", "error", err)
	} else {
		statsdClient = sc
		defer statsdClient.Close()
	}

	brokerURL := getEnv("ACTIVEMQ_URL", defaultBrokerURL)

	slog.Info("notification-service starting",
		"broker_url", brokerURL,
		"queue", alertQueue,
	)

	conn, err := connectSTOMP(brokerURL)
	if err != nil {
		slog.Error("failed to connect to STOMP broker", "error", err, "broker_url", brokerURL)
		os.Exit(1)
	}
	defer conn.Disconnect()

	slog.Info("connected to STOMP broker", "broker_url", brokerURL)

	sub, err := conn.Subscribe(alertQueue, stomp.AckClient)
	if err != nil {
		slog.Error("failed to subscribe to queue", "queue", alertQueue, "error", err)
		os.Exit(1)
	}

	slog.Info("subscribed to queue", "queue", alertQueue)

	// Graceful shutdown on SIGTERM / SIGINT (important for K8s pod lifecycle).
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	for {
		select {
		case <-ctx.Done():
			slog.Info("shutdown signal received, stopping consumer")
			return
		case msg, ok := <-sub.C:
			if !ok {
				slog.Warn("subscription channel closed, exiting")
				return
			}
			processMessage(conn, msg)
		}
	}
}

// processMessage deserialises the STOMP frame and dispatches to sendNotification.
func processMessage(conn *stomp.Conn, msg *stomp.Message) {
	if msg.Err != nil {
		slog.Error("received error frame from broker", "error", msg.Err)
		return
	}

	var alert AlertMessage
	if err := json.Unmarshal(msg.Body, &alert); err != nil {
		slog.Error("failed to unmarshal alert message",
			"error", err,
			"raw_body_length", len(msg.Body),
		)
		// NACK the message so the broker can redeliver or dead-letter it.
		if nackErr := conn.Nack(msg); nackErr != nil {
			slog.Error("failed to NACK message", "error", nackErr)
		}
		return
	}

	slog.Info("jms.message.process",
		"queue", alertQueue,
		"event_type", alert.EventType,
		"account_id", alert.AccountID,
		"channel", alert.Channel,
		"correlation_id", alert.CorrelationID,
		// dd.trace_id and dd.span_id are injected here automatically
		// once APM log correlation is enabled (Step 4 in README).
	)

	sendNotification(alert)

	if err := conn.Ack(msg); err != nil {
		slog.Error("failed to ACK message", "error", err, "correlation_id", alert.CorrelationID)
	}
}

// sendNotification stubs the email / SMS dispatch logic.
// In production this would call an SMTP relay or SMS gateway API.
func sendNotification(alert AlertMessage) {
	//
	span, _ := tracer.StartSpanFromContext(
		context.Background(), "alert.send",
		tracer.ResourceName(alert.EventType),
		tracer.Tag("notification.channel", alert.Channel),
		tracer.Tag("notification.event_type", alert.EventType),
		tracer.Tag("account.id", alert.AccountID),
		tracer.Tag("jms.correlation_id", alert.CorrelationID),
		tracer.Tag("messaging.destination", "alert.queue"),
	)
	defer span.Finish()

	start := time.Now()

	switch alert.Channel {
	case "email":
		slog.Info("alert.send",
			"channel", "email",
			"event_type", alert.EventType,
			"account_id", alert.AccountID,
			"correlation_id", alert.CorrelationID,
		)
		// TODO: integrate with SMTP relay (e.g. SendGrid, SES)
	case "sms":
		slog.Info("alert.send",
			"channel", "sms",
			"event_type", alert.EventType,
			"account_id", alert.AccountID,
			"correlation_id", alert.CorrelationID,
		)
		// TODO: integrate with SMS gateway (e.g. Twilio, SNS)
	default:
		slog.Warn("alert.send.unknown_channel",
			"channel", alert.Channel,
			"event_type", alert.EventType,
			"correlation_id", alert.CorrelationID,
		)
	}

	duration := time.Since(start).Milliseconds()

	slog.Info("alert.send.complete",
		"channel", alert.Channel,
		"event_type", alert.EventType,
		"duration_ms", duration,
		"correlation_id", alert.CorrelationID,
	)

	// Reuse the process-wide statsd client created once in main() — do NOT
	// create a new client here (see the BUG FIX comment in main() for why).
	if statsdClient != nil {
		statsdClient.Histogram("finance.notification.dispatch_time", float64(duration),
			[]string{"channel:" + alert.Channel, "event_type:" + alert.EventType, "env:" + getEnv("DD_ENV", "local")}, 1.0)
		statsdClient.Incr("finance.notification.sent",
			[]string{"channel:" + alert.Channel, "event_type:" + alert.EventType}, 1.0)
	}
}

// connectSTOMP establishes a STOMP connection to the ActiveMQ Artemis broker.
// Retries with a fixed delay to handle broker startup ordering in Docker Compose.
func connectSTOMP(rawURL string) (*stomp.Conn, error) {
	u, err := url.Parse(rawURL)
	if err != nil {
		return nil, err
	}

	host := u.Host
	var password string
	if u.User != nil {
		password, _ = u.User.Password()
	}
	user := u.User.Username()

	opts := []func(*stomp.Conn) error{
		stomp.ConnOpt.HeartBeat(10*time.Second, 10*time.Second),
	}
	if user != "" {
		opts = append(opts, stomp.ConnOpt.Login(user, password))
	}

	const maxRetries = 10
	for i := range maxRetries {
		conn, dialErr := stomp.Dial("tcp", host, opts...)
		if dialErr == nil {
			return conn, nil
		}
		slog.Warn("STOMP connection failed, retrying",
			"attempt", i+1,
			"max_attempts", maxRetries,
			"error", dialErr,
		)
		time.Sleep(3 * time.Second)
	}

	// Final attempt — return the error directly.
	return stomp.Dial("tcp", host, opts...)
}

// getEnv returns the value of an environment variable or a fallback default.
func getEnv(key, fallback string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return fallback
}
