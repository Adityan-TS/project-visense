// adpcm.h — IMA-ADPCM 4:1 encoder (standard IMA step/index tables).
// The iOS decoder is ios/ViSense/ADPCM.swift. Plain C++, no Arduino deps, so it
// can also be compiled on a PC for the round-trip test in tools/.
#pragma once
#include <stdint.h>
#include <stddef.h>

struct AdpcmState {
  int16_t predictor = 0;
  uint8_t index = 0;     // 0..88
};

// Encode `n` samples (n even) into n/2 bytes. Sample 2k -> low nibble,
// sample 2k+1 -> high nibble. Updates `st`.
void adpcmEncode(AdpcmState& st, const int16_t* pcm, size_t n, uint8_t* out);

// Decoder (used by the PC test only; the phone has its own copy).
void adpcmDecode(AdpcmState& st, const uint8_t* in, size_t n, int16_t* pcm);
