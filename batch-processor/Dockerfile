# ── Stage 1: Build ────────────────────────────────────────────────────────────
FROM gradle:8-jdk17 AS builder

WORKDIR /app

COPY build.gradle settings.gradle* ./
RUN gradle dependencies --no-daemon 2>/dev/null || true

COPY src ./src
RUN gradle bootJar --no-daemon -x test

# ── Stage 2: Runtime ──────────────────────────────────────────────────────────
FROM eclipse-temurin:17-jre

ARG APP_VERSION=0.0.1-SNAPSHOT

WORKDIR /app

COPY --from=builder /app/build/libs/*.jar app.jar

# ── DATADOG JAVA AGENT ────────────────────────────────────────────────────────
# The agent JAR is downloaded at build time so it is baked into the image.
# Uncomment when enabling APM (Step 3), Data Jobs Monitoring (Step 11),
# or Continuous Profiler (Step 7).
#
# ADD https://dtdg.co/latest-java-tracer /dd-java-agent.jar
# RUN chmod 444 /dd-java-agent.jar
# ─────────────────────────────────────────────────────────────────────────────

# ── JAVA_TOOL_OPTIONS ─────────────────────────────────────────────────────────
# Set externally in docker-compose.yml or K8s Deployment to attach the agent.
# Uncomment this ENV block after uncommenting ADD above (Step 3 onwards).
#
# ENV JAVA_TOOL_OPTIONS="\
#   -javaagent:/dd-java-agent.jar \
#   -Ddd.service=batch-processor \
#   -Ddd.env=${DD_ENV} \
#   -Ddd.version=${APP_VERSION} \
#   -Ddd.logs.injection=true \
#   -Ddd.data.jobs.enabled=true \
#   -Ddd.profiling.enabled=true \
#   -Ddd.runtime.metrics.enabled=true \
#   -Ddd.trace.sample.rate=1.0"
# ─────────────────────────────────────────────────────────────────────────────

ENV JAVA_OPTS="-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0 -Xss512k"

EXPOSE 8080

ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar /app/app.jar"]
