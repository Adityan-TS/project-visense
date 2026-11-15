// =============================================================================
// ViSenseDisplay.ino — caption glasses firmware: OLED + Bluetooth only.
// All speech processing happens on the iPhone; the phone sends text, we draw it.
//
// Board : XIAO_ESP32C3 or ESP32C3 Dev Module, ESP32 Arduino core 3.x
//         Tools -> USB CDC On Boot -> Enabled (for Serial logs)
// Lib   : U8g2 (by olikraus). Bluetooth uses the core's built-in BLE library.
// Wiring: OLED SDA -> D4 (GPIO6), SCL -> D5 (GPIO7), VCC -> 3V3, GND -> GND
//
// BLE protocol (must match ios/ViSense/Protocol.swift):
//   TEXT   characteristic (write / write-without-response), first byte = type:
//          0x01 partial (replace live line) 0x02 final (commit + scroll)
//          0x03 clear  0x04 ping (uint32, echoed in STATUS)  0x05 font size 0/1/2
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

// ---------------------------------------------------------------- settings ---
#define FW_MAJOR 2
#define FW_MINOR 0
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
#define TEXT_UUID    "4f1d0003-8b6e-4c3a-9a2f-6e5d1c0b7a90"
#define STATUS_UUID  "4f1d0004-8b6e-4c3a-9a2f-6e5d1c0b7a90"

#define MSG_PARTIAL 0x01
#define MSG_FINAL   0x02
#define MSG_CLEAR   0x03
#define MSG_PING    0x04
#define MSG_FONT    0x05
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
struct TextMsg { uint8_t type; uint16_t len; char data[TEXT_MAX + 1]; };

QueueHandle_t textQueue;
BLECharacteristic* statusChar = nullptr;
volatile bool bleConnected = false;
uint32_t lastPingToken = 0;

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
    if (xQueueSend(textQueue, &m, 0) != pdTRUE) {      // full: drop oldest
      TextMsg junk;
      xQueueReceive(textQueue, &junk, 0);
      xQueueSend(textQueue, &m, 0);
    }
  }
};

void bleBegin() {
  textQueue = xQueueCreate(12, sizeof(TextMsg));
  BLEDevice::init(DEVICE_NAME);
  BLEDevice::setMTU(247);
  BLEServer* server = BLEDevice::createServer();
  server->setCallbacks(new ServerCB());
  BLEService* svc = server->createService(SERVICE_UUID);

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

// STATUS, 18 bytes little-endian (layout shared with the app; mic fields are 0):
// [0]fw major [1]fw minor [2]mic level [3]flags [4..7]packets [8..11]fails
// [12..15]last ping token [16]gain [17]last OLED draw ms
void sendStatus() {
  if (!statusChar) return;
  uint8_t s[18] = {0};
  s[0] = FW_MAJOR;
  s[1] = FW_MINOR;
  memcpy(&s[12], &lastPingToken, 4);
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
    default: break;   // 0x06 mic gain etc.: no mic on this build, ignore
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
  Serial.setTxTimeoutMs(0);    // never block the display loop on an unread USB port
#endif
  delay(300);
  LOG("\nViSenseDisplay fw %d.%d\n", FW_MAJOR, FW_MINOR);

  u8g2.setI2CAddress(OLED_ADDR * 2);
  u8g2.setBusClock(400000);
  u8g2.begin();
  redrawIfNeeded();            // "ViSense - waiting for phone"

  bleBegin();
}

void loop() {
  pollSerial();
  demoStep();

  TextMsg m;
  while (xQueueReceive(textQueue, &m, 0) == pdTRUE) {   // everything the phone sent
    demoOn = false;
    handleMessage(m.type, m.data, m.len);
  }

  setLink(bleConnected);

  static uint32_t lastStatus = 0;
  if (bleConnected && millis() - lastStatus >= 1000) { lastStatus = millis(); sendStatus(); }

  redrawIfNeeded();            // draws once after draining all messages
  delay(2);
}
