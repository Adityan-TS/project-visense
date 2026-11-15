// =============================================================================
// display.cpp — caption rendering on the 128x64 SSD1306.
//
// Model: a few committed lines (finals) + one live partial. On every redraw we
// word-wrap everything with the current font and show the LAST N lines, so the
// newest words are always at the bottom and older lines scroll up.
// =============================================================================
#include "display.h"
#include "config.h"
#include <U8g2lib.h>
#include <Wire.h>

// ---- Orientation (compile-time, see config.h) --------------------------------
#if OLED_ROTATE_180 && OLED_MIRROR_H
  #define OLED_ROTATION U8G2_MIRROR_VERTICAL   // 180° + horizontal mirror
#elif OLED_ROTATE_180
  #define OLED_ROTATION U8G2_R2
#elif OLED_MIRROR_H
  #define OLED_ROTATION U8G2_MIRROR
#else
  #define OLED_ROTATION U8G2_R0
#endif

// Full frame buffer (_F_) = 1 KB RAM, single sendBuffer() per redraw.
static U8G2_SSD1306_128X64_NONAME_F_HW_I2C u8g2(OLED_ROTATION, U8X8_PIN_NONE,
                                                PIN_I2C_SCL, PIN_I2C_SDA);

// ---- Fonts -------------------------------------------------------------------
// _tr = ASCII only (the phone strips accents before sending).
struct FontSpec { const uint8_t* font; uint8_t lineH; };
static const FontSpec FONTS[3] = {
  { u8g2_font_7x14B_tr,  16 },   // small : 4 lines, ~18 chars
  { u8g2_font_10x20_tr,  21 },   // medium: 3 lines, ~12 chars
  { u8g2_font_helvB18_tr, 32 },  // large : 2 lines, ~9 chars
};

static const int SCREEN_W   = 128;
static const int SCREEN_H   = 64;
static const int TEXT_W     = 124;   // leave 4 px on the right for the link dot
static const int MAX_COMMIT = 6;     // committed utterances we remember
static const int MAX_LINES  = 24;    // wrapped lines considered per redraw

static String  committed[MAX_COMMIT];  // ring buffer of finals
static int     commitHead  = 0;        // index of the oldest
static int     commitCount = 0;
static String  partial;
static uint8_t fontSize   = DEFAULT_FONT_SIZE;
static bool    connected  = false;
static bool    everHadText = false;
static bool    dirty      = true;
static uint8_t lastDrawMs = 0;

// Copy text keeping only printable ASCII. Multi-byte UTF-8 becomes '?'.
static String sanitize(const char* s) {
  String out;
  for (const uint8_t* p = (const uint8_t*)s; *p; ++p) {
    uint8_t c = *p;
    if (c >= 0x20 && c < 0x7F)      out += (char)c;
    else if (c == '\n' || c == '\t') out += ' ';
    else if (c >= 0xC0)             out += '?';   // UTF-8 lead byte
    // 0x80..0xBF continuation bytes are skipped
  }
  out.trim();
  return out;
}

// Append a line; if full, drop the oldest (we only ever show the newest ones).
static void pushLine(String* lines, int& n, const String& l) {
  if (n < MAX_LINES) { lines[n++] = l; return; }
  for (int k = 1; k < MAX_LINES; k++) lines[k-1] = lines[k];
  lines[MAX_LINES-1] = l;
}

// Word-wrap `text` to TEXT_W pixels, appending lines to `lines`.
static void wrapInto(const String& text, String* lines, int& n) {
  int len = text.length();
  int i = 0;
  String line;
  while (i < len) {
    while (i < len && text[i] == ' ') i++;            // skip spaces
    int j = i;
    while (j < len && text[j] != ' ') j++;            // [i, j) = one word
    if (j == i) break;
    String word = text.substring(i, j);
    String candidate = line.length() ? line + " " + word : word;
    if (u8g2.getStrWidth(candidate.c_str()) <= TEXT_W) {
      line = candidate;
    } else {
      if (line.length()) {                             // flush current line
        pushLine(lines, n, line);
        line = "";
      }
      // Word longer than a whole line: hard-break it character by character.
      while (u8g2.getStrWidth(word.c_str()) > TEXT_W) {
        int cut = word.length() - 1;
        while (cut > 1 && u8g2.getStrWidth(word.substring(0, cut).c_str()) > TEXT_W) cut--;
        String piece = word.substring(0, cut);
        pushLine(lines, n, piece);
        word = word.substring(cut);
      }
      line = word;
    }
    i = j;
  }
  if (line.length()) {
    pushLine(lines, n, line);
  }
}

