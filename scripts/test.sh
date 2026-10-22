#!/bin/zsh
# Run Swift Testing with the extra framework paths needed by a CLT-only installation.
set -euo pipefail
cd "$(dirname "$0")/.."
developer_root="$(xcode-select -p)"
frameworks="$developer_root/Library/Developer/Frameworks"
swift_libraries="$developer_root/Library/Developer/usr/lib"
test_flags=(--enable-swift-testing --disable-xctest)
if [[ -d "$frameworks/Testing.framework" ]]; then
  test_flags+=(-Xswiftc -F"$frameworks" -Xlinker -rpath -Xlinker "$frameworks")
  [[ -d "$swift_libraries" ]] && test_flags+=(-Xlinker -rpath -Xlinker "$swift_libraries")
fi
# Some CLT releases omit the Testing macro plugin from SwiftPM's resolved plugins.
# Load the shipped plugin explicitly when present; do not retry failed tests to hide errors.
swift_compiler="$(xcrun --find swiftc)"
testing_plugin="${swift_compiler:h:h}/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ -f "$testing_plugin" ]]; then
  test_flags+=(-Xswiftc -load-plugin-library -Xswiftc "$testing_plugin")
fi
exec xcrun swift test "${test_flags[@]}" "$@"
