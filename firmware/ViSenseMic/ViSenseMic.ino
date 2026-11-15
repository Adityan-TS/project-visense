// =============================================================================
// ViSenseMic.ino — caption glasses firmware: OLED + INMP441 mic + Bluetooth.
// The glasses mic streams audio to the iPhone (IMA-ADPCM, 16 kHz), the phone
// transcribes it and sends the words back, we draw them.
//
// Board : XIAO_ESP32C3 or ESP32C3 Dev Module, ESP32 Arduino core 3.x
//         Tools -> USB CDC On Boot -> Enabled (for Serial logs)
// Lib   : U8g2 (by olikraus). Bluetooth uses the core's built-in BLE library.
// Wiring: OLED   SDA -> GPIO6, SCL -> GPIO7, VCC -> 3V3, GND -> GND
//         INMP441 SCK -> GPIO3, WS -> GPIO4, SD -> GPIO5, L/R -> GND,
//                 VDD -> 3V3, GND -> GND
// App   : Captions tab -> source "Glasses mic".
//
// BLE protocol (must match ios/ViSense/Protocol.swift):
//   AUDIO  characteristic (notify): 165-byte packets every 20 ms
//          [seq u16][predictor i16][step index u8][160 bytes ADPCM = 320 samples]
//          split into MTU-sized notifications if needed (the phone reassembles).
//          Only sent while the phone is subscribed (= "Glasses mic" selected).
//   TEXT   characteristic (write / write-without-response), first byte = type:
//          0x01 partial (replace live line) 0x02 final (commit + scroll)
//          0x03 clear  0x04 ping (uint32, echoed in STATUS)  0x05 font size 0/1/2
//          0x06 mic gain 1..64
//   STATUS characteristic (notify + read), 18 bytes, see sendStatus().
//
// Serial Monitor (115200, Newline): text = commit line, p:text = live line,
//   /clear, /demo, /font 0|1|2
// =============================================================================
#include <Wire.h>
#include <U8g2lib.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLE2902.h>
#include <ESP_I2S.h>

// ---------------------------------------------------------------- settings ---
#define FW_MAJOR 3
#define FW_MINOR 0

#define PIN_I2S_SCK 3
#define PIN_I2S_WS  4
#define PIN_I2S_SD  5
#define MIC_RIGHT_SLOT   0   // 1 if L/R is tied to 3V3
#define MIC_GAIN_DEFAULT 4   // 1..64, the app can change it (Captions settings)
#define SAMPLE_RATE      16000
#define FRAME_SAMPLES    320                    // 20 ms
#define PACKET_BYTES     (5 + FRAME_SAMPLES / 2) // 165
#define DEVICE_NAME "ViSense"

#define PIN_SDA   6          // XIAO D4
#define PIN_SCL   7          // XIAO D5
#define OLED_ADDR 0x3C       // 0x3D on some modules

#define OLED_ROTATE_180 0    // flip if the optics need it
#define OLED_MIRROR_H   0
#define DEFAULT_FONT    1    // 0 small (4x18), 1 medium (3x12), 2 large (2x9)
#define DEBUG_LOG       1

#if DEBUG_LOG
  #define LOG(...) Serial.printf(__VA_ARGS__)
#else
  #define LOG(...) do {} while (0)
#endif

// UUIDs — same as ios/ViSense/Protocol.swift
#define SERVICE_UUID "4f1d0001-8b6e-4c3a-9a2f-6e5d1c0b7a90"
#define AUDIO_UUID   "4f1d0002-8b6e-4c3a-9a2f-6e5d1c0b7a90"
#define TEXT_UUID    "4f1d0003-8b6e-4c3a-9a2f-6e5d1c0b7a90"
#define STATUS_UUID  "4f1d0004-8b6e-4c3a-9a2f-6e5d1c0b7a90"

#define MSG_PARTIAL 0x01
#define MSG_FINAL   0x02
#define MSG_CLEAR   0x03
#define MSG_PING    0x04
#define MSG_FONT    0x05
#define MSG_GAIN    0x06
#define TEXT_MAX    240

// ============================================================== display ===
#if OLED_ROTATE_180 && OLED_MIRROR_H
  #define OLED_ROTATION U8G2_MIRROR_VERTICAL
