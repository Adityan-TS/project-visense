#!/bin/sh
# End-to-end speaker-name test on the Mac, using the app's own files:
# AudioHistory -> SpeakerLabeler (silence trim + FluidAudio voiceprint) -> SpeakerRecognizer.assign.
# Plays a scripted conversation of 4 `say` voices in real time (~1 min), with room noise,
# and checks every line gets the right speaker. First run downloads FluidAudio + models.
#   sh tools/speakers/run.sh
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
W="${TMPDIR:-/tmp}/visense-speakers"
mkdir -p "$W/pkg/Sources/e2e" "$W/voices"
cat > "$W/pkg/Package.swift" <<PKG
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "e2e", platforms: [.macOS(.v14)],
  dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3")],
  targets: [.executableTarget(name: "e2e", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
    swiftSettings: [.swiftLanguageMode(.v5)])])
PKG
for f in SpeakerLabeler SpeakerRecognition Log TonePunctuation DatabricksClient; do
  cp "$ROOT/ios/ViSense/$f.swift" "$W/pkg/Sources/e2e/"; done
cp "$ROOT/tools/speakers/main.swift" "$W/pkg/Sources/e2e/main.swift"
cd "$W/voices"
say -v Daniel -o daniel1.aiff "Your next appointment is on Friday at three in the afternoon."
say -v Daniel -o daniel2.aiff "Okay, sounds good."
say -v Daniel -o daniel3.aiff "I was going to say that we should probably leave a bit earlier tomorrow because of the traffic."
say -v Aman -o aman1.aiff "Please take two tablets after dinner every day."
say -v Aman -o aman2.aiff "Yeah, I think so."
say -v Aman -o aman3.aiff "Did you finish the report for the meeting, or should I ask someone else to help with it?"
say -v Samantha -o samantha1.aiff "I'll pick up the groceries on my way home tonight."
say -v Samantha -o samantha2.aiff "Sure, no problem."
say -v Samantha -o samantha3.aiff "The doctor said the results look normal but she wants to see you again in two weeks."
say -v Karen -o karen1.aiff "Have you seen my keys anywhere in the kitchen?"
say -v Karen -o karen3.aiff "Honestly it has just been a really long week and I am looking forward to the weekend."
cd "$W/pkg" && swift build -c release 2>&1 | grep -E "error|Build complete"
P="$HOME/Library/Application Support/speaker_profiles.json"
[ -e "$P" ] && cp "$P" "$P.bak"
.build/release/e2e "$W/voices" 2>&1 | grep -E " -> |speakers created"
rm -f "$P"; [ -e "$P.bak" ] && mv "$P.bak" "$P"
