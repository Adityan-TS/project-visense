// =============================================================================
// config.h — every knob you may want to change at the hackathon lives here.
// =============================================================================
#pragma once
#include <Arduino.h>

#define FW_VERSION_MAJOR 1
#define FW_VERSION_MINOR 0

// ---- Feature switches (turn things off to isolate problems) -----------------
#define ENABLE_BLE   1   // 0 = OLED + Serial only (Milestone 1)
#define ENABLE_MIC   1   // 0 = no I2S / audio streaming

// ---- Serial debug logging ----------------------------------------------------
// Needs Tools -> "USB CDC On Boot: Enabled" in the Arduino IDE.
#define DEBUG_SERIAL 1
#if DEBUG_SERIAL
  #define LOG(...) Serial.printf(__VA_ARGS__)
#else
  #define LOG(...) do {} while (0)
#endif

// ---- Pins (XIAO ESP32C3). Never use D0, D8, D9 (strapping pins) -------------
// Raw GPIO numbers, so this compiles with board "XIAO_ESP32C3" OR "ESP32C3 Dev Module".
// XIAO label -> GPIO:  D1=3  D2=4  D3=5  D4=6  D5=7
#define PIN_I2C_SDA   6     // D4
#define PIN_I2C_SCL   7     // D5
#define OLED_I2C_ADDR 0x3C
#define I2C_CLOCK_HZ  400000

#define PIN_I2S_SCK   3     // D1  INMP441 SCK
#define PIN_I2S_WS    4     // D2  INMP441 WS
#define PIN_I2S_SD    5     // D3  INMP441 SD   (L/R tied to GND = left channel)

// ---- Microphone --------------------------------------------------------------
// If the mic level stays at 0 although wiring is right, try 1 (some driver/board
// combos swap the slots).
#define MIC_USE_RIGHT_SLOT 0
// Software gain multiplier, 1 = unity (24-bit -> 16-bit truncation).
// INMP441 is quiet; 8..16 is typical for speech at arm's length.
// Can be changed at runtime from the app (VS_MSG_GAIN).
#define MIC_GAIN_DEFAULT   10

// ---- OLED orientation ----------------------------------------------------------
// The optics use two reflections so the image is NOT mirrored by default.
#define OLED_ROTATE_180 0
#define OLED_MIRROR_H   0
// 0 small (7x14, 4 lines ~18 chars), 1 medium (10x20, 3 lines ~12 chars),
// 2 large (2 lines ~9 chars)
#define DEFAULT_FONT_SIZE 1

// ---- BLE ------------------------------------------------------------------------
#define BLE_DEVICE_NAME   "ViSense"
#define BLE_TX_POWER_DBM  9
#define BLE_PREFERRED_MTU 247
// Request 2M PHY after connect. If your NimBLE-Arduino version fails to compile
// on updatePhy(), set this to 0 (iOS usually picks 2M by itself anyway).
#define BLE_ENABLE_2M_PHY 1
