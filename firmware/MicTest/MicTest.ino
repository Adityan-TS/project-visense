// =============================================================================
// MicTest.ino — is the INMP441 mic detected, and does it hear sound?
//
// Board: ESP32-C3 Dev Module (or XIAO_ESP32C3), Tools > USB CDC On Boot: Enabled
// Serial Monitor: 115200 baud.
//
// Wiring (same as firmware/ViSense):
//   INMP441 VDD -> 3V3     GND -> GND     L/R -> GND (left channel)
//   SCK -> GPIO 3          WS  -> GPIO 4  SD  -> GPIO 5
//
// What it prints every ~0.25 s:
//   level bar, peak, average loudness, and a verdict:
//   "NO DATA"   all samples are 0     -> SD wire / power / L/R problem
//   "STUCK"     samples never change  -> SD floating or shorted
//   "SILENT?"   tiny, steady signal   -> mic alive but hears nothing (or very quiet room)
//   "OK"        signal moves when you talk/clap
// It also auto-tries the other channel (L/R slot) if the first one is dead.
// =============================================================================
#include <ESP_I2S.h>

#define PIN_SCK 3
#define PIN_WS  4
#define PIN_SD  5
#define RATE    16000

I2SClass i2s;
bool useRight = false;

bool startI2S() {
  i2s.end();
  i2s.setPins(PIN_SCK, PIN_WS, -1, PIN_SD);
  return i2s.begin(I2S_MODE_STD, RATE, I2S_DATA_BIT_WIDTH_32BIT, I2S_SLOT_MODE_MONO,
                   useRight ? I2S_STD_SLOT_RIGHT : I2S_STD_SLOT_LEFT);
}

void setup() {
  Serial.begin(115200);
  delay(1500);
  Serial.println("\n=== INMP441 mic test ===");
  Serial.printf("SCK=%d WS=%d SD=%d, %d Hz\n", PIN_SCK, PIN_WS, PIN_SD, RATE);
  if (!startI2S()) {
    Serial.println("I2S driver failed to start (pin conflict?). Stopping.");
    while (true) delay(1000);
  }
  Serial.println("I2S started. Talk, clap or tap the mic...\n");
}

void loop() {
  static int32_t raw[1024];
  static int deadRounds = 0;

  size_t got = i2s.readBytes((char*)raw, sizeof(raw)) / 4;
  if (got == 0) { Serial.println("NO DATA: I2S read returned nothing (clock not running?)"); delay(500); return; }

  int64_t sum = 0; int32_t mn = INT32_MAX, mx = INT32_MIN; size_t zeros = 0;
  for (size_t i = 0; i < got; i++) {
    int32_t s = raw[i] >> 14;               // 24-bit mic data in the top bits -> ~18-bit
    if (raw[i] == 0) zeros++;
    sum += s; if (s < mn) mn = s; if (s > mx) mx = s;
  }
  int32_t dc = sum / (int64_t)got;
  int64_t energy = 0; int32_t peak = 0;
  for (size_t i = 0; i < got; i++) {
    int32_t s = (raw[i] >> 14) - dc;        // remove DC offset
    energy += (int64_t)s * s; if (abs(s) > peak) peak = abs(s);
  }
  int rms = (int)sqrt((double)energy / got);

  const char* verdict;
  if (zeros == got)       verdict = "NO DATA  (all zeros: check SD, VDD, GND, L/R)";
  else if (mn == mx)      verdict = "STUCK    (constant value: SD floating/shorted)";
  else if (peak < 40)     verdict = "SILENT?  (alive but very quiet - clap near it)";
  else                    verdict = "OK";

  int bars = constrain(rms / 20, 0, 40);
  char bar[41]; memset(bar, '#', bars); memset(bar + bars, '.', 40 - bars); bar[40] = 0;
  Serial.printf("[%s] rms=%5d peak=%6d  %s ch=%s\n", bar, rms, peak, verdict, useRight ? "R" : "L");

  // Dead on this channel for ~3 s? Try the other one (L/R pin may be tied high).
  if (zeros == got || mn == mx) {
    if (++deadRounds == 12) {
      useRight = !useRight;
      Serial.printf("\n>> Nothing on this channel, switching to %s channel\n\n", useRight ? "RIGHT" : "LEFT");
      startI2S();
      deadRounds = 0;
    }
  } else deadRounds = 0;
}
