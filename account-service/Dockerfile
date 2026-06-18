# ── Stage 1: Build ────────────────────────────────────────────────────────────
FROM gradle:8-jdk17 AS builder

WORKDIR /app

# Copy Gradle build files first for layer caching — dependencies are re-downloaded
# only when build.gradle changes, not on every source change.
COPY build.gradle settings.gradle* ./
RUN gradle dependencies --no-daemon 2>/dev/null || true

COPY src ./src
RUN gradle bootJar --no-daemon -x test

# ── Stage 2: Runtime ──────────────────────────────────────────────────────────
FROM eclipse-temurin:17-jre-jammy

LABEL maintainer="finance-platform-team"
LABEL service="account-service"

WORKDIR /app

COPY --from=builder /app/build/libs/app.jar app.jar

# ── DATADOG INSTRUMENTATION ──────────────────────────────────────────
# Step 3 — Download and add the Datadog Java agent.
# The agent provides auto-instrumentation with zero code changes.
# Uncomment the ADD line to include the agent in the image at build time.
#
# ADD https://dtdg.co/latest-java-tracer /dd-java-agent.jar
#
# Alternative: mount the agent from a shared volume or init-container in K8s.
# Docs: https://docs.datadoghq.com/tracing/trace_collection/dd_libraries/java/
# ─────────────────────────────────────────────────────────────────────

RUN addgroup --system finance && adduser --system --ingroup finance finance
USER finance

EXPOSE 8081

# ── DATADOG INSTRUMENTATION ──────────────────────────────────────────
# JAVA_TOOL_OPTIONS is picked up automatically by the JVM.
# Set this env var in docker-compose.yml or the K8s Deployment to inject
# the dd-java-agent — do NOT set it here to keep the image environment-agnostic.
#
# Example value (set externally):
#   -javaagent:/dd-java-agent.jar
#   -Ddd.service=account-service
#   -Ddd.env=${DD_ENV}
#   -Ddd.version=${DD_VERSION}
#   -Ddd.logs.injection=true
#   -Ddd.profiling.enabled=true
#
# Docs: https://docs.datadoghq.com/tracing/trace_collection/dd_libraries/java/
# ─────────────────────────────────────────────────────────────────────

CMD ["java", "-jar", "app.jar"]