#elif OLED_ROTATE_180
  #define OLED_ROTATION U8G2_R2
#elif OLED_MIRROR_H
  #define OLED_ROTATION U8G2_MIRROR
#else
  #define OLED_ROTATION U8G2_R0
#endif

U8G2_SSD1306_128X64_NONAME_F_HW_I2C u8g2(OLED_ROTATION, U8X8_PIN_NONE, PIN_SCL, PIN_SDA);

struct FontSpec { const uint8_t* font; uint8_t lineH; };
const FontSpec FONTS[3] = {
  { u8g2_font_7x14B_tr,   16 },  // small : 4 lines
  { u8g2_font_10x20_tr,   21 },  // medium: 3 lines
  { u8g2_font_helvB18_tr, 32 },  // large : 2 lines
};

const int SCREEN_W = 128, SCREEN_H = 64;
const int TEXT_W = 124;          // keep 4 px on the right for the "connected" dot
const int MAX_COMMIT = 6;        // finished lines remembered
const int MAX_LINES = 24;

String  committed[MAX_COMMIT];   // ring buffer of finished lines
int     commitHead = 0, commitCount = 0;
String  partial;                 // live line
uint8_t fontSize = DEFAULT_FONT;
bool    linkUp = false;
bool    hadText = false;
bool    dirty = true;
uint8_t lastDrawMs = 0;

// Keep printable ASCII only (the phone already strips accents).
String sanitize(const char* s) {
  String out;
  for (const uint8_t* p = (const uint8_t*)s; *p; ++p) {
    uint8_t c = *p;
    if (c >= 0x20 && c < 0x7F) out += (char)c;
    else if (c == '\n' || c == '\t') out += ' ';
    else if (c >= 0xC0) out += '?';          // start of a multi-byte UTF-8 char
  }
  out.trim();
  return out;
}

void pushLine(String* lines, int& n, const String& l) {
  if (n < MAX_LINES) { lines[n++] = l; return; }
  for (int k = 1; k < MAX_LINES; k++) lines[k - 1] = lines[k];
  lines[MAX_LINES - 1] = l;
}

// Word-wrap text to the screen width.
void wrapInto(const String& text, String* lines, int& n) {
  int len = text.length(), i = 0;
  String line;
  while (i < len) {
    while (i < len && text[i] == ' ') i++;
    int j = i;
    while (j < len && text[j] != ' ') j++;
    if (j == i) break;
    String word = text.substring(i, j);
    String cand = line.length() ? line + " " + word : word;
    if (u8g2.getStrWidth(cand.c_str()) <= TEXT_W) {
      line = cand;
    } else {
      if (line.length()) { pushLine(lines, n, line); line = ""; }
      while (u8g2.getStrWidth(word.c_str()) > TEXT_W) {   // word wider than the screen
        int cut = word.length() - 1;
        while (cut > 1 && u8g2.getStrWidth(word.substring(0, cut).c_str()) > TEXT_W) cut--;
        pushLine(lines, n, word.substring(0, cut));
        word = word.substring(cut);
      }
      line = word;
    }
    i = j;
  }
  if (line.length()) pushLine(lines, n, line);
}

void drawWaiting() {
  u8g2.setFont(u8g2_font_helvB14_tr);
  u8g2.drawStr(0, 18, "ViSense");
  u8g2.setFont(u8g2_font_7x14_tr);
  u8g2.drawStr(0, 40, "waiting for");
  u8g2.drawStr(0, 56, "phone...");
}

void drawCaptions() {
  const FontSpec& f = FONTS[fontSize];
  u8g2.setFont(f.font);
  int rows = SCREEN_H / f.lineH;
  static String lines[MAX_LINES];
  int n = 0;
  for (int k = 0; k < commitCount; k++) wrapInto(committed[(commitHead + k) % MAX_COMMIT], lines, n);
  if (partial.length()) wrapInto(partial, lines, n);

  if (n == 0 && linkUp && !hadText) { u8g2.drawStr(0, f.lineH - 4, "connected"); return; }

  // Show the newest `rows` lines, bottom-aligned (newest words on the last row).
  int first = n > rows ? n - rows : 0;
  int topPad = SCREEN_H - rows * f.lineH;
  int startRow = rows - (n - first);
  for (int k = first; k < n; k++) {
    int row = startRow + (k - first);
    u8g2.drawStr(0, topPad + row * f.lineH + u8g2.getAscent(), lines[k].c_str());
  }
}

