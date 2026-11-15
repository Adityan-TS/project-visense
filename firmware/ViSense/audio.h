// audio.h — INMP441 I2S capture -> IMA-ADPCM -> BLE audio packets.
#pragma once
#include <stdint.h>

void    audioBegin();          // starts the I2S driver and the audio task
uint8_t audioMicLevel();       // 0..100, peak of the last frame (log scale)
bool    audioMicOk();          // false if I2S failed or the mic only returns 0 / -1
void    audioSetGain(uint8_t gain);   // 1..64, 1 = unity
uint8_t audioGain();
