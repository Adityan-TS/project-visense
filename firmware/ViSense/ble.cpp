// =============================================================================
// ble.cpp — NimBLE-Arduino 2.x peripheral.
//
// * Advertises the ViSense service; restarts advertising after a disconnect
//   (auto-reconnect: the phone keeps a pending connect() open forever).
// * TEXT writes are copied into a FreeRTOS queue; loop() drains it.
//   (Never touch the display from a BLE callback — it runs on the host task.)
// * AUDIO is only sent while the phone has notifications enabled.
// =============================================================================
#include "config.h"
#if ENABLE_BLE
#include "ble.h"
#include <NimBLEDevice.h>

static NimBLEServer*         server     = nullptr;
static NimBLECharacteristic* audioChar  = nullptr;
static NimBLECharacteristic* statusChar = nullptr;
static QueueHandle_t         textQueue  = nullptr;

static volatile bool     connected      = false;
static volatile bool     audioSubscribed = false;
static volatile uint16_t peerMtu        = 23;     // default ATT MTU until negotiated
static volatile uint32_t packetsSent    = 0;
static volatile uint32_t notifyFails    = 0;

// ---- Server (connection) callbacks ------------------------------------------------
class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* s, NimBLEConnInfo& info) override {
    connected = true;
    LOG("[ble] connected %s\n", info.getAddress().toString().c_str());
    // Short connection interval = low latency. iOS rules: min >= 15 ms,
    // max >= min + 15 ms. Units of 1.25 ms -> 12 = 15 ms, 24 = 30 ms.
    // Supervision timeout 4 s (units of 10 ms).
    s->updateConnParams(info.getConnHandle(), 12, 24, 0, 400);
#if BLE_ENABLE_2M_PHY
    s->updatePhy(info.getConnHandle(), BLE_GAP_LE_PHY_2M_MASK, BLE_GAP_LE_PHY_2M_MASK, 0);
#endif
  }

  void onDisconnect(NimBLEServer* s, NimBLEConnInfo& info, int reason) override {
    connected = false;
    audioSubscribed = false;
    peerMtu = 23;
    LOG("[ble] disconnected, reason 0x%x — advertising again\n", reason);
    NimBLEDevice::startAdvertising();
  }

  void onMTUChange(uint16_t mtu, NimBLEConnInfo& info) override {
    peerMtu = mtu;
    LOG("[ble] MTU %u (audio packet %s)\n", mtu,
        mtu - 3 >= VS_AUDIO_PACKET_BYTES ? "fits in one notification" : "will be split");
  }
};

// ---- TEXT characteristic: phone -> glasses ------------------------------------------
class TextCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* c, NimBLEConnInfo& info) override {
    NimBLEAttValue v = c->getValue();
    if (v.length() < 1) return;
    TextMsg m;
    m.type = v.data()[0];
    size_t n = v.length() - 1;
    if (n > VS_TEXT_MAX) n = VS_TEXT_MAX;
    memcpy(m.data, v.data() + 1, n);
    m.data[n] = 0;
    m.len = n;
    if (xQueueSend(textQueue, &m, 0) != pdTRUE) {
      // Queue full: drop the oldest so the newest text always gets through.
      TextMsg junk;
      xQueueReceive(textQueue, &junk, 0);
      xQueueSend(textQueue, &m, 0);
    }
  }
};

// ---- AUDIO characteristic: track subscription -----------------------------------------
class AudioCallbacks : public NimBLECharacteristicCallbacks {
  void onSubscribe(NimBLECharacteristic* c, NimBLEConnInfo& info, uint16_t subValue) override {
    audioSubscribed = (subValue & 0x0001) != 0;   // bit0 = notifications
    LOG("[ble] audio %s\n", audioSubscribed ? "subscribed -> streaming" : "unsubscribed");
  }
};

// =============================================================================
void bleBegin() {
  textQueue = xQueueCreate(12, sizeof(TextMsg));

  NimBLEDevice::init(BLE_DEVICE_NAME);
  NimBLEDevice::setPower(BLE_TX_POWER_DBM);
  NimBLEDevice::setMTU(BLE_PREFERRED_MTU);   // iOS initiates the exchange; we offer 247

  server = NimBLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());

  NimBLEService* svc = server->createService(VS_SERVICE_UUID);

  audioChar = svc->createCharacteristic(VS_AUDIO_CHAR_UUID, NIMBLE_PROPERTY::NOTIFY);
  audioChar->setCallbacks(new AudioCallbacks());

  NimBLECharacteristic* textChar = svc->createCharacteristic(
      VS_TEXT_CHAR_UUID, NIMBLE_PROPERTY::WRITE_NR | NIMBLE_PROPERTY::WRITE);
  textChar->setCallbacks(new TextCallbacks());

  statusChar = svc->createCharacteristic(
      VS_STATUS_CHAR_UUID, NIMBLE_PROPERTY::NOTIFY | NIMBLE_PROPERTY::READ);

  svc->start();

  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  adv->setName(BLE_DEVICE_NAME);
  adv->addServiceUUID(VS_SERVICE_UUID);   // the phone scans for this UUID
  adv->enableScanResponse(true);
  adv->start();
  LOG("[ble] advertising as \"%s\"\n", BLE_DEVICE_NAME);
}

bool bleIsConnected()       { return connected; }
bool bleAudioSubscribed()   { return connected && audioSubscribed; }
uint32_t bleAudioPacketsSent() { return packetsSent; }
uint32_t bleNotifyFailures()   { return notifyFails; }

bool blePopText(TextMsg& out) {
  return textQueue && xQueueReceive(textQueue, &out, 0) == pdTRUE;
}

void bleSendAudioPacket(const uint8_t* p, size_t n) {
  if (!bleAudioSubscribed()) return;
  size_t maxPayload = peerMtu > 23 ? peerMtu - 3 : 20;
  for (size_t off = 0; off < n; off += maxPayload) {
    size_t len = n - off < maxPayload ? n - off : maxPayload;
    audioChar->setValue(p + off, len);
    if (!audioChar->notify()) { notifyFails++; return; }   // out of buffers: drop rest of frame
  }
  packetsSent++;
}

void bleSendStatus(const uint8_t* p, size_t n) {
  if (!statusChar) return;
  statusChar->setValue(p, n);
  if (connected) statusChar->notify();
}

#endif  // ENABLE_BLE
