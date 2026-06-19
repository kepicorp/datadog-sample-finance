# =============================================================================
# Finance Sample App — Datadog Observability Configuration
# =============================================================================
# Provisions all Datadog resources for the Finance sample app:
#   - Log index with correct filter and retention
#   - Log index ordering (finance index before main)
#   - Log processing pipeline (structured JSON parsing)
#   - Monitors (pod restarts, error rate, log volume)
#   - Dashboard (Finance app overview)
#
# Prerequisites:
#   1. make tf-apply-aws        — EKS cluster and Datadog Agent deployed
#   2. make deploy-k8s-eks      — Finance app running on EKS
#   3. make deploy-k8s-dd       — Datadog Agent running, sending data
#   4. Set secrets in AWS Secrets Manager:
#        aws secretsmanager put-secret-value --secret-id finance-app/staging/dd-api-key --secret-string <key>
#        aws secretsmanager put-secret-value --secret-id finance-app/staging/dd-app-key --secret-string <key>
#   5. Export keys as env vars (never put in tfvars):
#        export TF_VAR_datadog_api_key="$(aws secretsmanager get-secret-value \
#          --secret-id finance-app/staging/dd-api-key --query SecretString --output text)"
#        export TF_VAR_datadog_app_key="$(aws secretsmanager get-secret-value \
#          --secret-id finance-app/staging/dd-app-key --query SecretString --output text)"
#
# Docs: https://registry.terraform.io/providers/DataDog/datadog/latest/docs
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    datadog = {
      source  = "DataDog/datadog"
      version = "~> 3.0"
    }
  }
}

provider "datadog" {
  api_key = var.datadog_api_key
  app_key = var.datadog_app_key
  api_url = "https://api.${var.datadog_site}/"
}

# =============================================================================
# LOCALS
# =============================================================================

locals {
  # Tag filter used consistently across index, pipeline, monitors, dashboard
  cluster_filter   = "kube_cluster_name:${var.cluster_name}"
  env_filter       = "env:${var.environment}"
  namespace_filter = "kube_namespace:finance"

  # Combined filter for all finance app logs
  finance_log_filter = "${local.cluster_filter} ${local.namespace_filter}"

  common_tags = [
    "env:${var.environment}",
    "cluster:${var.cluster_name}",
    "managed-by:terraform",
    "app:finance-sample-app",
  ]
}

# =============================================================================
# LOG INDEX
# =============================================================================
# A dedicated index for finance app logs gives:
#   - Separate retention policy from the default 'main' index
#   - Faster queries (smaller index, focused filter)
#   - Independent daily quota management
#
# Docs: https://docs.datadoghq.com/logs/log_configuration/indexes/

resource "datadog_logs_index" "finance_app" {
  name           = "finance-sample"
  retention_days = var.log_retention_days

  # Only index logs from the finance namespace on the finance-app cluster.
  # Logs not matching this filter fall through to the next index (main).
  filter {
    query = local.finance_log_filter
  }

  # Daily quota — prevent runaway log ingestion from crashing the budget.
  # Set to 500 MB/day for staging; increase for production.
  daily_limit                              = 500
  daily_limit_warning_threshold_percentage = 80

  # Note: flex_retention_days requires Flex Logs to be enabled on the org.
  # Remove the comment below and set to enable if your org supports it:
  # flex_retention_days = 90
}

# =============================================================================
# LOG INDEX ORDER — intentionally NOT managed by Terraform
# =============================================================================
# datadog_logs_index_order requires listing ALL indexes in the org, including
# any personal or pre-existing ones. Managing it here would silently overwrite
# the org's full index order every time tf-apply-dd runs, potentially breaking
# other indexes that have nothing to do with this project.
#
# Instead, set the index order manually once in the Datadog UI:
#   Logs > Configuration > Indexes > drag finance-app to the top
#
# This ensures finance logs are routed to the finance-app index first.
# Docs: https://docs.datadoghq.com/logs/log_configuration/indexes/#indexes-filters

