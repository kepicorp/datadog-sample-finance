#!/usr/bin/env python3
"""
generate-patches.py — Generate unified diff patch files for all service
instrumentation blocks.

Each patch uncomments all Datadog blocks in one service file.
Run from the project root:
    python3 scripts/generate-patches.py

Output: scripts/patches/<service>.patch for each service.
"""

import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).parent.parent

# ── Helpers ───────────────────────────────────────────────────────────────────


def read(path):
    return (ROOT / path).read_text()


def write_tmp(name, content):
    p = Path(f"/tmp/{name}")
    p.write_text(content)
    return p


def append_diff_from_strings(orig_rel, original_content, patched_content, patch_name):
    """Diff original_content against patched_content and APPEND to an existing patch file.
    Both inputs are strings; orig_rel is used only for the patch headers.
    """
    tmp_orig = write_tmp("_orig_" + orig_rel.replace("/", "_"), original_content)
    tmp_patched = write_tmp("_patched_" + orig_rel.replace("/", "_"), patched_content)

    result = subprocess.run(
        ["diff", "-u", str(tmp_orig), str(tmp_patched)], capture_output=True, text=True
    )
    if result.returncode == 2:
        print(f"  ERROR running diff for {orig_rel}: {result.stderr}")
        return False

    diff = result.stdout
    if not diff.strip():
        print(f"  WARNING: no diff for {orig_rel} (already patched?)")
        return False

    diff = re.sub(
        r"^--- .*\n", f"--- a/{orig_rel}\n", diff, count=1, flags=re.MULTILINE
    )
    diff = re.sub(
        r"^\+\+\+ .*\n", f"+++ b/{orig_rel}\n", diff, count=1, flags=re.MULTILINE
    )

    out = ROOT / "scripts" / "patches" / f"{patch_name}.patch"
    with out.open("a") as f:
        f.write(diff)
    lines = len(diff.splitlines())
    print(f"  appended {orig_rel} to {out.relative_to(ROOT)}  ({lines} lines)")
    return True


def append_diff(orig_rel, patched_content, patch_name):
    """Diff orig_rel against patched_content and APPEND the result to an existing patch file."""
    orig_abs = ROOT / orig_rel
    tmp_name = orig_rel.replace("/", "_")
    tmp_path = write_tmp(tmp_name, patched_content)

    result = subprocess.run(
        ["diff", "-u", str(orig_abs), str(tmp_path)], capture_output=True, text=True
    )
    if result.returncode == 2:
        print(f"  ERROR running diff for {orig_rel}: {result.stderr}")
        return False

    diff = result.stdout
    if not diff.strip():
        print(f"  WARNING: no diff for {orig_rel} (already patched?)")
        return False

    # Fix headers to be relative
    diff = re.sub(
        r"^--- .*\n", f"--- a/{orig_rel}\n", diff, count=1, flags=re.MULTILINE
    )
    diff = re.sub(
        r"^\+\+\+ .*\n", f"+++ b/{orig_rel}\n", diff, count=1, flags=re.MULTILINE
    )

    out = ROOT / "scripts" / "patches" / f"{patch_name}.patch"
    with out.open("a") as f:
        f.write(diff)
    lines = len(diff.splitlines())
    print(f"  appended {orig_rel} to {out.relative_to(ROOT)}  ({lines} lines)")
    return True


def make_patch(orig_rel, tmp_path, patch_name):
    """Create a unified diff and write it to scripts/patches/<patch_name>.patch"""
    orig_abs = str(ROOT / orig_rel)
    result = subprocess.run(
        ["diff", "-u", orig_abs, str(tmp_path)], capture_output=True, text=True
    )
    # diff exits 1 when files differ (normal), 2 on error
    if result.returncode == 2:
        print(f"  ERROR running diff: {result.stderr}")
        return False

    patch = result.stdout
    if not patch.strip():
        print(f"  WARNING: no diff generated for {patch_name}")
        return False

    # Fix headers to be relative (a/... b/...)
    patch = re.sub(
        r"^--- .*\n", f"--- a/{orig_rel}\n", patch, count=1, flags=re.MULTILINE
    )
    patch = re.sub(
        r"^\+\+\+ .*\n", f"+++ b/{orig_rel}\n", patch, count=1, flags=re.MULTILINE
    )

    out = ROOT / "scripts" / "patches" / f"{patch_name}.patch"
    out.write_text(patch)
    lines = len(patch.splitlines())
    print(f"  wrote {out.relative_to(ROOT)}  ({lines} lines)")
    return True


