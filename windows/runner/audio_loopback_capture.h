#ifndef RUNNER_AUDIO_LOOPBACK_CAPTURE_H_
#define RUNNER_AUDIO_LOOPBACK_CAPTURE_H_

#include <array>
#include <atomic>
#include <mutex>
#include <thread>

#include <audioclient.h>
#include <windows.h>

class AudioLoopbackCapture {
 public:
  AudioLoopbackCapture() = default;
  ~AudioLoopbackCapture();

  void Start(bool system_loopback);
  void Stop();
  HRESULT GetLevels(std::array<double, 10>* levels);

 private:
  void Capture(bool system_loopback);
  void SetFailure(HRESULT error);
  void ProcessSamples(const BYTE* data, UINT32 frames, DWORD flags,
                      const WAVEFORMATEX* format);
  void CalculateSpectrum(double sample_rate);

  std::atomic<bool> stop_requested_{false};
  std::thread capture_thread_;
  std::mutex mutex_;
  std::array<double, 10> levels_{};
  HRESULT error_ = S_OK;
  std::array<float, 2048> samples_{};
  size_t sample_index_ = 0;
  size_t samples_since_update_ = 0;
  bool samples_filled_ = false;
};

#endif  // RUNNER_AUDIO_LOOPBACK_CAPTURE_H_