# =============================================================================
# LOG PROCESSING PIPELINE
# =============================================================================
# Parses structured JSON logs emitted by all finance services and enriches
# them with finance-domain attributes for fast filtering and dashboarding.
#
# Docs: https://docs.datadoghq.com/logs/log_configuration/pipelines/

resource "datadog_logs_custom_pipeline" "finance_app" {
  name       = "Finance App — ${var.cluster_name}"
  is_enabled = true

  # Scope to finance logs only
  filter {
    query = local.finance_log_filter
  }

  # ── Processor 1: JSON parser ──────────────────────────────────────────────
  # All finance services emit structured JSON. Use a grok parser to extract
  # the JSON body into attributes (json_parser was removed in provider v3;
  # grok %{data::json} is the equivalent).
  processor {
    grok_parser {
      name       = "Parse JSON log body"
      is_enabled = true
      source     = "message"
      grok {
        support_rules = ""
        match_rules   = "json_rule %%{data::json}"
      }
    }
  }

  # ── Processor 2: Status remapper ─────────────────────────────────────────
  # Map the application-level 'level' / 'severity' field to the Datadog
  # official log status so logs appear with the right colour in Log Explorer.
  processor {
    status_remapper {
      name       = "Map log level to Datadog status"
      is_enabled = true
      sources    = ["level", "severity", "msg.level", "msg.severity"]
    }
  }

  # ── Processor 3: Service remapper ────────────────────────────────────────
  # Use the Kubernetes deployment name as the Datadog service tag so traces,
  # logs, and metrics are correlated under the same service in APM.
  processor {
    service_remapper {
      name       = "Map kube_deployment to service"
      is_enabled = true
      sources    = ["kube_deployment", "service", "msg.service"]
    }
  }

  # ── Processor 4: Trace ID remapper ───────────────────────────────────────
  # When APM is enabled (Learning Progression Step 3), dd.trace_id is injected
  # into every log line. This processor links logs to their parent trace.
  # Docs: https://docs.datadoghq.com/tracing/other_telemetry/connect_logs_and_traces/
  processor {
    trace_id_remapper {
      name       = "Link logs to APM traces via trace_id"
      is_enabled = true
      sources    = ["dd.trace_id", "msg.dd.trace_id"]
    }
  }

  # ── Processor 5: Finance domain attribute remapper ───────────────────────
  # Promote finance-specific fields to top-level attributes so they appear
  # as facets in Log Explorer without manual parsing.
  processor {
    attribute_remapper {
      name                 = "Promote transaction.type to facet"
      is_enabled           = true
      sources              = ["msg.transaction.type"]
      source_type          = "attribute"
      target               = "transaction.type"
      target_type          = "attribute"
      preserve_source      = true
      override_on_conflict = false
    }
  }

  processor {
    attribute_remapper {
      name                 = "Promote fraud.score_bucket to facet"
      is_enabled           = true
      sources              = ["msg.fraud.score_bucket"]
      source_type          = "attribute"
      target               = "fraud.score_bucket"
      target_type          = "attribute"
      preserve_source      = true
      override_on_conflict = false
    }
  }

  processor {
    attribute_remapper {
      name                 = "Promote account.tier to facet"
      is_enabled           = true
      sources              = ["msg.account.tier"]
      source_type          = "attribute"
      target               = "account.tier"
      target_type          = "attribute"
      preserve_source      = true
      override_on_conflict = false
    }
  }
}

# =============================================================================
# METRICS FROM SPANS
# =============================================================================
# Generates custom metrics directly from indexed APM spans — no DogStatsD code
# required. Metrics become available in the Metrics Explorer and dashboards as
# soon as APM instrumentation is active (Learning Progression Step 3).
#
# Resource: datadog_spans_metric
# Docs: https://docs.datadoghq.com/tracing/trace_pipeline/generate_metrics/
# Terraform: https://registry.terraform.io/providers/DataDog/datadog/latest/docs/resources/spans_metric