def dry_run(patch_name):
    patch_path = ROOT / "scripts" / "patches" / f"{patch_name}.patch"
    r = subprocess.run(
        ["patch", "--dry-run", "-p1", "-s", "--input", str(patch_path)],
        capture_output=True,
        text=True,
        cwd=ROOT,
    )
    if r.returncode == 0:
        print(f"  dry-run OK: {patch_name}.patch")
    else:
        print(f"  dry-run FAILED: {patch_name}.patch\n{r.stderr or r.stdout}")
    return r.returncode == 0


# ── Uncomment engine ──────────────────────────────────────────────────────────

BANNER_PY = re.compile(r"# ── DATADOG .*?# ─{5,}\n", re.DOTALL)
BANNER_JS = re.compile(r"// ── DATADOG .*?// ─{5,}\n", re.DOTALL)
BANNER_GO = re.compile(r"\t// ── DATADOG .*?\t// ─{5,}\n", re.DOTALL)
BANNER_GO_NOTAB = re.compile(r"// ── DATADOG .*?// ─{5,}\n", re.DOTALL)
BANNER_JAVA = re.compile(r"[ \t]*// ── DATADOG .*?[ \t]*// ─{5,}\n", re.DOTALL)


def uncomment_python_block(block):
    """Given a DATADOG banner block content, return the uncommented code lines."""
    lines = block.split("\n")
    result = []
    for line in lines:
        # Skip banner and footer lines
        if re.match(r"# ── DATADOG", line) or re.match(r"# ─{5,}", line):
            continue
        # Strip "# " prefix from code lines; drop pure prose comment lines
        m = re.match(r"^(\s*)# (.*)$", line)
        if m:
            indent, rest = m.group(1), m.group(2)
            # Keep if it looks like code (starts with python keyword, symbol, or indent)
            if re.match(
                r"^(import |from |with |if |    |patch|tracer|statsd|initia)", rest
            ):
                result.append(indent + rest)
            # else: drop prose
        elif line.strip() == "":
            result.append(line)
        else:
            result.append(line)  # non-commented line, keep as-is
    return "\n".join(result)


def process_python(content):
    def replace_block(m):
        return uncomment_python_block(m.group(0))

    return BANNER_PY.sub(replace_block, content)


def uncomment_js_block(block):
    lines = block.split("\n")
    result = []
    for line in lines:
        if re.match(r"// ── DATADOG", line) or re.match(r"// ─{5,}", line):
            continue
        m = re.match(r"^(\s*)// (.*)$", line)
        if m:
            indent, rest = m.group(1), m.group(2)
            if re.match(r"^(const |'use |require|  [a-zA-Z]|\}|logI|runt|prof)", rest):
                result.append(indent + rest)
        elif line.strip() == "":
            result.append(line)
        else:
            result.append(line)
    return "\n".join(result)


def process_js(content):
    def replace_block(m):
        return uncomment_js_block(m.group(0))

    return BANNER_JS.sub(replace_block, content)


def uncomment_go_block(block):
    lines = block.split("\n")
    result = []
    for line in lines:
        if re.match(r"\s*// ── DATADOG", line) or re.match(r"\s*// ─{5,}", line):
            continue
        # Tab-indented code inside functions: \t// <code>
        m = re.match(r"^(\s*)// (.*)$", line)
        if m:
            indent, rest = m.group(1), m.group(2)
            # Keep lines that look like Go code
            if (
                re.match(
                    r"^(\t|\"go\.|import|tracer\.|profiler\.|if |defer |edgesMap|ctx |_ =|datastreams|options\.|statsd)",
                    rest,
                )
                or re.match(
                    r'^[ \t]*(tracer\.|profiler\.|datastreams\.|options\.|statsd|edgesMap|"go\.)',
                    rest,
                )
                or rest.strip().startswith('"')
                or rest.strip().startswith(")")
                or rest.strip().startswith("}")
            ):
                result.append(indent + rest)
            # else: drop prose
        elif line.strip() == "":
            result.append(line)
        else:
            result.append(line)
    return "\n".join(result)


