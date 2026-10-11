#!/bin/bash
set -euo pipefail

# Compile the real delivery service with fake preferences/localization and URLProtocol transport.
TASK_PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TASK_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codexmeter-push-test.XXXXXX")"
trap 'rm -rf "$TASK_BUILD_DIR"' EXIT

xcrun swiftc -parse-as-library -module-cache-path "$TASK_BUILD_DIR/module-cache" \
  "$TASK_PROJECT_DIR/CodexMeter/Core/QuotaModels.swift" \
  "$TASK_PROJECT_DIR/CodexMeter/Core/QuotaResetTracker.swift" \
  "$TASK_PROJECT_DIR/CodexMeter/Core/PushDelivery.swift" \
  "$TASK_PROJECT_DIR/CodexMeter/PushNotificationService.swift" \
  "$TASK_PROJECT_DIR/Tests/PushServiceIntegration/main.swift" \
  -o "$TASK_BUILD_DIR/integration"
"$TASK_BUILD_DIR/integration"