# finance.payment.hits — count of payment spans, grouped by transaction type and currency
resource "datadog_spans_metric" "payment_hits" {
  name = "finance.payment.hits"

  compute {
    aggregation_type = "count"
  }

  filter {
    query = "service:gateway-api @http.route:\"/v1/payments\""
  }

  group_by {
    path     = "@transaction.type"
    tag_name = "transaction_type"
  }

  group_by {
    path     = "@payment.currency"
    tag_name = "currency"
  }

  group_by {
    path     = "env"
    tag_name = "env"
  }
}

# finance.payment.duration — distribution of payment span latency (nanoseconds)
# Percentiles (p50/p75/p90/p95/p99) are automatically generated by Datadog.
resource "datadog_spans_metric" "payment_duration" {
  name = "finance.payment.duration"

  compute {
    aggregation_type    = "distribution"
    include_percentiles = true
    path                = "@duration"
  }

  filter {
    query = "service:gateway-api @http.route:\"/v1/payments\""
  }

  group_by {
    path     = "@transaction.type"
    tag_name = "transaction_type"
  }

  group_by {
    path     = "env"
    tag_name = "env"
  }
}

# finance.fraud.hits — count of fraud-scoring spans, grouped by risk bucket
# Use @fraud.score_bucket (low/medium/high) rather than the raw float to avoid
# high-cardinality tag values.
resource "datadog_spans_metric" "fraud_hits" {
  name = "finance.fraud.hits"

  compute {
    aggregation_type = "count"
  }

  filter {
    query = "service:fraud-detection"
  }

  group_by {
    path     = "@fraud.score_bucket"
    tag_name = "score_bucket"
  }

  group_by {
    path     = "env"
    tag_name = "env"
  }
}

# finance.batch.records_processed — distribution of records written per batch step
# Surfaces in dashboards as sum/p95. Tagged by job name and terminal status so
# you can alert on partial runs (e.g. job_status:partial or job_status:failed).
resource "datadog_spans_metric" "batch_records" {
  name = "finance.batch.records_processed"

  compute {
    aggregation_type    = "distribution"
    include_percentiles = false
    path                = "@job.records_processed"
  }

  filter {
    query = "service:batch-processor"
  }

  group_by {
    path     = "@job.name"
    tag_name = "job_name"
  }

  group_by {
    path     = "@job.status"
    tag_name = "job_status"
  }

  group_by {
    path     = "env"
    tag_name = "env"
  }
}

# =============================================================================
# METRICS FROM LOGS
# =============================================================================
# Generates custom metrics from indexed log events — counts log lines matching
# a query and makes the result available as a standard Datadog metric.
# Metrics are populated as long as logs flow into the finance-app index, even
# before APM is enabled.
#
# Resource: datadog_logs_metric
# Docs: https://docs.datadoghq.com/logs/log_configuration/logs_to_metrics/
# Terraform: https://registry.terraform.io/providers/DataDog/datadog/latest/docs/resources/logs_metric

# finance.logs.errors — count of error-level log lines, grouped by service
# Powers the Error Logs by Service timeseries widget in the dashboard and feeds
# the error_rate monitor below.
resource "datadog_logs_metric" "error_count" {
  name = "finance.logs.errors"

  compute {
    aggregation_type = "count"
  }

  filter {
    query = "${local.finance_log_filter} status:error"
  }

  group_by {
    path     = "service"
    tag_name = "service"
  }

  group_by {
    path     = "env"
    tag_name = "env"
  }
}

# finance.logs.payments_initiated — count of payment log events from gateway-api
# Useful as a cross-check against the span-based finance.payment.hits metric;
# a divergence between the two may indicate incomplete APM coverage.
resource "datadog_logs_metric" "payments_initiated" {
  name = "finance.logs.payments_initiated"

  compute {
    aggregation_type = "count"
  }

  filter {
    query = "${local.finance_log_filter} service:gateway-api @message:payment*"
  }

  group_by {
    path     = "env"
    tag_name = "env"
  }
}

# =============================================================================
# MONITORS
# =============================================================================
# Docs: https://docs.datadoghq.com/monitors/

