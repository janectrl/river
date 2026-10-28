#include "flutter_window.h"

#include <optional>
#include <set>
#include <string>
#include <vector>

#include "flutter/generated_plugin_registrant.h"

namespace {

bool SupportsProcessLoopback() {
  using RtlGetVersionFunction = LONG(WINAPI*)(OSVERSIONINFOW*);
  const auto get_version = reinterpret_cast<RtlGetVersionFunction>(
      GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "RtlGetVersion"));
  if (get_version == nullptr) return false;

  OSVERSIONINFOW version{};
  version.dwOSVersionInfoSize = sizeof(version);
  if (get_version(&version) != 0) return false;
  return version.dwMajorVersion > 10 ||
         (version.dwMajorVersion == 10 && version.dwBuildNumber >= 20348);
}

int CALLBACK CollectFontFamilies(const LOGFONTW* font,
                                 const TEXTMETRICW*, DWORD,
                                 LPARAM user_data) {
  auto* families = reinterpret_cast<std::set<std::wstring>*>(user_data);
  families->insert(font->lfFaceName);
  return 1;
}

std::string ToUtf8(const std::wstring& value) {
  const int size = WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, nullptr,
                                       0, nullptr, nullptr);
  if (size <= 1) return {};
  std::string result(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, result.data(), size,
                      nullptr, nullptr);
  result.resize(size - 1);
  return result;
}

flutter::EncodableList GetSystemFonts() {
  std::set<std::wstring> families;
  HDC device_context = GetDC(nullptr);
  if (device_context == nullptr) return {};

  LOGFONTW filter{};
  filter.lfCharSet = DEFAULT_CHARSET;
  EnumFontFamiliesExW(device_context, &filter, CollectFontFamilies,
                      reinterpret_cast<LPARAM>(&families), 0);
  ReleaseDC(nullptr, device_context);

  flutter::EncodableList result;
  result.reserve(families.size());
  for (const auto& family : families) {
    const auto utf8 = ToUtf8(family);
    if (!utf8.empty()) result.emplace_back(utf8);
  }
  return result;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  system_fonts_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "river/system_fonts",
          &flutter::StandardMethodCodec::GetInstance());
  system_fonts_channel_->SetMethodCallHandler(
      [](const auto& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() == "listFonts") {
          result->Success(flutter::EncodableValue(GetSystemFonts()));
        } else {
          result->NotImplemented();
        }
      });
  audio_visualizer_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "river/audio_visualizer",
          &flutter::StandardMethodCodec::GetInstance());
  audio_visualizer_channel_->SetMethodCallHandler(
      [this](const auto& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "start") {
          const bool system_loopback = !SupportsProcessLoopback();
          audio_loopback_capture_.Start(system_loopback);
          result->Success(flutter::EncodableValue(
              system_loopback ? "system" : "process"));
          return;
        }
        if (call.method_name() == "stop") {
          audio_loopback_capture_.Stop();
          result->Success();
          return;
        }
        if (call.method_name() == "getLevels") {
          std::array<double, 10> levels{};
          const HRESULT status = audio_loopback_capture_.GetLevels(&levels);
          if (FAILED(status)) {
            result->Error(
                "audio_capture_failed",
                "Windows process audio capture failed (HRESULT " +
                    std::to_string(static_cast<unsigned long>(status)) + ").");
            return;
          }
          flutter::EncodableList encoded_levels;
          encoded_levels.reserve(levels.size());
          for (const double level : levels) {
            encoded_levels.emplace_back(level);
          }
          result->Success(flutter::EncodableValue(encoded_levels));
          return;
        }
        result->NotImplemented();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (audio_visualizer_channel_) {
    audio_visualizer_channel_->SetMethodCallHandler(nullptr);
  }
  audio_visualizer_channel_.reset();
  audio_loopback_capture_.Stop();
  system_fonts_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      if (flutter_controller_ && flutter_controller_->engine()) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
