// =============================================================================
// visense_protocol.h — THE single source of truth for the BLE protocol.
// The iOS app mirrors this file in ios/ViSense/Protocol.swift.
// If you change anything here, change it there too.
// =============================================================================
#pragma once
#include <stdint.h>

// ---- UUIDs ------------------------------------------------------------------
#define VS_SERVICE_UUID      "4f1d0001-8b6e-4c3a-9a2f-6e5d1c0b7a90"
#define VS_AUDIO_CHAR_UUID   "4f1d0002-8b6e-4c3a-9a2f-6e5d1c0b7a90"  // notify
#define VS_TEXT_CHAR_UUID    "4f1d0003-8b6e-4c3a-9a2f-6e5d1c0b7a90"  // write w/o response
#define VS_STATUS_CHAR_UUID  "4f1d0004-8b6e-4c3a-9a2f-6e5d1c0b7a90"  // notify + read

// ---- AUDIO characteristic ---------------------------------------------------
// One packet per 20 ms frame (all little-endian):
//   [0..1] uint16 seq            frame counter, wraps
//   [2..3] int16  adpcm_predictor  IMA-ADPCM state BEFORE the first sample
//   [4]    uint8  adpcm_step_index (0..88)
//   [5..164] 160 bytes ADPCM = 320 samples; low nibble = earlier sample
// If the negotiated MTU is too small (payload < 165) the packet is sent as
// consecutive notifications of (MTU-3) bytes; the phone re-assembles to 165.
#define VS_AUDIO_SAMPLE_RATE    16000
#define VS_AUDIO_FRAME_SAMPLES  320                       // 20 ms
#define VS_AUDIO_HEADER_BYTES   5
#define VS_AUDIO_DATA_BYTES     (VS_AUDIO_FRAME_SAMPLES / 2)
#define VS_AUDIO_PACKET_BYTES   (VS_AUDIO_HEADER_BYTES + VS_AUDIO_DATA_BYTES)  // 165

// ---- TEXT characteristic (phone -> glasses) --------------------------------
// First byte = message type, rest = payload.
#define VS_MSG_PARTIAL   0x01  // UTF-8 text: replace the live (bottom) line
#define VS_MSG_FINAL     0x02  // UTF-8 text: commit as a finished line, scroll up
#define VS_MSG_CLEAR     0x03  // no payload: clear the screen
#define VS_MSG_PING      0x04  // uint32 token: echoed back in STATUS asap (latency)
#define VS_MSG_FONT      0x05  // uint8 size: 0 small, 1 medium, 2 large
#define VS_MSG_GAIN      0x06  // uint8 mic gain multiplier (1 = unity, 1..64)
#define VS_TEXT_MAX      240   // max payload bytes we accept

// ---- STATUS characteristic (glasses -> phone), 18 bytes little-endian -------
//   [0]      uint8  fw_major
//   [1]      uint8  fw_minor
//   [2]      uint8  mic_level 0..100 (peak, log scale)
//   [3]      uint8  flags: bit0 audio subscribed, bit1 mic ok
//   [4..7]   uint32 audio packets sent
//   [8..11]  uint32 notify failures (dropped packets on the glasses side)
//   [12..15] uint32 last ping token received (0 = none)
//   [16]     uint8  mic gain
//   [17]     uint8  last OLED redraw time in ms
#define VS_STATUS_BYTES 18