void redrawIfNeeded() {
  if (!dirty) return;
  dirty = false;
  uint32_t t0 = millis();
  u8g2.clearBuffer();
  if (linkUp || commitCount || partial.length()) drawCaptions(); else drawWaiting();
  if (linkUp) u8g2.drawBox(SCREEN_W - 2, 0, 2, 2);        // tiny "connected" dot
  u8g2.sendBuffer();
  uint32_t dt = millis() - t0;
  lastDrawMs = dt > 255 ? 255 : dt;
}

void showPartial(const char* t) {
  String s = sanitize(t);
  if (s == partial) return;          // redraw only when the text changed
  partial = s;
  if (s.length()) hadText = true;
  dirty = true;
}

void showFinal(const char* t) {
  String s = sanitize(t);
  partial = "";
  if (s.length()) {
    if (commitCount < MAX_COMMIT) committed[(commitHead + commitCount++) % MAX_COMMIT] = s;
    else { committed[commitHead] = s; commitHead = (commitHead + 1) % MAX_COMMIT; }
    hadText = true;
  }
  dirty = true;
}

void clearScreen() { commitCount = 0; commitHead = 0; partial = ""; dirty = true; }

void setLink(bool up) {
  if (up == linkUp) return;
  linkUp = up;
  hadText = false;
  if (!up) clearScreen();            // back to "waiting for phone"
  dirty = true;
}

// ================================================================== BLE ===
struct TextMsg { uint8_t type; uint16_t len; uint32_t seq; char data[TEXT_MAX + 1]; };

// Finished lines, clear, font, ping...: a queue, in order, never dropped while there is room.
// The live line (partial): only the NEWEST matters, so it is a single slot that is
// overwritten. A partial older than the last applied queue message is stale (a
// final after it already cleared the live line) and is ignored.
QueueHandle_t textQueue;
portMUX_TYPE partialMux = portMUX_INITIALIZER_UNLOCKED;
TextMsg latestPartial;
bool    partialWaiting = false;
uint32_t msgSeq = 0;              // written only by the BLE callback
BLEServer* server = nullptr;
BLECharacteristic* statusChar = nullptr;
BLECharacteristic* audioChar = nullptr;
BLE2902* audioCCCD = nullptr;
volatile bool bleConnected = false;
volatile bool audioSubscribed = false;
uint32_t lastPingToken = 0;

// Is the phone listening to the AUDIO characteristic? ("Glasses mic" selected)
bool phoneWantsAudio() {
  if (!bleConnected) return false;
#if defined(CONFIG_NIMBLE_ENABLED)
  return audioSubscribed;                       // set in AudioCB::onSubscribe
#else
  return audioCCCD && audioCCCD->getNotifications();
#endif
}

class ServerCB : public BLEServerCallbacks {
  // The core's BLE library runs on Bluedroid or NimBLE depending on the chip /
  // core version (NimBLE on the C3 with core 3.3); handle both.
  void onConnect(BLEServer* s) override {
    bleConnected = true;
    LOG("[ble] connected\n");
  }
  // Ask for a short connection interval = low latency (15–30 ms, iOS-compatible).
#if defined(CONFIG_NIMBLE_ENABLED)
  void onConnect(BLEServer* s, ble_gap_conn_desc* desc) override {
    bleConnected = true;
    s->updateConnParams(desc->conn_handle, 12, 24, 0, 400);
  }
#elif defined(CONFIG_BLUEDROID_ENABLED)
  void onConnect(BLEServer* s, esp_ble_gatts_cb_param_t* param) override {
    bleConnected = true;
    s->updateConnParams(param->connect.remote_bda, 12, 24, 0, 400);
  }
#endif
  void onDisconnect(BLEServer* s) override {
    bleConnected = false;
    audioSubscribed = false;
    LOG("[ble] disconnected, advertising again\n");
    BLEDevice::startAdvertising();   // the phone reconnects by itself
  }
};

