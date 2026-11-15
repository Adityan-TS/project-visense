// adpcm.cpp — IMA-ADPCM, see adpcm.h
#include "adpcm.h"

static const int16_t STEP_TABLE[89] = {
  7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
  50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230,
  253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963,
  1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327,
  3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442,
  11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794,
  32767 };

static const int8_t INDEX_TABLE[16] = { -1, -1, -1, -1, 2, 4, 6, 8,
                                        -1, -1, -1, -1, 2, 4, 6, 8 };

static inline uint8_t encodeOne(AdpcmState& st, int16_t sample) {
  int step = STEP_TABLE[st.index];
  int diff = (int)sample - st.predictor;
  uint8_t nib = 0;
  if (diff < 0) { nib = 8; diff = -diff; }
  int vpdiff = step >> 3;
  if (diff >= step) { nib |= 4; diff -= step; vpdiff += step; }
  step >>= 1;
  if (diff >= step) { nib |= 2; diff -= step; vpdiff += step; }
  step >>= 1;
  if (diff >= step) { nib |= 1; vpdiff += step; }

  int pred = st.predictor + ((nib & 8) ? -vpdiff : vpdiff);
  if (pred > 32767) pred = 32767; else if (pred < -32768) pred = -32768;
  st.predictor = (int16_t)pred;

  int idx = st.index + INDEX_TABLE[nib];
  st.index = idx < 0 ? 0 : (idx > 88 ? 88 : idx);
  return nib;
}

static inline int16_t decodeOne(AdpcmState& st, uint8_t nib) {
  int step = STEP_TABLE[st.index];
  int vpdiff = step >> 3;
  if (nib & 4) vpdiff += step;
  if (nib & 2) vpdiff += step >> 1;
  if (nib & 1) vpdiff += step >> 2;
  int pred = st.predictor + ((nib & 8) ? -vpdiff : vpdiff);
  if (pred > 32767) pred = 32767; else if (pred < -32768) pred = -32768;
  st.predictor = (int16_t)pred;
  int idx = st.index + INDEX_TABLE[nib];
  st.index = idx < 0 ? 0 : (idx > 88 ? 88 : idx);
  return st.predictor;
}

void adpcmEncode(AdpcmState& st, const int16_t* pcm, size_t n, uint8_t* out) {
  for (size_t i = 0; i + 1 < n; i += 2) {
    uint8_t lo = encodeOne(st, pcm[i]);
    uint8_t hi = encodeOne(st, pcm[i + 1]);
    out[i / 2] = (uint8_t)(lo | (hi << 4));
  }
}

void adpcmDecode(AdpcmState& st, const uint8_t* in, size_t n, int16_t* pcm) {
  for (size_t i = 0; i < n; i++) {
    pcm[2 * i]     = decodeOne(st, in[i] & 0x0F);
    pcm[2 * i + 1] = decodeOne(st, in[i] >> 4);
  }
}
