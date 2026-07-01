package com.example.finance.batch.listener;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.batch.core.JobExecution;
import org.springframework.batch.core.JobExecutionListener;
import org.springframework.batch.core.StepExecution;
import org.springframework.stereotype.Component;

// ── DATADOG INSTRUMENTATION — APM imports ────────────────────────────────────
// Uncomment when enabling manual span tagging in DatadogJobListener.
// Requires: compileOnly 'io.opentracing:opentracing-api:0.33.0'
//           compileOnly 'io.opentracing:opentracing-util:0.33.0'  (see build.gradle)
//
// import io.opentracing.Span;
// import io.opentracing.Tracer;
// import io.opentracing.util.GlobalTracer;
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

        // ── DATADOG INSTRUMENTATION — APM span tags (beforeJob) ──────────────────────────
        // Uncomment to tag the active span with job identity at start.
        // Requires opentracing imports (see import block above).
        //
        // Tracer tracer = GlobalTracer.get();
        // Span span = tracer.activeSpan();
        // if (span != null) {
        //     span.setTag("job.name", jobName);
        //     span.setTag("job.id", jobId != null ? jobId.toString() : "unknown");
        //     span.setTag("job.env", System.getenv().getOrDefault("DD_ENV", "local"));
        //     String runDate = jobExecution.getJobParameters().getString("run.date");
        //     if (runDate != null) { span.setTag("job.run_date", runDate); }
        //     String statementPeriod = jobExecution.getJobParameters().getString("statement.period");
        //     if (statementPeriod != null) { span.setTag("job.statement_period", statementPeriod); }
        // }
        // ─────────────────────────────────────────────────────────────────────────────
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
        // Note: finance.batch.records_processed metrics are generated in Datadog
        // from APM spans via Metrics from Spans (see deploy/terraform/datadog/main.tf).
        // No DogStatsD client needed in this service.
    }
}
