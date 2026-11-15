// =============================================================================
// audio.cpp — mic capture task.
//
// Every 20 ms: read 320 samples from I2S (blocking), convert INMP441 24-bit
// (in 32-bit slots) to 16-bit with DC removal + gain, and — only while the phone
// is subscribed — IMA-ADPCM encode and notify one 165-byte packet.
//
// ESP32-C3 has no FPU, so the per-sample path is integer only.
// =============================================================================
#include "config.h"
#if ENABLE_MIC
#include "audio.h"
#include "adpcm.h"
#include "visense_protocol.h"
#include <ESP_I2S.h>
#if ENABLE_BLE
  #include "ble.h"
#endif

static I2SClass i2s;
static volatile uint8_t gain = MIC_GAIN_DEFAULT;
static volatile uint8_t level = 0;
static volatile bool    micOk = false;

// Static buffers (keep them off the task stack).
static int32_t raw[VS_AUDIO_FRAME_SAMPLES];
static int16_t pcm[VS_AUDIO_FRAME_SAMPLES];
static uint8_t packet[VS_AUDIO_PACKET_BYTES];

static void audioTask(void*) {
  AdpcmState enc;
  uint16_t seq = 0;
  int32_t dcQ = 0;            // DC estimate, scaled by 1024
  bool wasStreaming = false;
  uint32_t zeroFrames = 0;

  for (;;) {
    size_t got = i2s.readBytes((char*)raw, sizeof(raw));   // blocks ~20 ms
    if (got != sizeof(raw)) { LOG("[mic] short read %u\n", (unsigned)got); continue; }

    // ---- 24-bit -> 16-bit, DC removal, gain, peak --------------------------------
    const int32_t g = gain;
    int32_t peak = 0;
    bool allSame = true;
    for (int i = 0; i < VS_AUDIO_FRAME_SAMPLES; i++) {
      int32_t x = raw[i] >> 12;               // 24-bit MSB-aligned -> ~20-bit
      if (raw[i] != raw[0]) allSame = false;
      dcQ += x - (dcQ >> 10);                 // 1-pole low-pass ~2.5 Hz = DC estimate
      int32_t y = x - (dcQ >> 10);            // high-passed signal
      y = (y * g) >> 4;                       // gain 1 = 20-bit -> 16-bit
      if (y > 32767) y = 32767; else if (y < -32768) y = -32768;
      pcm[i] = (int16_t)y;
      int32_t a = y < 0 ? -y : y;
      if (a > peak) peak = a;
    }
    // A dead/miswired mic returns constant 0 or -1 forever.
    zeroFrames = allSame ? zeroFrames + 1 : 0;
    micOk = zeroFrames < 25;                   // 0.5 s of constant data = not ok

    // Peak -> 0..100 on a log scale (-60 dBFS .. 0 dBFS). Float once per frame is fine.
    float db = peak > 0 ? 20.0f * log10f(peak / 32768.0f) : -100.0f;
    int lv = (int)((db + 60.0f) * (100.0f / 60.0f));
    level = lv < 0 ? 0 : (lv > 100 ? 100 : lv);

#if ENABLE_BLE
    // ---- Encode + send, only while the phone listens ---------------------------
    bool streaming = bleAudioSubscribed();
    if (streaming) {
      if (!wasStreaming) { enc = AdpcmState(); }   // fresh state per stream
      packet[0] = seq & 0xFF;
      packet[1] = seq >> 8;
      packet[2] = (uint16_t)enc.predictor & 0xFF;  // state BEFORE this frame
      packet[3] = (uint16_t)enc.predictor >> 8;
      packet[4] = enc.index;
      adpcmEncode(enc, pcm, VS_AUDIO_FRAME_SAMPLES, packet + VS_AUDIO_HEADER_BYTES);
      bleSendAudioPacket(packet, sizeof(packet));
      seq++;
    }
    wasStreaming = streaming;
#endif
  }
}

void audioBegin() {
  // setPins(bclk, ws, dout, din): we only receive.
  i2s.setPins(PIN_I2S_SCK, PIN_I2S_WS, -1, PIN_I2S_SD);
  bool ok = i2s.begin(I2S_MODE_STD, VS_AUDIO_SAMPLE_RATE, I2S_DATA_BIT_WIDTH_32BIT,
                      I2S_SLOT_MODE_MONO,
                      MIC_USE_RIGHT_SLOT ? I2S_STD_SLOT_RIGHT : I2S_STD_SLOT_LEFT);
  if (!ok) { LOG("[mic] I2S begin FAILED\n"); return; }
  LOG("[mic] I2S running at %d Hz, gain %u\n", VS_AUDIO_SAMPLE_RATE, gain);
  // Priority above loop() (1) so display redraws never starve the mic.
  xTaskCreate(audioTask, "audio", 4096, nullptr, 5, nullptr);
}

uint8_t audioMicLevel() { return level; }
bool    audioMicOk()    { return micOk; }
uint8_t audioGain()     { return gain; }
void    audioSetGain(uint8_t g) {
  if (g < 1) g = 1; if (g > 64) g = 64;
  gain = g;
  LOG("[mic] gain %u\n", g);
}

#endif  // ENABLE_MIC