// Runs on the Bluetooth task: only copy the message into the queue.
class TextCB : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) override {
    String v = c->getValue();
    if (v.length() < 1) return;
    TextMsg m;
    m.type = (uint8_t)v[0];
    size_t n = v.length() - 1;
    if (n > TEXT_MAX) n = TEXT_MAX;
    memcpy(m.data, v.c_str() + 1, n);
    m.data[n] = 0;
    m.len = n;
    m.seq = ++msgSeq;
    if (m.type == MSG_PARTIAL) {
      portENTER_CRITICAL(&partialMux);
      latestPartial = m;
      partialWaiting = true;
      portEXIT_CRITICAL(&partialMux);
      return;
    }
    if (xQueueSend(textQueue, &m, 0) != pdTRUE) {      // 32 deep: only if the display is stuck
      TextMsg junk;
      xQueueReceive(textQueue, &junk, 0);
      xQueueSend(textQueue, &m, 0);
    }
  }
};

#if defined(CONFIG_NIMBLE_ENABLED)
class AudioCB : public BLECharacteristicCallbacks {
  void onSubscribe(BLECharacteristic* c, ble_gap_conn_desc* desc, uint16_t subValue) override {
    audioSubscribed = (subValue & 1) != 0;
    LOG("[ble] audio %s\n", audioSubscribed ? "subscribed -> streaming mic" : "unsubscribed");
  }
};
#endif

