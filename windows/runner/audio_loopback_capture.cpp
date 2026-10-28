#include "audio_loopback_capture.h"

#include <audioclient.h>
#include <audioclientactivationparams.h>
#include <mmdeviceapi.h>
#include <ks.h>
#include <ksmedia.h>
#include <wrl/client.h>
#include <wrl/implements.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <complex>
#include <cstdint>
#include <cstring>

namespace {

using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Make;
constexpr size_t kFftSize = 2048;
constexpr double kPi = 3.14159265358979323846;

class ActivationHandler final
    : public Microsoft::WRL::RuntimeClass<
          Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
          IActivateAudioInterfaceCompletionHandler> {
 public:
  explicit ActivationHandler(HANDLE completed) : completed_(completed) {}

  HRESULT STDMETHODCALLTYPE ActivateCompleted(
      IActivateAudioInterfaceAsyncOperation* operation) override {
    HRESULT activation_result = E_UNEXPECTED;
    ComPtr<IUnknown> activated_interface;
    HRESULT result =
        operation->GetActivateResult(&activation_result, &activated_interface);
    if (SUCCEEDED(result)) result = activation_result;
    if (SUCCEEDED(result)) {
      result = activated_interface.As(&audio_client_);
    }
    result_ = result;
    SetEvent(completed_);
    return S_OK;
  }

  HRESULT result() const { return result_; }
  ComPtr<IAudioClient> audio_client() const { return audio_client_; }

 private:
  HANDLE completed_;
  HRESULT result_ = E_UNEXPECTED;
  ComPtr<IAudioClient> audio_client_;
};

HRESULT ActivateProcessLoopback(ComPtr<IAudioClient>* audio_client) {
  HANDLE completed = CreateEvent(nullptr, TRUE, FALSE, nullptr);
  if (completed == nullptr) return HRESULT_FROM_WIN32(GetLastError());

  AUDIOCLIENT_ACTIVATION_PARAMS activation{};
  activation.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
  activation.ProcessLoopbackParams.TargetProcessId = GetCurrentProcessId();
  activation.ProcessLoopbackParams.ProcessLoopbackMode =
      PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE;

  PROPVARIANT parameters{};
  parameters.vt = VT_BLOB;
  parameters.blob.cbSize = sizeof(activation);
  parameters.blob.pBlobData = reinterpret_cast<BYTE*>(&activation);

  auto handler = Make<ActivationHandler>(completed);
  if (!handler) {
    CloseHandle(completed);
    return E_OUTOFMEMORY;
  }

  ComPtr<IActivateAudioInterfaceAsyncOperation> operation;
  HRESULT result = ActivateAudioInterfaceAsync(
      VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK, __uuidof(IAudioClient),
      &parameters, handler.Get(), &operation);
  if (SUCCEEDED(result)) {
    const DWORD wait_result = WaitForSingleObject(completed, INFINITE);
    result = wait_result == WAIT_OBJECT_0
                 ? handler->result()
                 : HRESULT_FROM_WIN32(GetLastError());
  }
  if (SUCCEEDED(result)) *audio_client = handler->audio_client();
  CloseHandle(completed);
  return result;
}

HRESULT ActivateSystemLoopback(ComPtr<IAudioClient>* audio_client) {
  ComPtr<IMMDeviceEnumerator> enumerator;
  HRESULT result = CoCreateInstance(
      __uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
      IID_PPV_ARGS(&enumerator));
  if (FAILED(result)) return result;

  ComPtr<IMMDevice> device;
  result = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
  if (FAILED(result)) return result;

  return device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                          reinterpret_cast<void**>(audio_client->GetAddressOf()));
}

bool IsFloatFormat(const WAVEFORMATEX* format) {
  if (format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) return true;
  if (format->wFormatTag != WAVE_FORMAT_EXTENSIBLE ||
      format->cbSize < sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)) {
    return false;
  }
  return IsEqualGUID(
      reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(format)->SubFormat,
      KSDATAFORMAT_SUBTYPE_IEEE_FLOAT);
}

bool IsPcmFormat(const WAVEFORMATEX* format) {
  if (format->wFormatTag == WAVE_FORMAT_PCM) return true;
  if (format->wFormatTag != WAVE_FORMAT_EXTENSIBLE ||
      format->cbSize < sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)) {
    return false;
  }
  return IsEqualGUID(
      reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(format)->SubFormat,
      KSDATAFORMAT_SUBTYPE_PCM);
}

