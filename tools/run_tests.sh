#!/bin/sh
# Round-trip test: firmware ADPCM encoder (C++) -> iOS decoder (Swift), on the Mac.
set -e
cd "$(dirname "$0")"
mkdir -p build
clang++ -std=c++17 -Wall -I../firmware/ViSense adpcm_roundtrip.cpp ../firmware/ViSense/adpcm.cpp -o build/rt
./build/rt build/packets.bin
swiftc -O -o build/dec ../ios/ViSense/Protocol.swift ../ios/ViSense/ADPCM.swift main.swift
./build/dec build/packets.bin
swiftc -o build/pacer ../ios/ViSense/Protocol.swift ../ios/ViSense/WordPacer.swift pacer/main.swift
./build/pacer | tail -1
swiftc -O -DDEBUG -o build/tone \
  ../ios/ViSense/Log.swift \
  ../ios/ViSense/DatabricksClient.swift \
  ../ios/ViSense/TonePunctuation.swift \
  tone/main.swift
./build/tone | grep -E 'milestone|fine, honestly|going to say'
# Speech: committed-word alignment (pure helper pulled out of SpeechEngine.swift)
sed -n '/static func alignedCommitCount/,/^    }$/p' ../ios/ViSense/SpeechEngine.swift | sed 's/^    static func/func/' > build/align.swift
(echo "import Foundation"; cat realign/main.swift) > build/main.swift
swiftc -o build/realign build/main.swift build/align.swift
./build/realign | tail -1
echo "All tests OK"