void bleBegin() {
  textQueue = xQueueCreate(32, sizeof(TextMsg));
  BLEDevice::init(DEVICE_NAME);
  BLEDevice::setMTU(247);
  server = BLEDevice::createServer();
  server->setCallbacks(new ServerCB());
  BLEService* svc = server->createService(SERVICE_UUID);

  audioChar = svc->createCharacteristic(AUDIO_UUID, BLECharacteristic::PROPERTY_NOTIFY);
  audioCCCD = new BLE2902();
  audioChar->addDescriptor(audioCCCD);
#if defined(CONFIG_NIMBLE_ENABLED)
  audioChar->setCallbacks(new AudioCB());
#endif

  BLECharacteristic* textChar = svc->createCharacteristic(
      TEXT_UUID, BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  textChar->setCallbacks(new TextCB());

  statusChar = svc->createCharacteristic(
      STATUS_UUID, BLECharacteristic::PROPERTY_NOTIFY | BLECharacteristic::PROPERTY_READ);
  statusChar->addDescriptor(new BLE2902());

  svc->start();
  BLEAdvertising* adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(SERVICE_UUID);     // the phone scans for this
  adv->setScanResponse(true);
  BLEDevice::startAdvertising();
  LOG("[ble] advertising as %s\n", DEVICE_NAME);
}

// ============================================================== mic ===
// IMA-ADPCM encoder (same tables as ios/ViSense/ADPCM.swift).
const int16_t STEP_TABLE[89] = {
  7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
  50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230,
  253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963,
  1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327,
  3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442,
  11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794,
  32767 };
const int8_t INDEX_TABLE[16] = { -1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8 };

struct Adpcm {
  int16_t predictor = 0; uint8_t index = 0;
  uint8_t encode(int16_t sample);
};

uint8_t Adpcm::encode(int16_t sample) {
  Adpcm& st = *this;
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
  st.predictor = (int16_t)constrain(pred, -32768, 32767);
  st.index = (uint8_t)constrain(st.index + INDEX_TABLE[nib], 0, 88);
  return nib;
}

I2SClass i2s;
volatile uint8_t micGain = MIC_GAIN_DEFAULT;
volatile uint8_t micLevel = 0;      // 0..100
volatile bool    micOk = false;
volatile uint32_t audioPackets = 0;

void sendAudio(const uint8_t* p, size_t n) {
  uint16_t mtu = server ? server->getPeerMTU(server->getConnId()) : 23;
  size_t chunk = mtu > 23 ? mtu - 3 : 20;          // iOS usually gives 185+ -> one notify
  if (chunk > n) chunk = n;
  for (size_t off = 0; off < n; off += chunk) {
    size_t len = n - off < chunk ? n - off : chunk;
    audioChar->setValue((uint8_t*)p + off, len);
    audioChar->notify();
  }
  audioPackets++;
}

// Runs on its own task: read 20 ms, clean up, encode, send. Never blocks the display.
void audioTask(void*) {
  static int32_t raw[FRAME_SAMPLES];
  static int16_t pcm[FRAME_SAMPLES];
  static uint8_t packet[PACKET_BYTES];
  Adpcm enc;
  uint16_t seq = 0;
  int32_t dcQ = 0;
  uint32_t stuckFrames = 0;
  bool wasStreaming = false;

  for (;;) {
    size_t got = i2s.readBytes((char*)raw, sizeof(raw));   // blocks ~20 ms
    if (got != sizeof(raw)) continue;

    int32_t g = micGain, peak = 0;
    bool same = true;
    for (int i = 0; i < FRAME_SAMPLES; i++) {
      int32_t x = raw[i] >> 12;                 // 24-bit mic -> ~20-bit
      if (raw[i] != raw[0]) same = false;
      dcQ += x - (dcQ >> 10);                   // DC estimate
      int32_t y = ((x - (dcQ >> 10)) * g) >> 4; // remove DC, apply gain -> 16-bit
      y = constrain(y, -32768, 32767);
      pcm[i] = (int16_t)y;
      if (abs(y) > peak) peak = abs(y);
    }
    stuckFrames = same ? stuckFrames + 1 : 0;
    micOk = stuckFrames < 25;                   // 0.5 s of constant data = dead mic
    float db = peak > 0 ? 20.0f * log10f(peak / 32768.0f) : -100.0f;
    micLevel = (uint8_t)constrain((int)((db + 60.0f) * (100.0f / 60.0f)), 0, 100);

    bool streaming = phoneWantsAudio();
    if (streaming) {
      if (!wasStreaming) { enc = Adpcm(); LOG("[mic] streaming to phone\n"); }
      packet[0] = seq & 0xFF; packet[1] = seq >> 8;
      packet[2] = (uint16_t)enc.predictor & 0xFF; packet[3] = (uint16_t)enc.predictor >> 8;
      packet[4] = enc.index;                    // encoder state BEFORE this frame
      for (int i = 0; i < FRAME_SAMPLES; i += 2)
        packet[5 + i / 2] = enc.encode(pcm[i]) | (enc.encode(pcm[i + 1]) << 4);
      sendAudio(packet, PACKET_BYTES);
      seq++;
    }
    wasStreaming = streaming;
  }
}

void micBegin() {
  i2s.setPins(PIN_I2S_SCK, PIN_I2S_WS, -1, PIN_I2S_SD);
  if (!i2s.begin(I2S_MODE_STD, SAMPLE_RATE, I2S_DATA_BIT_WIDTH_32BIT, I2S_SLOT_MODE_MONO,
                 MIC_RIGHT_SLOT ? I2S_STD_SLOT_RIGHT : I2S_STD_SLOT_LEFT)) {
    LOG("[mic] I2S start FAILED\n");
    return;
  }
  LOG("[mic] I2S running, %d Hz, gain %u\n", SAMPLE_RATE, micGain);
  xTaskCreate(audioTask, "audio", 4096, nullptr, 5, nullptr);   // above loop() priority
}

// STATUS, 18 bytes little-endian (layout shared with the app):
// [0]fw major [1]fw minor [2]mic level [3]flags(bit0 streaming, bit1 mic ok)
// [4..7]audio packets [8..11]fails [12..15]last ping token [16]gain [17]last OLED draw ms
void sendStatus() {
  if (!statusChar) return;
  uint8_t s[18] = {0};
  s[0] = FW_MAJOR;
  s[1] = FW_MINOR;
  s[2] = micLevel;
  s[3] = (phoneWantsAudio() ? 1 : 0) | (micOk ? 2 : 0);
  uint32_t pk = audioPackets;
  memcpy(&s[4], &pk, 4);
  memcpy(&s[12], &lastPingToken, 4);
  s[16] = micGain;
  s[17] = lastDrawMs;
  statusChar->setValue(s, sizeof(s));
  if (bleConnected) statusChar->notify();
}

void handleMessage(uint8_t type, const char* data, size_t len) {
  switch (type) {
    case MSG_PARTIAL: showPartial(data); break;
    case MSG_FINAL:   showFinal(data);   break;
    case MSG_CLEAR:   clearScreen();     break;
    case MSG_FONT:
      if (len >= 1 && (uint8_t)data[0] <= 2 && (uint8_t)data[0] != fontSize) { fontSize = data[0]; dirty = true; }
      break;
    case MSG_PING:
      if (len >= 4) { memcpy(&lastPingToken, data, 4); sendStatus(); }   // echo for latency
      break;
    case MSG_GAIN:
      if (len >= 1) { micGain = constrain((uint8_t)data[0], 1, 64); LOG("[mic] gain %u\n", micGain); }
      break;
    default: break;
  }
}

// ========================================================== serial / demo ===
const char* DEMO[] = { "Hello and welcome to ViSense", "live captions on smart glasses",
                       "this line is long enough to wrap across several rows" };
bool demoOn = false;
int demoSentence = 0, demoWord = 0;
uint32_t demoNext = 0;

void demoStep() {
  if (!demoOn || millis() < demoNext) return;
  const char* s = DEMO[demoSentence];
  char buf[96]; int words = 0, i = 0;
  for (; s[i] && i < 95; i++) { if (s[i] == ' ' && ++words > demoWord) break; buf[i] = s[i]; }
  buf[i] = 0;
  if (!s[i]) { showFinal(buf); demoWord = 0; demoSentence = (demoSentence + 1) % 3; demoNext = millis() + 900; }
  else       { showPartial(buf); demoWord++; demoNext = millis() + 250; }
}

void pollSerial() {
  static String buf;
  while (Serial.available()) {
    char c = Serial.read();
    if (c != '\n' && c != '\r') { if (buf.length() < 200) buf += c; continue; }
    buf.trim();
    if (buf == "/clear") { demoOn = false; clearScreen(); }
    else if (buf == "/demo") demoOn = !demoOn;
    else if (buf.startsWith("/font ")) { fontSize = constrain(buf.substring(6).toInt(), 0, 2); dirty = true; }
    else if (buf.startsWith("p:")) showPartial(buf.substring(2).c_str());
    else if (buf.length()) showFinal(buf.c_str());
    buf = "";
  }
}

// ============================================================== main ===
void setup() {
  Serial.begin(115200);
#if ARDUINO_USB_CDC_ON_BOOT
  // Plugged into a computer that isn't reading the port, USB serial writes block
  // (up to ~2 s each), freezing the display loop. Never wait: drop the log text.
  Serial.setTxTimeoutMs(0);
#endif
  delay(300);
  LOG("\nViSenseMic fw %d.%d\n", FW_MAJOR, FW_MINOR);

  u8g2.setI2CAddress(OLED_ADDR * 2);
  u8g2.setBusClock(400000);
  u8g2.begin();
  redrawIfNeeded();            // "ViSense - waiting for phone"

  bleBegin();
  micBegin();
}

void loop() {
  pollSerial();
  demoStep();

  static TextMsg m, live;
  static uint32_t lastQueuedSeq = 0;
  bool haveLive = false;
  portENTER_CRITICAL(&partialMux);
  if (partialWaiting) { live = latestPartial; partialWaiting = false; haveLive = true; }
  portEXIT_CRITICAL(&partialMux);
  // Drain AFTER taking the live line, so a final sent just before it is applied first.
  while (xQueueReceive(textQueue, &m, 0) == pdTRUE) {   // finished lines etc., in order
    demoOn = false;
    lastQueuedSeq = m.seq;
    handleMessage(m.type, m.data, m.len);
  }
  if (haveLive && live.seq > lastQueuedSeq) {            // newest live line, unless a later final replaced it
    demoOn = false;
    handleMessage(live.type, live.data, live.len);
  }

  setLink(bleConnected);

  static uint32_t lastStatus = 0;
  if (bleConnected && millis() - lastStatus >= 1000) { lastStatus = millis(); sendStatus(); }

  static uint32_t lastLog = 0;                 // mic health in the Serial Monitor
  if (millis() - lastLog >= 2000) {
    lastLog = millis();
    LOG("[mic] level %3u  %s  %s  packets %lu\n", micLevel, micOk ? "ok" : "NO SIGNAL",
        phoneWantsAudio() ? "streaming" : "idle (pick Glasses mic in app)", (unsigned long)audioPackets);
  }

  redrawIfNeeded();            // draws once after draining all messages
  delay(2);
}
