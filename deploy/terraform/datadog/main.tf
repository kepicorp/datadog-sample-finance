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
  name           = "finance-app"
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
              index        = "finance-app"
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
              index        = "finance-app"
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

  # ── Row 4: APM (placeholder — activates when instrumentation is enabled) ──
  widget {
    group_definition {
      title            = "APM — Traces (activate Step 3 of Learning Progression)"
      layout_type      = "ordered"
      background_color = "gray"

      widget {
        note_definition {
          content          = "## APM traces will appear here after completing **Step 3** of the Learning Progression.\n\nUncomment the APM initialisation block in each service and redeploy.\n\nDocs: https://docs.datadoghq.com/tracing/trace_collection/"
          background_color = "gray"
          font_size        = "14"
          text_align       = "left"
          show_tick        = false
          tick_pos         = "50%"
          tick_edge        = "left"
        }
      }
    }
  }
}
