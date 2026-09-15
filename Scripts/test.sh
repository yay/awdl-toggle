#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
xcrun clang -fobjc-arc -fmodules -fmodules-cache-path="$PWD/build/tests/ModuleCache" -framework Foundation -Wall -Wextra \
  -Wno-unused-parameter -mmacosx-version-min=26.0 \
  Sources/Helper/AWDLMonitor.m Tests/MonitorTests.m -o build/tests/monitor-tests
build/tests/monitor-tests
xcrun swiftc -parse-as-library -module-cache-path "$PWD/build/tests/SwiftModuleCache" \
  -import-objc-header Sources/Shared/BridgingHeader.h \
  Sources/Shared/HelperClient.swift Tests/ClientTests.swift -o build/tests/client-tests
build/tests/client-tests
python3 -m unittest discover -s Tests -p 'test_*.py' -v