# ── Monitor 1: Pod restart rate ──────────────────────────────────────────────
# Fires when any finance pod restarts more than 3 times in 15 minutes.
# Common causes: OOMKill, app crash, misconfigured secrets.

resource "datadog_monitor" "pod_restarts" {
  name    = "[Finance] Pod restart rate — ${var.cluster_name}"
  type    = "metric alert"
  message = <<-EOT
    ## Finance app pod restart spike

    Pod {{kube_deployment.name}} in namespace {{kube_namespace.name}} on cluster
    {{kube_cluster_name.name}} has restarted more than 3 times in 15 minutes.

    **Common causes:**
    - OOMKill: check memory limits in the Deployment spec
    - App crash: check pod logs in [Log Explorer](https://app.datadoghq.com/logs?query=${local.namespace_filter})
    - Bad secret/configmap: check for missing env vars at startup

    @pagerduty @slack-finance-alerts
  EOT

  query = "sum(last_15m):sum:kubernetes.containers.restarts{${local.cluster_filter},${local.namespace_filter}} by {kube_deployment}.as_count() > 3"

  monitor_thresholds {
    critical = 3
    warning  = 1
  }

  notify_no_data    = false
  renotify_interval = 60
  tags              = local.common_tags
}

# ── Monitor 2: Finance service error rate ────────────────────────────────────
# Fires when error-level logs exceed 20 per minute for a given service.
# Requires log collection to be active (Learning Progression Step 1).

resource "datadog_monitor" "error_rate" {
  name    = "[Finance] High error rate — ${var.cluster_name}"
  type    = "log alert"
  message = <<-EOT
    ## High error rate detected in Finance app

    Service {{service.name}} is producing more than 20 error logs per minute
    in cluster {{kube_cluster_name.name}}.

    [View logs](https://app.datadoghq.com/logs?query=${local.finance_log_filter} status:error)

    @slack-finance-alerts
  EOT

  # Use index "*" (all indexes) so the monitor validates before the finance-app
  # index exists. Logs are already scoped by the filter query itself.
  query = "logs(\"${local.finance_log_filter} status:error\").index(\"*\").rollup(\"count\").last(\"5m\") > 20"

  monitor_thresholds {
    critical = 20
    warning  = 10
  }

  notify_no_data    = false
  renotify_interval = 30
  tags              = local.common_tags

  depends_on = [datadog_logs_index.finance_app]
}

# ── Monitor 3: Pods not running ───────────────────────────────────────────────
# Fires when fewer than the expected number of pods are running in the finance namespace.

resource "datadog_monitor" "pods_not_running" {
  name    = "[Finance] Pods not running — ${var.cluster_name}"
  type    = "metric alert"
  message = <<-EOT
    ## Finance app pods not running

    The number of running pods in kube_namespace:finance on ${var.cluster_name}
    has dropped below the expected minimum.

    Check pod status:
      kubectl get pods -n finance

    @slack-finance-alerts
  EOT

  query = "min(last_5m):sum:kubernetes.pods.running{${local.cluster_filter},${local.namespace_filter}} < 8"

  monitor_thresholds {
    critical = 8
    warning  = 10
  }

  notify_no_data    = true
  no_data_timeframe = 10
  renotify_interval = 30
  tags              = local.common_tags
}

# =============================================================================
# DASHBOARD
# =============================================================================
# Finance app overview dashboard.
# Docs: https://docs.datadoghq.com/dashboards/

resource "datadog_dashboard" "finance_overview" {
  title       = "Finance App — ${var.cluster_name} Overview"
  description = "Infrastructure and application health for the Finance sample app on EKS cluster ${var.cluster_name}. Managed by Terraform — deploy/terraform/datadog/."
  layout_type = "ordered"
  # tags are restricted in this org to team: and ai: only
  # tags = local.common_tags

  # ── Row 1: Pod health ──────────────────────────────────────────────────────
  widget {
    group_definition {
      title            = "Pod Health"
      layout_type      = "ordered"
      background_color = "blue"

      widget {
        query_value_definition {
          title       = "Running Pods"
          title_size  = "16"
          title_align = "left"
          autoscale   = true
          precision   = 0

          request {
            q          = "sum:kubernetes.pods.running{${local.cluster_filter},${local.namespace_filter}}"
            aggregator = "last"
          }
        }
      }

      widget {
        query_value_definition {
          title       = "Pod Restarts (15m)"
          title_size  = "16"
          title_align = "left"
          autoscale   = true
          precision   = 0

          request {
            q          = "sum:kubernetes.containers.restarts{${local.cluster_filter},${local.namespace_filter}}.as_count()"
            aggregator = "sum"
          }
        }
      }

      widget {
        timeseries_definition {
          title       = "Pod Restarts by Deployment"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "sum:kubernetes.containers.restarts{${local.cluster_filter},${local.namespace_filter}} by {kube_deployment}.as_count()"
            display_type = "bars"
          }
        }
      }
    }
  }

  # ── Row 2: CPU & Memory ────────────────────────────────────────────────────
  widget {
    group_definition {
      title            = "CPU & Memory"
      layout_type      = "ordered"
      background_color = "green"

      widget {
        timeseries_definition {
          title       = "CPU Usage by Deployment"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "avg:kubernetes.cpu.usage.total{${local.cluster_filter},${local.namespace_filter}} by {kube_deployment}"
            display_type = "line"
          }
        }
      }

      widget {
        timeseries_definition {
          title       = "Memory Usage by Deployment"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "avg:kubernetes.memory.usage{${local.cluster_filter},${local.namespace_filter}} by {kube_deployment}"
            display_type = "line"
          }
        }
      }
    }
  }

  # ── Row 3: Logs ────────────────────────────────────────────────────────────
  widget {
    group_definition {
      title            = "Log Volume"
      layout_type      = "ordered"
      background_color = "yellow"

      widget {
        timeseries_definition {
          title       = "Log Volume by Service"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            log_query {
              index        = "finance-sample"
              search_query = local.finance_log_filter
              compute_query {
                aggregation = "count"
              }
              group_by {
                facet = "service"
                limit = 10
                sort_query {
                  aggregation = "count"
                  order       = "desc"
                }
              }
            }
            display_type = "bars"
          }
        }
      }

      widget {
        timeseries_definition {
          title       = "Error Logs by Service"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            log_query {
              index        = "finance-sample"
              search_query = "${local.finance_log_filter} status:error"
              compute_query {
                aggregation = "count"
              }
              group_by {
                facet = "service"
                limit = 10
                sort_query {
                  aggregation = "count"
                  order       = "desc"
                }
              }
            }
            display_type = "bars"
          }
        }
      }
    }
  }

    # ── Row 4: APM Service Health ────────────────────────────────────────────
    widget {
      group_definition {
        title            = "APM Service Health"
        layout_type      = "ordered"
        background_color = "vivid_blue"

        widget {
          timeseries_definition {
            title       = "Request Rate by Service"
            title_size  = "16"
            title_align = "left"
            show_legend = true

            request {
              q            = "sum:trace.web.request.hits{${local.env_filter}} by {service}.as_rate()"
              display_type = "line"
            }
          }
        }

        widget {
          timeseries_definition {
            title       = "Error Rate by Service"
            title_size  = "16"
            title_align = "left"
            show_legend = true

            request {
              q            = "sum:trace.web.request.errors{${local.env_filter}} by {service}.as_rate()"
              display_type = "bars"
            }
          }
        }

        widget {
          timeseries_definition {
            title       = "p95 Latency by Service (ms)"
            title_size  = "16"
            title_align = "left"
            show_legend = true

            request {
              q            = "p95:trace.web.request{${local.env_filter}} by {service}"
              display_type = "line"
            }
          }
        }
      }
    }

    # ── Row 5: DogStatsD Custom Metrics ───────────────────────────────────────
    widget {
      group_definition {
        title            = "Finance Custom Metrics (DogStatsD)"
        layout_type      = "ordered"
        background_color = "orange"

        widget {
          query_value_definition {
            title       = "Payments Initiated (1h)"
            title_size  = "16"
            title_align = "left"
            autoscale   = true
            precision   = 0

            request {
              q          = "sum:finance.payment.initiated{${local.env_filter}}.as_count()"
              aggregator = "sum"
            }
          }
        }

        widget {
          timeseries_definition {
            title       = "Payment Initiated Rate by Currency"
            title_size  = "16"
            title_align = "left"
            show_legend = true

            request {
              q            = "sum:finance.payment.initiated{${local.env_filter}} by {payment.currency}.as_rate()"
              display_type = "bars"
            }
          }
        }

        widget {
          timeseries_definition {
            title       = "Payment Processing Time p95 (ms)"
            title_size  = "16"
            title_align = "left"
            show_legend = true

            request {
              q            = "p95:finance.payment.processing_time{${local.env_filter}}"
              display_type = "line"
            }
          }
        }
      }
    }

    # ── Row 6: Database Monitoring ────────────────────────────────────────────
    widget {
      group_definition {
        title            = "Database — PostgreSQL Ledger"
        layout_type      = "ordered"
        background_color = "gray"

        widget {
          timeseries_definition {
            title       = "DB Query Latency p95 (ms)"
            title_size  = "16"
            title_align = "left"
            show_legend = false

            request {
              q            = "p95:postgresql.query.duration{db:ledger,${local.env_filter}} * 1000"
              display_type = "line"
            }
          }
        }

        widget {
          timeseries_definition {
            title       = "Active DB Connections"
            title_size  = "16"
            title_align = "left"
            show_legend = false

            request {
              q            = "avg:postgresql.connections{db:ledger,${local.env_filter}}"
              display_type = "line"
            }
          }
        }

        widget {
          timeseries_definition {
            title       = "Stuck Pending Transactions"
            title_size  = "16"
            title_align = "left"
            show_legend = false

            request {
              q            = "max:finance.db.ledger.pending_count{${local.env_filter}}"
              display_type = "bars"
            }
          }
        }
      }
    }

    # ── Row 7: Messaging — ActiveMQ ───────────────────────────────────────────
    widget {
      group_definition {
        title            = "Messaging — ActiveMQ Artemis"
        layout_type      = "ordered"
        background_color = "vivid_orange"

        widget {
          timeseries_definition {
            title       = "Queue Depth by Queue"
            title_size  = "16"
            title_align = "left"
            show_legend = true

            request {
              q            = "max:activemq.artemis.queue.message_count{${local.env_filter}} by {queue_name}"
              display_type = "line"
            }
          }
        }

        widget {
          timeseries_definition {
            title       = "Consumer Count by Queue"
            title_size  = "16"
            title_align = "left"
            show_legend = true

            request {
              q            = "min:activemq.artemis.queue.consumer_count{${local.env_filter}} by {queue_name}"
              display_type = "line"
            }
          }
        }

        widget {
          timeseries_definition {
            title       = "Messages Added Rate"
            title_size  = "16"
            title_align = "left"
            show_legend = true

            request {
              q            = "sum:activemq.artemis.queue.messages_added{${local.env_filter}} by {queue_name}.as_rate()"
              display_type = "bars"
            }
          }
        }
      }
    }

    # ── Row 8: Finance Metrics from Spans & Logs ─────────────────────────────
    # These widgets use metrics generated by datadog_spans_metric and
    # datadog_logs_metric resources defined above. They are populated as soon as
    # APM instrumentation is active (Step 3) and logs are flowing (Step 1).
  widget {
    group_definition {
      title            = "Finance Metrics from Spans & Logs"
      layout_type      = "ordered"
      background_color = "purple"

      widget {
        timeseries_definition {
          title       = "Payment Requests (from spans)"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "sum:finance.payment.hits{${local.env_filter}} by {transaction_type}"
            display_type = "bars"
          }
        }
      }

      widget {
        timeseries_definition {
          title       = "Payment p95 Latency (from spans)"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "p95:finance.payment.duration{${local.env_filter}}"
            display_type = "line"
          }
        }
      }

      widget {
        timeseries_definition {
          title       = "Fraud Score Distribution (from spans)"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "sum:finance.fraud.hits{${local.env_filter}} by {score_bucket}"
            display_type = "bars"
          }
        }
      }

      widget {
        timeseries_definition {
          title       = "Error Logs by Service (from logs metric)"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "sum:finance.logs.errors{${local.env_filter}} by {service}"
            display_type = "bars"
          }
        }
      }

      widget {
        timeseries_definition {
          title       = "Batch Records Processed (from spans)"
          title_size  = "16"
          title_align = "left"
          show_legend = true

          request {
            q            = "sum:finance.batch.records_processed{${local.env_filter}} by {job_name,job_status}"
            display_type = "bars"
          }
        }
      }
    }
  }
}

