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
                    r"^(import |Tracer |Span |tracer\.|span\.|if |statsd|StatsDClient|NonBlocking|    |\}|\))",
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
    print(
        "batch-processor/src/main/java/com/example/finance/batch/listener/DatadogJobListener.java"
    )
    orig = "batch-processor/src/main/java/com/example/finance/batch/listener/DatadogJobListener.java"
    content = read(orig)
    patched = process_java(content)
    tmp = write_tmp("djl.java", patched)
    ok = make_patch(orig, tmp, "batch-processor")
    if ok:
        dry_run("batch-processor")


# ── Main ──────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    (ROOT / "scripts" / "patches").mkdir(parents=True, exist_ok=True)
    print("Generating patches...\n")
    patch_gateway_api()
    print()
    patch_fraud_detection()
    print()
    patch_transaction_service()
    print()
    patch_notification_service()
    print()
    patch_batch_processor()
    print("\nDone.")
