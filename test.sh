#!/bin/bash
# Build and run the embedded portable regression suite (pure logic only).
set -euo pipefail
cd "$(dirname "$0")"
swiftc -parse-as-library -DCUB_SELF_TEST Sources/Core/*.swift Sources/SelfTests.swift -o /tmp/cub_self_tests
/tmp/cub_self_tests