float ReadSample(const BYTE* data, WORD bits, bool is_float) {
  if (is_float && bits == 32) {
    float value = 0;
    std::memcpy(&value, data, sizeof(value));
    return std::clamp(value, -1.0f, 1.0f);
  }
  if (bits == 16) {
    int16_t value = 0;
    std::memcpy(&value, data, sizeof(value));
    return static_cast<float>(value) / 32768.0f;
  }
  if (bits == 24) {
    int32_t value = static_cast<int32_t>(data[0]) |
                    (static_cast<int32_t>(data[1]) << 8) |
                    (static_cast<int32_t>(data[2]) << 16);
    if (value & 0x00800000) value |= 0xFF000000;
    return static_cast<float>(value) / 8388608.0f;
  }
  if (bits == 32 && !is_float) {
    int32_t value = 0;
    std::memcpy(&value, data, sizeof(value));
    return static_cast<float>(value) / 2147483648.0f;
  }
  return 0;
}

void Fft(std::array<std::complex<double>, kFftSize>* values) {
  for (size_t i = 1, j = 0; i < kFftSize; ++i) {
    size_t bit = kFftSize >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) std::swap((*values)[i], (*values)[j]);
  }

  for (size_t length = 2; length <= kFftSize; length <<= 1) {
    const double angle = -2.0 * kPi / static_cast<double>(length);
    const std::complex<double> step(std::cos(angle), std::sin(angle));
    for (size_t start = 0; start < kFftSize; start += length) {
      std::complex<double> factor(1.0, 0.0);
      for (size_t offset = 0; offset < length / 2; ++offset) {
        const auto even = (*values)[start + offset];
        const auto odd = (*values)[start + offset + length / 2] * factor;
        (*values)[start + offset] = even + odd;
        (*values)[start + offset + length / 2] = even - odd;
        factor *= step;
      }
    }
  }
}

}  // namespace

AudioLoopbackCapture::~AudioLoopbackCapture() { Stop(); }

void AudioLoopbackCapture::Start(bool system_loopback) {
  Stop();
  {
    std::lock_guard<std::mutex> lock(mutex_);
    levels_.fill(0);
    error_ = S_OK;
    sample_index_ = 0;
    samples_since_update_ = 0;
    samples_filled_ = false;
  }
  stop_requested_ = false;
  capture_thread_ =
      std::thread(&AudioLoopbackCapture::Capture, this, system_loopback);
}

void AudioLoopbackCapture::Stop() {
  stop_requested_ = true;
  if (capture_thread_.joinable()) capture_thread_.join();
  std::lock_guard<std::mutex> lock(mutex_);
  levels_.fill(0);
}

HRESULT AudioLoopbackCapture::GetLevels(std::array<double, 10>* levels) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (FAILED(error_)) return error_;
  *levels = levels_;
  return S_OK;
}

void AudioLoopbackCapture::SetFailure(HRESULT error) {
  std::lock_guard<std::mutex> lock(mutex_);
  error_ = error;
}

void AudioLoopbackCapture::Capture(bool system_loopback) {
  const HRESULT com_result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const bool uninitialize_com = SUCCEEDED(com_result);
  if (FAILED(com_result) && com_result != RPC_E_CHANGED_MODE) {
    SetFailure(com_result);
    return;
  }

  ComPtr<IAudioClient> audio_client;
  HRESULT result = system_loopback
                       ? ActivateSystemLoopback(&audio_client)
                       : ActivateProcessLoopback(&audio_client);
  if (FAILED(result)) {
    SetFailure(result);
    if (uninitialize_com) CoUninitialize();
    return;
  }

  WAVEFORMATEX* format = nullptr;
  result = audio_client->GetMixFormat(&format);
  if (FAILED(result) || format == nullptr) {
    SetFailure(FAILED(result) ? result : E_FAIL);
    if (format != nullptr) CoTaskMemFree(format);
    if (uninitialize_com) CoUninitialize();
    return;
  }
  if ((!IsFloatFormat(format) && !IsPcmFormat(format)) ||
      (IsFloatFormat(format) && format->wBitsPerSample != 32) ||
      (format->wBitsPerSample != 16 && format->wBitsPerSample != 24 &&
       format->wBitsPerSample != 32)) {
    CoTaskMemFree(format);
    SetFailure(E_NOTIMPL);
    if (uninitialize_com) CoUninitialize();
    return;
  }

  ComPtr<IAudioCaptureClient> capture_client;
  result = audio_client->Initialize(
      AUDCLNT_SHAREMODE_SHARED,
      AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM,
      0, 0, format, nullptr);
  if (SUCCEEDED(result)) {
    result = audio_client->GetService(IID_PPV_ARGS(&capture_client));
  }
  if (SUCCEEDED(result)) result = audio_client->Start();
  if (FAILED(result)) {
    CoTaskMemFree(format);
    SetFailure(result);
    if (uninitialize_com) CoUninitialize();
    return;
  }

  while (!stop_requested_) {
    UINT32 frames = 0;
    result = capture_client->GetNextPacketSize(&frames);
    if (FAILED(result)) break;
    if (frames == 0) {
      Sleep(5);
      continue;
    }

    BYTE* data = nullptr;
    DWORD flags = 0;
    result = capture_client->GetBuffer(&data, &frames, &flags, nullptr, nullptr);
    if (FAILED(result)) break;
    ProcessSamples(data, frames, flags, format);
    const HRESULT release_result = capture_client->ReleaseBuffer(frames);
    if (FAILED(release_result)) {
      result = release_result;
      break;
    }
  }

  audio_client->Stop();
  CoTaskMemFree(format);
  if (FAILED(result)) SetFailure(result);
  if (uninitialize_com) CoUninitialize();
}

