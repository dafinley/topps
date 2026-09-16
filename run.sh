#!/bin/zsh

set -euo pipefail

project_root="${0:A:h}"
derived_data="$project_root/.build/DerivedData"
configuration="${TOPPS_CONFIGURATION:-Release}"
app_path="$derived_data/Build/Products/$configuration/Topps.app"
if [[ "$configuration" != Release && "$configuration" != Debug ]]; then
    print -u2 "TOPPS_CONFIGURATION must be Release or Debug."
    exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
    print -u2 "Topps requires Xcode and the xcodebuild command-line tool."
    exit 1
fi

print "Building Topps ($configuration)…"
xcodebuild \
    -quiet \
    -project "$project_root/Topps.xcodeproj" \
    -scheme Topps \
    -configuration "$configuration" \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data" \
    build \
    CODE_SIGNING_ALLOWED=NO \
    ONLY_ACTIVE_ARCH=YES

if [[ ! -d "$app_path" ]]; then
    print -u2 "Build succeeded, but Topps.app was not found at: $app_path"
    exit 1
fi

# `open` alone activates an older running instance, even after a successful build.
# Request a normal quit and wait for it to finish before loading the new executable.
print "Restarting Topps with the new build…"
/usr/bin/osascript -l JavaScript <<'JAVASCRIPT'
ObjC.import('AppKit');
ObjC.bindFunction('kill', ['int', ['int', 'int']]);
const apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier('com.dafinley.Topps');
const pids = [];
for (let i = 0; i < apps.count; i++) {
    pids.push(apps.objectAtIndex(i).processIdentifier);
    apps.objectAtIndex(i).terminate;
}
for (let attempt = 0; attempt < 100; attempt++) {
    let remaining = false;
    // NSRunningApplication state can stay cached without an AppKit run loop.
    // Signal 0 only checks existence; it does not send a termination signal.
    for (let i = 0; i < pids.length; i++) {
        if (pids[i] > 0 && $.kill(pids[i], 0) === 0) remaining = true;
    }
    if (!remaining) break;
    if (attempt === 99) throw new Error('Topps did not finish quitting. Quit it normally, then run ./run.sh again.');
    delay(0.1);
}
JAVASCRIPT
open -n "$app_path"
