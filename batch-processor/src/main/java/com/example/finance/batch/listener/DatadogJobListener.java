package com.example.finance.batch.listener;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.batch.core.JobExecution;
import org.springframework.batch.core.JobExecutionListener;
import org.springframework.batch.core.StepExecution;
import org.springframework.stereotype.Component;

// ── DATADOG INSTRUMENTATION ───────────────────────────────────────────────────
// Uncomment the block below to inject Finance-domain span tags into every
// Spring Batch job execution trace, enabling Data Jobs Monitoring.
//
// Requires:
//   - dd-java-agent.jar attached via -javaagent (see Dockerfile / .env.example)
//   - DD_DATA_JOBS_ENABLED=true  OR  -Ddd.data.jobs.enabled=true
//   - dd-trace-api on the classpath (see build.gradle)
//
// Add to build.gradle:
//   implementation 'com.datadoghq:dd-trace-api:1.+'
//
// Docs: https://docs.datadoghq.com/data_jobs/java/
// Docs: https://docs.datadoghq.com/tracing/trace_collection/custom_instrumentation/java/
//
// import datadog.trace.api.GlobalTracer;
// import io.opentracing.Span;
// import io.opentracing.Tracer;
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Spring Batch {@link JobExecutionListener} that:
 * <ul>
 *   <li><b>Active (always on):</b> emits structured JSON log events at job
 *       start and completion for Log Management correlation.</li>
 *   <li><b>Commented out:</b> injects Datadog Finance-domain span tags for
 *       Data Jobs Monitoring and APM trace correlation.</li>
 * </ul>
 *
 * <p>Register this listener on each {@link org.springframework.batch.core.Job}
 * bean via {@code .listener(datadogJobListener)} in the job builder chain.
 */
@Component
public class DatadogJobListener implements JobExecutionListener {

    private static final Logger log = LoggerFactory.getLogger(DatadogJobListener.class);

    // ── BEFORE JOB ────────────────────────────────────────────────────────────

    @Override
    public void beforeJob(JobExecution jobExecution) {
        String jobName = jobExecution.getJobInstance().getJobName();
        Long jobId = jobExecution.getJobId();

        // ── Active: structured log at job start (always enabled) ──────────────
        log.info("Batch job starting job.name={} job.id={} job.parameters={}",
                jobName,
                jobId,
                jobExecution.getJobParameters());

        // ── DATADOG INSTRUMENTATION ───────────────────────────────────────────
        // Uncomment the block below to inject span tags before the job starts.
        // These tags appear in:
        //   - APM > Services > batch-processor > Traces
        //   - Data Jobs Monitoring > Jobs > [job name] > Run history
        //
        // Finance-domain tags applied here:
        //   job.name    → identifies the job in Data Jobs Monitoring dashboards
        //   job.id      → links this run to the Spring Batch JobInstance
        //   job.env     → maps to DD_ENV for environment filtering
        //
        // ⚠ HIGH-CARDINALITY: job.id is numeric and bounded by your retention
        // period — safe to use. Never tag with raw transaction.id or account.id.
        //
        // Tracer tracer = GlobalTracer.get();
        // Span span = tracer.activeSpan();
        // if (span != null) {
        //     span.setTag("job.name", jobName);
        //     span.setTag("job.id", jobId != null ? jobId.toString() : "unknown");
        //     span.setTag("job.env", System.getenv().getOrDefault("DD_ENV", "local"));
        //     // Finance-specific: tag with the run date parameter when present
        //     String runDate = jobExecution.getJobParameters().getString("run.date");
        //     if (runDate != null) {
        //         span.setTag("job.run_date", runDate);
        //     }
        //     String statementPeriod = jobExecution.getJobParameters().getString("statement.period");
        //     if (statementPeriod != null) {
        //         span.setTag("job.statement_period", statementPeriod);
        //     }
        // }
        // ─────────────────────────────────────────────────────────────────────
    }

