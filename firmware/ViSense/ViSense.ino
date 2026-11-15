// =============================================================================
// ViSense firmware — live captions on smart glasses.
// Board: Seeed XIAO ESP32C3, ESP32 Arduino core 3.x
// Libs : NimBLE-Arduino 2.x, U8g2
//
// Tasks:
//   loop()      : BLE text queue -> OLED, Serial commands, status notifications
//   audioTask   : I2S mic -> DC removal/gain -> IMA-ADPCM -> BLE notify (audio.cpp)
//   NimBLE host : BLE callbacks push text messages into a queue (ble.cpp)
//
// Serial Monitor commands (115200, "Newline"):
//   any text      -> committed (final) line
//   p:some text   -> live partial line
//   /clear        -> clear screen
//   /demo         -> scrolling caption demo (simulated partials + finals)
//   /font 0|1|2   -> font size
//   /gain N       -> mic gain (1..64)
//   /stat         -> print status
// =============================================================================
#include "config.h"
#include "visense_protocol.h"
#include "display.h"
#if ENABLE_BLE
  #include "ble.h"
#endif
#if ENABLE_MIC
  #include "audio.h"
#endif

// ---- Demo mode: simulates a recognizer typing words, then committing ------------
static const char* DEMO_SENTENCES[] = {
  "Hello and welcome to ViSense",
  "live captions on smart glasses",
  "the quick brown fox jumps over the lazy dog",
  "this line is long enough to wrap across several rows of the display",
};
static bool     demoOn = false;
static int      demoSentence = 0;
static int      demoWord = 0;
static uint32_t demoNextMs = 0;

static void demoStep() {
  if (!demoOn || millis() < demoNextMs) return;
  const char* s = DEMO_SENTENCES[demoSentence];
  // Build the first (demoWord+1) words of the sentence.
  char buf[128]; int words = 0; int i = 0;
  for (; s[i] && i < (int)sizeof(buf) - 1; i++) {
    if (s[i] == ' ' && ++words > demoWord) break;
    buf[i] = s[i];
  }
  buf[i] = 0;
  bool done = (s[i] == 0);
  if (done) {
    displayFinal(buf);
    demoWord = 0;
    demoSentence = (demoSentence + 1) % (sizeof(DEMO_SENTENCES) / sizeof(DEMO_SENTENCES[0]));
    demoNextMs = millis() + 900;
  } else {
    displayPartial(buf);
    demoWord++;
    demoNextMs = millis() + 250;
  }
}

// ---- Apply one protocol message (from BLE or Serial) ---------------------------
static uint32_t lastPingToken = 0;
static void sendStatus();

static void handleMessage(uint8_t type, const char* payload, size_t len) {
  switch (type) {
    case VS_MSG_PARTIAL: displayPartial(payload); break;
    case VS_MSG_FINAL:   displayFinal(payload);   break;
    case VS_MSG_CLEAR:   displayClear();          break;
    case VS_MSG_FONT:    if (len >= 1) displaySetFontSize((uint8_t)payload[0]); break;
    case VS_MSG_GAIN:
#if ENABLE_MIC
      if (len >= 1) audioSetGain((uint8_t)payload[0]);
#endif
      break;
    case VS_MSG_PING:
      if (len >= 4) {
        memcpy(&lastPingToken, payload, 4);   // little-endian on both sides
        sendStatus();                          // echo immediately
      }
      break;
    default: LOG("[msg] unknown type 0x%02x\n", type);
  }
}

// ---- STATUS notification (see visense_protocol.h for layout) -------------------
static void sendStatus() {
#if ENABLE_BLE
  uint8_t s[VS_STATUS_BYTES] = {0};
  s[0] = FW_VERSION_MAJOR;
  s[1] = FW_VERSION_MINOR;
  uint8_t flags = bleAudioSubscribed() ? 1 : 0;
  uint32_t sent = bleAudioPacketsSent(), fails = bleNotifyFailures();
#if ENABLE_MIC
  s[2] = audioMicLevel();
  if (audioMicOk()) flags |= 2;
  s[16] = audioGain();
#endif
  s[3] = flags;
  memcpy(&s[4],  &sent, 4);
  memcpy(&s[8],  &fails, 4);
  memcpy(&s[12], &lastPingToken, 4);
  s[17] = displayLastDrawMs();
  bleSendStatus(s, sizeof(s));
#endif
}

// ---- Serial command line --------------------------------------------------------
static void handleSerialLine(String line) {
  line.trim();
  if (!line.length()) return;
  if (line == "/clear")              { demoOn = false; displayClear(); }
  else if (line == "/demo")          { demoOn = !demoOn; LOG("demo %s\n", demoOn ? "on" : "off"); }
  else if (line.startsWith("/font ")) displaySetFontSize(line.substring(6).toInt());
  else if (line.startsWith("/gain ")) {
#if ENABLE_MIC
    audioSetGain(line.substring(6).toInt());
#endif
  }
  else if (line == "/stat") {
#if ENABLE_BLE
    LOG("connected=%d subscribed=%d sent=%lu fails=%lu\n", bleIsConnected(), bleAudioSubscribed(),
        (unsigned long)bleAudioPacketsSent(), (unsigned long)bleNotifyFailures());
#endif
#if ENABLE_MIC
    LOG("mic level=%u gain=%u ok=%d\n", audioMicLevel(), audioGain(), audioMicOk());
#endif
    LOG("draw=%u ms heap=%lu\n", displayLastDrawMs(), (unsigned long)ESP.getFreeHeap());
  }
  else if (line.startsWith("p:"))    displayPartial(line.substring(2).c_str());
  else                               displayFinal(line.c_str());
}

static void pollSerial() {
  static String buf;
  while (Serial.available()) {
    char c = Serial.read();
    if (c == '\n' || c == '\r') { handleSerialLine(buf); buf = ""; }
    else if (buf.length() < 200) buf += c;
  }
}

// =============================================================================
void setup() {
  Serial.begin(115200);
  delay(300);   // give USB CDC a moment so the first logs aren't lost
  LOG("\nViSense fw %d.%d booting\n", FW_VERSION_MAJOR, FW_VERSION_MINOR);

  displayBegin();          // shows "ViSense – waiting for phone"
#if ENABLE_BLE
  bleBegin();
#endif
#if ENABLE_MIC
  audioBegin();
#endif
#if !ENABLE_BLE
  // Milestone 1: no phone yet, pretend we're "connected" so captions render.
  displaySetConnected(true);
  LOG("BLE disabled - type text in Serial Monitor, or /demo\n");
#endif
}

void loop() {
  pollSerial();
  demoStep();

#if ENABLE_BLE
  // Drain everything the phone sent since last time, then redraw once.
  TextMsg msg;
  while (blePopText(msg)) { demoOn = false; handleMessage(msg.type, msg.data, msg.len); }

  bool conn = bleIsConnected();
  displaySetConnected(conn);

  static uint32_t lastStatus = 0;
  if (conn && millis() - lastStatus >= 1000) { lastStatus = millis(); sendStatus(); }
#endif

  displayUpdate();   // no-op unless text changed
  delay(2);
}
