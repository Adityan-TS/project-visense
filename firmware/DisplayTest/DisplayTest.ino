// =============================================================================
// DisplayTest.ino — OLED-only test: prints "Hello world" on the SSD1306.
// Nothing else (no BLE, no mic). Use it to check wiring before the main sketch.
//
// Board : Tools -> Board -> esp32 -> XIAO_ESP32C3
//         Tools -> USB CDC On Boot -> Enabled   (for the Serial output)
// Lib   : U8g2 (by olikraus)
// Wiring: OLED SDA -> D4, SCL -> D5, VCC -> 3V3, GND -> GND
//
// Serial Monitor (115200) also lists every I2C device found, so if the screen
// stays black you can see whether the OLED answers at all (expect 0x3C).
// =============================================================================
#include <Wire.h>
#include <U8g2lib.h>

// Raw GPIO numbers: works with board "XIAO_ESP32C3" or "ESP32C3 Dev Module".
#define PIN_SDA 6               // XIAO D4
#define PIN_SCL 7               // XIAO D5
#define OLED_ADDR 0x3C          // try 0x3D if the scan shows that instead

// U8G2_R0 = normal. Use U8G2_R2 for 180°, U8G2_MIRROR to mirror horizontally.
U8G2_SSD1306_128X64_NONAME_F_HW_I2C u8g2(U8G2_R0, U8X8_PIN_NONE, PIN_SCL, PIN_SDA);

void scanI2C() {
  Serial.println("Scanning I2C...");
  int found = 0;
  for (uint8_t a = 1; a < 127; a++) {
    Wire.beginTransmission(a);
    if (Wire.endTransmission() == 0) {
      Serial.printf("  device at 0x%02X\n", a);
      found++;
    }
  }
  if (!found) Serial.println("  NOTHING found -> check SDA=D4, SCL=D5, 3V3, GND");
}

void setup() {
  Serial.begin(115200);
  delay(1000);                         // give USB serial time to connect
  Serial.println("\nDisplayTest starting");

  Wire.begin(PIN_SDA, PIN_SCL);
  scanI2C();

  u8g2.setI2CAddress(OLED_ADDR * 2);   // U8g2 wants the 8-bit address
  u8g2.setBusClock(400000);
  u8g2.begin();

  u8g2.clearBuffer();
  u8g2.setFont(u8g2_font_10x20_tr);    // same font the captions use (12 chars/line)
  u8g2.drawStr(0, 20, "Hello world");
  u8g2.setFont(u8g2_font_6x10_tr);
  u8g2.drawStr(0, 40, "ViSense display OK");
  u8g2.drawFrame(0, 0, 128, 64);       // border: shows if the whole panel is visible
  u8g2.sendBuffer();

  Serial.println("Drew \"Hello world\"");
}

void loop() {
  // Blink a small box in the corner so you can tell the board isn't frozen.
  static bool on = false;
  on = !on;
  u8g2.setDrawColor(on ? 1 : 0);
  u8g2.drawBox(120, 54, 6, 8);
  u8g2.setDrawColor(1);
  u8g2.sendBuffer();
  delay(500);
}
