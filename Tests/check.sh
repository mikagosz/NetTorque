#!/bin/bash
# Runs the logic checks: compiles the files that do not need AppKit together with Tests/main.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
# Same minimum system as the app (MACOSX_DEPLOYMENT_TARGET), so the checks also catch newer APIs.
swiftc -O -target "$(uname -m)-apple-macos14.0" NetTorque/LinkSpeed.swift NetTorque/LinkAlert.swift NetTorque/LinkMonitor.swift NetTorque/LinkDiagnosis.swift NetTorque/SpeedTest.swift NetTorque/TestController.swift NetTorque/Notifier.swift NetTorque/Migration.swift NetTorque/History.swift NetTorque/ServiceBrowser.swift NetTorque/PeerLink.swift NetTorque/HelpContent.swift Tests/main.swift -o build/checks
build/checks