static void drawWaitingScreen() {
  u8g2.setFont(u8g2_font_helvB14_tr);
  u8g2.drawStr(0, 18, "ViSense");
  u8g2.setFont(u8g2_font_7x14_tr);
  u8g2.drawStr(0, 40, "waiting for");
  u8g2.drawStr(0, 56, "phone...");
}

static void drawCaptions() {
  const FontSpec& f = FONTS[fontSize];
  u8g2.setFont(f.font);
  int rows = SCREEN_H / f.lineH;
  if (rows < 1) rows = 1;

  static String lines[MAX_LINES];
  int n = 0;
  for (int k = 0; k < commitCount; k++) wrapInto(committed[(commitHead + k) % MAX_COMMIT], lines, n);
  if (partial.length()) wrapInto(partial, lines, n);

  if (n == 0 && connected && !everHadText) {
    u8g2.drawStr(0, f.lineH - 4, "connected");
    return;
  }
  int first = n > rows ? n - rows : 0;
  // Bottom-align: the newest line always sits on the last row.
  int topPad = SCREEN_H - rows * f.lineH;
  int startRow = rows - (n - first);
  for (int k = first; k < n; k++) {
    int row = startRow + (k - first);
    int baseline = topPad + row * f.lineH + u8g2.getAscent();
    u8g2.drawStr(0, baseline, lines[k].c_str());
  }
}

// ---- Public API -----------------------------------------------------------------
void displayBegin() {
  u8g2.setI2CAddress(OLED_I2C_ADDR * 2);   // U8g2 wants the 8-bit address
  u8g2.setBusClock(I2C_CLOCK_HZ);
  u8g2.begin();
  u8g2.setFontPosBaseline();
  dirty = true;
  displayUpdate();
}

void displaySetConnected(bool c) {
  if (c == connected) return;
  connected = c;
  everHadText = false;
  if (!c) { commitCount = 0; commitHead = 0; partial = ""; }   // back to "waiting for phone"
  dirty = true;
}

void displayPartial(const char* text) {
  String s = sanitize(text);
  if (s == partial) return;          // only redraw when the text changed
  partial = s;
  if (s.length()) everHadText = true;
  dirty = true;
}

void displayFinal(const char* text) {
  String s = sanitize(text);
  partial = "";
  if (s.length()) {
    if (commitCount < MAX_COMMIT) {
      committed[(commitHead + commitCount) % MAX_COMMIT] = s;
      commitCount++;
    } else {
      committed[commitHead] = s;     // overwrite oldest
      commitHead = (commitHead + 1) % MAX_COMMIT;
    }
    everHadText = true;
  }
  dirty = true;
}

void displayClear() {
  commitCount = 0; commitHead = 0; partial = "";
  dirty = true;
}

void displaySetFontSize(uint8_t size) {
  if (size > 2) size = 2;
  if (size == fontSize) return;
  fontSize = size;
  dirty = true;
}

bool displayUpdate() {
  if (!dirty) return false;
  dirty = false;
  uint32_t t0 = millis();
  u8g2.clearBuffer();
  bool showCaptions = connected || commitCount > 0 || partial.length() > 0;
  if (showCaptions) drawCaptions(); else drawWaitingScreen();
  if (connected) u8g2.drawBox(SCREEN_W - 2, 0, 2, 2);   // tiny "link up" dot top-right
  u8g2.sendBuffer();                                    // ~25 ms at 400 kHz
  uint32_t dt = millis() - t0;
  lastDrawMs = dt > 255 ? 255 : (uint8_t)dt;
  return true;
}

uint8_t displayLastDrawMs() { return lastDrawMs; }