void AudioLoopbackCapture::ProcessSamples(const BYTE* data, UINT32 frames,
                                          DWORD flags,
                                          const WAVEFORMATEX* format) {
  const bool is_float = IsFloatFormat(format);
  if (!is_float && !IsPcmFormat(format)) return;
  if ((is_float && format->wBitsPerSample != 32) ||
      (format->wBitsPerSample != 16 && format->wBitsPerSample != 24 &&
       format->wBitsPerSample != 32)) {
    return;
  }

  const size_t sample_bytes = format->wBitsPerSample / 8;
  const size_t frame_bytes = format->nBlockAlign;
  for (UINT32 frame = 0; frame < frames; ++frame) {
    double mono = 0;
    if ((flags & AUDCLNT_BUFFERFLAGS_SILENT) == 0 && data != nullptr) {
      for (WORD channel = 0; channel < format->nChannels; ++channel) {
        mono += ReadSample(data + frame * frame_bytes + channel * sample_bytes,
                           format->wBitsPerSample, is_float);
      }
      mono /= std::max<WORD>(1, format->nChannels);
    }
    samples_[sample_index_] = static_cast<float>(mono);
    sample_index_ = (sample_index_ + 1) % kFftSize;
    samples_filled_ = samples_filled_ || sample_index_ == 0;
    if (++samples_since_update_ >= 1024 && samples_filled_) {
      samples_since_update_ = 0;
      CalculateSpectrum(format->nSamplesPerSec);
    }
  }
}

void AudioLoopbackCapture::CalculateSpectrum(double sample_rate) {
  std::array<std::complex<double>, kFftSize> spectrum{};
  for (size_t index = 0; index < kFftSize; ++index) {
    const size_t sample = (sample_index_ + index) % kFftSize;
    const double window =
        0.5 - 0.5 * std::cos(2.0 * kPi * index / (kFftSize - 1));
    spectrum[index] = samples_[sample] * window;
  }
  Fft(&spectrum);

  constexpr std::array<double, 11> band_edges = {
      25, 50, 100, 200, 400, 800, 1600, 3200, 6400, 12800, 22000};
  std::array<double, 10> next_levels{};
  const double bin_width = sample_rate / kFftSize;
  for (size_t band = 0; band < next_levels.size(); ++band) {
    const size_t first_bin = std::max<size_t>(
        1, static_cast<size_t>(band_edges[band] / bin_width));
    const size_t last_bin = std::min<size_t>(
        kFftSize / 2,
        static_cast<size_t>(std::ceil(band_edges[band + 1] / bin_width)));
    double magnitude = 0;
    for (size_t bin = first_bin; bin <= last_bin; ++bin) {
      magnitude = std::max(magnitude, std::abs(spectrum[bin]) / (kFftSize * 0.25));
    }
    const double decibels = 20 * std::log10(std::max(magnitude, 0.00001));
    next_levels[band] = std::clamp((decibels + 60) / 60, 0.0, 1.0);
  }

  std::lock_guard<std::mutex> lock(mutex_);
  for (size_t index = 0; index < levels_.size(); ++index) {
    const double speed = next_levels[index] > levels_[index] ? 0.55 : 0.22;
    levels_[index] += (next_levels[index] - levels_[index]) * speed;
  }
}