def process_go(content):
    # Go blocks can be tab-indented (inside functions) or not (import blocks)
    def replace_block(m):
        return uncomment_go_block(m.group(0))

    # Try both patterns
    content = BANNER_GO.sub(replace_block, content)
    content = BANNER_GO_NOTAB.sub(replace_block, content)
    return content


def uncomment_java_block(block):
    lines = block.split("\n")
    result = []
    for line in lines:
        if re.match(r"\s*// ── DATADOG", line) or re.match(r"\s*// ─{5,}", line):
            continue
        m = re.match(r"^(\s*)// (.*)$", line)
        if m:
            indent, rest = m.group(1), m.group(2)
            if (
                re.match(
                    r"^(import |Tracer |Span |tracer\.|span\.|if |statsd|StatsDClient|NonBlocking|compileOnly |implementation |    |\}|\))",
                    rest,
                )
                or rest.strip().startswith('"')
                or rest.strip().startswith(")")
                or rest.strip().startswith("}")
            ):
                result.append(indent + rest)
        elif line.strip() == "":
            result.append(line)
        else:
            result.append(line)
    return "\n".join(result)


def process_java(content):
    def replace_block(m):
        return uncomment_java_block(m.group(0))

    return BANNER_JAVA.sub(replace_block, content)


# ── Per-service patch generation ──────────────────────────────────────────────


def patch_gateway_api():
    print("gateway-api/main.py")
    orig = "gateway-api/main.py"
    content = read(orig)
    patched = process_python(content)
    tmp = write_tmp("gw.py", patched)
    ok = make_patch(orig, tmp, "gateway-api")
    if ok:
        dry_run("gateway-api")


def patch_fraud_detection():
    print("fraud-detection/main.py")
    orig = "fraud-detection/main.py"
    content = read(orig)
    patched = process_python(content)
    tmp = write_tmp("fd.py", patched)
    ok = make_patch(orig, tmp, "fraud-detection")
    if ok:
        dry_run("fraud-detection")


def patch_transaction_service():
    print("transaction-service/src/index.js")
    orig = "transaction-service/src/index.js"
    content = read(orig)
    patched = process_js(content)
    tmp = write_tmp("ts.js", patched)
    ok = make_patch(orig, tmp, "transaction-service")
    if ok:
        dry_run("transaction-service")


def patch_notification_service():
    print("notification-service/main.go")
    orig = "notification-service/main.go"
    content = read(orig)
    patched = process_go(content)
    tmp = write_tmp("ns.go", patched)
    ok = make_patch(orig, tmp, "notification-service")
    if ok:
        dry_run("notification-service")


def patch_batch_processor():
    # Patch both the Java source (custom spans) and build.gradle (dependencies)
    print(
        "batch-processor/src/main/java/com/example/finance/batch/listener/DatadogJobListener.java"
    )
    orig_java = "batch-processor/src/main/java/com/example/finance/batch/listener/DatadogJobListener.java"
    content_java = read(orig_java)
    patched_java = process_java(content_java)
    tmp_java = write_tmp("djl.java", patched_java)

    print("batch-processor/build.gradle")
    orig_gradle = "batch-processor/build.gradle"
    content_gradle = read(orig_gradle)
    patched_gradle = process_java(content_gradle)  # same // banner style
    tmp_gradle = write_tmp("build.gradle", patched_gradle)

    # Combine both diffs into one patch file
    import re as _re
    import subprocess

    def _diff(orig_rel, tmp_path):
        orig_abs = str(ROOT / orig_rel)
        r = subprocess.run(
            ["diff", "-u", orig_abs, str(tmp_path)], capture_output=True, text=True
        )
        if not r.stdout.strip():
            return ""
        patch = r.stdout
        patch = _re.sub(
            r"^--- .*\n", f"--- a/{orig_rel}\n", patch, count=1, flags=_re.MULTILINE
        )
        patch = _re.sub(
            r"^\+\+\+ .*\n", f"+++ b/{orig_rel}\n", patch, count=1, flags=_re.MULTILINE
        )
        return patch

    combined = _diff(orig_java, tmp_java) + _diff(orig_gradle, tmp_gradle)
    if not combined.strip():
        print("  WARNING: no diff generated for batch-processor")
        return

    out = ROOT / "scripts" / "patches" / "batch-processor.patch"
    out.write_text(combined)
    lines = len(combined.splitlines())
    print(f"  wrote scripts/patches/batch-processor.patch  ({lines} lines)")
    dry_run("batch-processor")


