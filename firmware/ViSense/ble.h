// ble.h — NimBLE peripheral: one service, AUDIO / TEXT / STATUS characteristics.
#pragma once
#include <stdint.h>
#include <stddef.h>
#include "visense_protocol.h"

struct TextMsg {
  uint8_t  type;
  uint16_t len;                    // payload length (without the type byte)
  char     data[VS_TEXT_MAX + 1];  // payload, always 0-terminated
};

void     bleBegin();
bool     bleIsConnected();
bool     bleAudioSubscribed();
bool     blePopText(TextMsg& out);                     // loop(): next message from phone
void     bleSendAudioPacket(const uint8_t* p, size_t n); // audio task: splits if MTU small
void     bleSendStatus(const uint8_t* p, size_t n);
uint32_t bleAudioPacketsSent();
uint32_t bleNotifyFailures();