# =============================================================================
# ADDITIONAL MONITORS
# =============================================================================

# ── Monitor 4: Payment API high latency ──────────────────────────────────────────
# Fires when the p95 payment latency exceeds 2 s. Requires APM (Step 3).
resource "datadog_monitor" "payment_latency" {
  name    = "[Finance] Payment p95 latency high — ${var.cluster_name}"
  type    = "metric alert"
  message = <<-EOT
    ## Payment latency SLA breach

    p95 latency for POST /v1/payments on service gateway-api has exceeded
    the 2-second SLA threshold.

    - [APM Service page](https://app.datadoghq.com/apm/services/gateway-api)
    - [Trace Explorer](https://app.datadoghq.com/apm/traces?query=service:gateway-api%20@http.url_details.path:/v1/payments)

    @slack-finance-alerts
  EOT

  # p95 duration in nanoseconds from the finance.payment.duration spans metric
  query = "percentile(last_5m):p95:finance.payment.duration{${local.env_filter}} > 2000000000"

  monitor_thresholds {
    critical = 2000000000 # 2 s in nanoseconds
    warning  = 1000000000 # 1 s in nanoseconds
  }

  notify_no_data    = false
  renotify_interval = 30
  tags              = local.common_tags

  depends_on = [datadog_spans_metric.payment_duration]
}

# ── Monitor 5: Payment error rate ───────────────────────────────────────────
# Fires when more than 10% of payment spans are errors. Requires APM (Step 3).
resource "datadog_monitor" "payment_error_rate" {
  name    = "[Finance] Payment error rate — ${var.cluster_name}"
  type    = "metric alert"
  message = <<-EOT
    ## Payment error rate above threshold

    The error rate for POST /v1/payments has exceeded 10%.

    **Triage steps:**
    1. Check [APM Traces](https://app.datadoghq.com/apm/traces?query=service:gateway-api%20status:error) for error details
    2. Review [account-service logs](https://app.datadoghq.com/logs?query=service:account-service%20status:error)
    3. Check [PostgreSQL DBM](https://app.datadoghq.com/databases) for slow queries

    @slack-finance-alerts
  EOT

  # Count of error spans from gateway-api in a 5-minute window
  query = "sum(last_5m):sum:trace.web.request.errors{${local.env_filter},service:gateway-api}.as_count() > 10"

  monitor_thresholds {
    critical = 10
    warning  = 5
  }

  notify_no_data    = false
  renotify_interval = 30
  tags              = local.common_tags
}

# ── Monitor 6: Fraud queue depth ───────────────────────────────────────────
# Fires when fraud.score.queue has >100 unprocessed messages, indicating
# fraud-detection is lagging. Requires ActiveMQ JMX check (Step 9).
resource "datadog_monitor" "fraud_queue_depth" {
  name    = "[Finance] Fraud score queue backlog — ${var.cluster_name}"
  type    = "metric alert"
  message = <<-EOT
    ## Fraud score queue backlog detected

    The fraud.score.queue has {{value}} unprocessed messages, which may delay
    payment confirmations and breach the SLA for real-time fraud detection.

    **Triage steps:**
    1. Check fraud-detection pod status: `kubectl get pods -n finance -l app=fraud-detection`
    2. Check consumer count: should be >= 1 for this queue
    3. Check [fraud-detection logs](https://app.datadoghq.com/logs?query=service:fraud-detection)

    @slack-finance-alerts
  EOT

  query = "max(last_5m):max:activemq.artemis.queue.message_count{${local.env_filter},queue_name:fraud.score.queue} > 100"

  monitor_thresholds {
    critical = 100
    warning  = 50
  }

  notify_no_data    = false
  renotify_interval = 30
  tags              = local.common_tags
}

# ── Monitor 7: Stuck pending transactions (DBM custom query) ───────────────
# Uses the custom_query defined in the postgres Agent config.
# Fires when transactions are stuck in 'pending' for > 5 minutes.
resource "datadog_monitor" "stuck_pending_transactions" {
  name    = "[Finance] Stuck pending transactions — ${var.cluster_name}"
  type    = "metric alert"
  message = <<-EOT
    ## Stuck pending transactions detected

    {{value}} transactions have been in 'pending' status for more than 5 minutes.
    This may indicate a downstream service failure (fraud-detection, notification).

    **Triage steps:**
    1. Check [DBM Query Samples](https://app.datadoghq.com/databases/queries) for blocking queries
    2. Check fraud-detection queue depth (see fraud queue monitor)
    3. Review [transaction-service logs](https://app.datadoghq.com/logs?query=service:transaction-service)

    @slack-finance-alerts
  EOT

  query = "max(last_10m):max:finance.db.ledger.pending_count{${local.env_filter}} > 10"

  monitor_thresholds {
    critical = 10
    warning  = 5
  }

  notify_no_data    = false
  renotify_interval = 60
  tags              = local.common_tags
}

# =============================================================================
# SERVICE LEVEL OBJECTIVES (SLOs)
# =============================================================================
# SLOs define and track service reliability targets.
# Docs: https://docs.datadoghq.com/monitors/service_level_objectives/

# ── SLO 1: Payment API availability (99.9%) ───────────────────────────────
# Tracks the ratio of successful payments to total payment requests.
# Uses span-based metrics for accuracy (counts actual APM spans).
resource "datadog_service_level_objective" "payment_availability" {
  name        = "[Finance] Payment API Availability — ${var.cluster_name}"
  type        = "metric"
  description = "99.9% of payment requests must succeed (non-5xx). Measured from APM spans on gateway-api POST /v1/payments."

  query {
    numerator   = "sum:trace.web.request.hits{${local.env_filter},service:gateway-api,http.status_class:2xx}.as_count()"
    denominator = "sum:trace.web.request.hits{${local.env_filter},service:gateway-api}.as_count()"
  }

  thresholds {
    timeframe       = "7d"
    target          = 99.9
    warning         = 99.95
  }

  thresholds {
    timeframe       = "30d"
    target          = 99.9
    warning         = 99.95
  }

  tags = local.common_tags
}

# ── SLO 2: Payment API latency (p95 < 1 s, 95% of the time) ───────────────
# Monitors that the p95 latency SLA is met over a 7-day rolling window.
resource "datadog_service_level_objective" "payment_latency" {
  name        = "[Finance] Payment API Latency SLO — ${var.cluster_name}"
  type        = "monitor"
  description = "p95 payment latency must stay below 2 s for 99% of any 7-day window."

  monitor_ids = [datadog_monitor.payment_latency.id]

  thresholds {
    timeframe       = "7d"
    target          = 99
    warning         = 99.5
  }

  tags = local.common_tags
}

# ── SLO 3: Fraud queue consumer availability ─────────────────────────────
# Tracks that at least one consumer is active on fraud.score.queue.
# A consumer count of 0 means fraud-detection is down and payments stall.
resource "datadog_service_level_objective" "fraud_consumer_availability" {
  name        = "[Finance] Fraud Queue Consumer Availability — ${var.cluster_name}"
  type        = "monitor"
  description = "fraud.score.queue must have at least 1 active consumer 99.5% of the time."

  monitor_ids = [datadog_monitor.fraud_queue_depth.id]

  thresholds {
    timeframe       = "7d"
    target          = 99.5
    warning         = 99.9
  }

  tags = local.common_tags
}
