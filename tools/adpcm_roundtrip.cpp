// tools/adpcm_roundtrip.cpp — PC-side test of the firmware ADPCM encoder.
// Builds packets exactly like audio.cpp, writes them to a file for the Swift
// decoder test, and reports SNR of the C decoder.
//   clang++ -std=c++17 -I../firmware/ViSense adpcm_roundtrip.cpp ../firmware/ViSense/adpcm.cpp -o build/rt
#include "adpcm.h"
#include "visense_protocol.h"
#include <cmath>
#include <cstdio>
#include <vector>

int main(int argc, char** argv) {
  const char* outPath = argc > 1 ? argv[1] : "packets.bin";
  const int frames = 100;                       // 2 s
  std::vector<int16_t> pcm(frames * VS_AUDIO_FRAME_SAMPLES);
  for (size_t i = 0; i < pcm.size(); i++) {     // speech-ish: 2 tones + chirp + noise
    double t = i / 16000.0;
    double v = 0.3 * sin(2 * M_PI * 220 * t) + 0.2 * sin(2 * M_PI * (500 + 1500 * t) * t)
             + 0.05 * ((rand() % 2001) - 1000) / 1000.0;
    pcm[i] = (int16_t)(v * 32767 * (0.5 + 0.5 * sin(2 * M_PI * 1.5 * t)));
  }
  FILE* f = fopen(outPath, "wb");
  FILE* fp = fopen((std::string(outPath) + ".pcm").c_str(), "wb");
  fwrite(pcm.data(), 2, pcm.size(), fp); fclose(fp);

  AdpcmState enc;
  double sig = 0, err = 0;
  for (int fr = 0; fr < frames; fr++) {
    uint8_t pkt[VS_AUDIO_PACKET_BYTES];
    pkt[0] = fr & 0xFF; pkt[1] = fr >> 8;
    pkt[2] = (uint16_t)enc.predictor & 0xFF; pkt[3] = (uint16_t)enc.predictor >> 8;
    pkt[4] = enc.index;
    adpcmEncode(enc, &pcm[fr * VS_AUDIO_FRAME_SAMPLES], VS_AUDIO_FRAME_SAMPLES, pkt + 5);
    fwrite(pkt, 1, sizeof(pkt), f);
    // Decode from the packet header alone (like the phone does).
    AdpcmState dec; dec.predictor = (int16_t)(pkt[2] | pkt[3] << 8); dec.index = pkt[4];
    int16_t out[VS_AUDIO_FRAME_SAMPLES];
    adpcmDecode(dec, pkt + 5, VS_AUDIO_DATA_BYTES, out);
    for (int i = 0; i < VS_AUDIO_FRAME_SAMPLES; i++) {
      double a = pcm[fr * VS_AUDIO_FRAME_SAMPLES + i], d = a - out[i];
      sig += a * a; err += d * d;
    }
  }
  fclose(f);
  double snr = 10 * log10(sig / err);
  printf("C encode->decode SNR: %.1f dB (%d packets of %d bytes)\n", snr, frames, VS_AUDIO_PACKET_BYTES);
  return snr > 15 ? 0 : 1;
}
