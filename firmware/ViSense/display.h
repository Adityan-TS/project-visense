// display.h — OLED caption renderer (U8g2, SSD1306 128x64).
// All functions must be called from the Arduino loop() task only.
#pragma once
#include <stdint.h>

void     displayBegin();
void     displaySetConnected(bool connected);
void     displayPartial(const char* text);   // replace the live bottom line(s)
void     displayFinal(const char* text);     // commit a line, scroll up
void     displayClear();
void     displaySetFontSize(uint8_t size);   // 0, 1, 2
bool     displayUpdate();                    // redraws only if something changed
uint8_t  displayLastDrawMs();