# ── Dependency file patch helpers ────────────────────────────────────────────


def patch_gateway_api_deps():
    """Uncomment ddtrace==2.9.0 in gateway-api/requirements.txt."""
    orig = "gateway-api/requirements.txt"
    original_content = read(orig)
    patched_content = re.sub(
        r"^# (ddtrace==\S+)",
        r"\1",
        original_content,
        flags=re.MULTILINE,
    )
    append_diff_from_strings(orig, original_content, patched_content, "gateway-api")


def patch_fraud_detection_deps():
    """Uncomment ddtrace[data_streams] in fraud-detection/requirements.txt."""
    orig = "fraud-detection/requirements.txt"
    original_content = read(orig)
    patched_content = re.sub(
        r"^# (ddtrace\[data_streams\]==\S+)",
        r"\1",
        original_content,
        flags=re.MULTILINE,
    )
    append_diff_from_strings(orig, original_content, patched_content, "fraud-detection")


def patch_transaction_service_deps():
    """Add dd-trace ^5.0.0 to transaction-service/package.json dependencies."""
    import copy
    import json

    orig = "transaction-service/package.json"
    original_content = read(orig)
    pkg = json.loads(original_content)

    # Add dd-trace as the first dependency
    deps = {"dd-trace": "^5.0.0"}
    deps.update(pkg.get("dependencies", {}))
    pkg_patched = copy.deepcopy(pkg)
    pkg_patched["dependencies"] = deps
    patched_content = json.dumps(pkg_patched, indent=2) + "\n"

    append_diff_from_strings(
        orig, original_content, patched_content, "transaction-service"
    )


def patch_notification_service_deps():
    """Uncomment dd-trace-go require block in notification-service/go.mod.

    The commented block in go.mod looks like:
        // require (
        //     // APM tracer + DSM — manual instrumentation and tracer.Start()
        //     github.com/DataDog/dd-trace-go/v2 v2.0.0
        //
        //     // DogStatsD client — custom counters, histograms, gauges
        //     github.com/DataDog/datadog-go/v5 v5.5.0
        // )

    We replace it with an active require block (go mod tidy must be run in the
    Docker build stage to populate go.sum for the new transitive deps).
    """
    orig = "notification-service/go.mod"
    original_content = read(orig)

    # Build the exact commented block using a regex so inline comment variations
    # don't break matching.
    commented_pattern = re.compile(
        r"// require \(\n"
        r"(?://[^\n]*\n)*"
        r"// \)",
        re.MULTILINE,
    )

    match = commented_pattern.search(original_content)
    if not match:
        print("  WARNING: could not find commented require block in go.mod")
        append_diff_from_strings(
            orig, original_content, original_content, "notification-service"
        )
        return

    uncommented_block = (
        "require (\n"
        "\tgithub.com/DataDog/dd-trace-go/v2 v2.0.0\n"
        "\tgithub.com/DataDog/datadog-go/v5 v5.5.0\n"
        ")"
    )
    patched_content = (
        original_content[: match.start()]
        + uncommented_block
        + original_content[match.end() :]
    )
    append_diff_from_strings(
        orig, original_content, patched_content, "notification-service"
    )


def patch_batch_processor_dockerfile():
    """Append a Dockerfile hunk to batch-processor.patch to uncomment ADD agent line."""
    orig = "batch-processor/Dockerfile"
    content = read(orig)
    patched = content.replace(
        "# ADD https://dtdg.co/latest-java-tracer /dd-java-agent.jar\n"
        "# RUN chmod 444 /dd-java-agent.jar",
        "ADD https://dtdg.co/latest-java-tracer /dd-java-agent.jar\n"
        "RUN chmod 444 /dd-java-agent.jar",
    )
    append_diff(orig, patched, "batch-processor")


# ── Main ──────────────────────────────────────────────────────────────────────


if __name__ == "__main__":
    (ROOT / "scripts" / "patches").mkdir(parents=True, exist_ok=True)
    print("Generating patches...\n")
    patch_gateway_api()
    patch_gateway_api_deps()
    print()
    patch_fraud_detection()
    patch_fraud_detection_deps()
    print()
    patch_transaction_service()
    patch_transaction_service_deps()
    print()
    patch_notification_service()
    patch_notification_service_deps()
    print()
    patch_batch_processor()
    patch_batch_processor_dockerfile()
    print("\nDone.")