    // ── AFTER JOB ─────────────────────────────────────────────────────────────

    @Override
    public void afterJob(JobExecution jobExecution) {
        String jobName = jobExecution.getJobInstance().getJobName();
        String status = jobExecution.getStatus().toString();

        // Sum write counts across all steps to get total records processed.
        // This mirrors what Data Jobs Monitoring surfaces as "records_processed".
        long totalRecordsProcessed = jobExecution.getStepExecutions().stream()
                .mapToLong(StepExecution::getWriteCount)
                .sum();

        long totalReadCount = jobExecution.getStepExecutions().stream()
                .mapToLong(StepExecution::getReadCount)
                .sum();

        long totalSkipCount = jobExecution.getStepExecutions().stream()
                .mapToLong(step -> step.getReadSkipCount()
                        + step.getProcessSkipCount()
                        + step.getWriteSkipCount())
                .sum();

        // ── Active: structured log at job completion (always enabled) ─────────
        log.info("Batch job completed job.name={} job.status={} records.read={} records.written={} records.skipped={}",
                jobName,
                status,
                totalReadCount,
                totalRecordsProcessed,
                totalSkipCount);

        if (jobExecution.getStatus().isUnsuccessful()) {
            jobExecution.getAllFailureExceptions().forEach(ex ->
                    log.error("Batch job failure job.name={} error={}",
                            jobName, ex.getMessage(), ex));
        }

        // ── DATADOG INSTRUMENTATION ───────────────────────────────────────────
        // Uncomment the block below to inject outcome span tags after the job.
        // These tags power:
        //   - Data Jobs Monitoring alerts (e.g. alert when job.status = FAILED)
        //   - Monitors on job.records_processed < threshold (partial run detection)
        //   - Deployment Tracking: correlate failed runs with DD_VERSION
        //
        // Finance-domain tags applied here:
        //   job.status            → "COMPLETED" | "FAILED" | "STOPPED" (BatchStatus)
        //   job.records_processed → total write count — alert when below SLA threshold
        //   job.skip_count        → flag unexpectedly high skip rates
        //
        // Tracer tracer = GlobalTracer.get();
        // Span span = tracer.activeSpan();
        // if (span != null) {
        //     span.setTag("job.status", status);
        //     span.setTag("job.records_processed", totalRecordsProcessed);
        //     span.setTag("job.read_count", totalReadCount);
        //     span.setTag("job.skip_count", totalSkipCount);
        //
        //     // Mark the span as an error if the job failed — surfaces in APM error tracking
        //     if (jobExecution.getStatus().isUnsuccessful()) {
        //         span.setTag("error", true);
        //         jobExecution.getAllFailureExceptions().stream().findFirst().ifPresent(ex -> {
        //             span.setTag("error.type", ex.getClass().getName());
        //             span.setTag("error.message", ex.getMessage());
        //         });
        //     }
        // }
        //
        // ── CUSTOM METRIC: batch records processed ────────────────────────────
        // Emit a DogStatsD counter so you can build dashboards and monitors
        // without relying solely on trace data.
        // Requires: DD_DOGSTATSD_PORT=8125 and statsd client on classpath.
        // Metric name: finance.batch.records_processed
        // Docs: https://docs.datadoghq.com/developers/dogstatsd/
        //
        // import com.timgroup.statsd.NonBlockingStatsDClientBuilder;
        // import com.timgroup.statsd.StatsDClient;
        //
        // StatsDClient statsd = new NonBlockingStatsDClientBuilder()
        //     .prefix("finance")
        //     .hostname(System.getenv().getOrDefault("DD_AGENT_HOST", "localhost"))
        //     .port(8125)
        //     .build();
        // statsd.count("batch.records_processed", totalRecordsProcessed,
        //     "job.name:" + jobName,
        //     "job.status:" + status,
        //     "env:" + System.getenv().getOrDefault("DD_ENV", "local"));
        // ─────────────────────────────────────────────────────────────────────
    }
}
