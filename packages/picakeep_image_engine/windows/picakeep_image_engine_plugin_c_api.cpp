#include "include/picakeep_image_engine/picakeep_image_engine_plugin_c_api.h"
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <memory>
#include "picakeep_image_engine.h"
namespace {
class ImageEnginePlugin : public flutter::Plugin {
 public:
  explicit ImageEnginePlugin(flutter::PluginRegistrarWindows *registrar) {
    channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), "picakeep/image_engine", &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler([](const auto &call, auto result) {
      if (call.method_name() == "abiVersion") result->Success(flutter::EncodableValue(int(pki_abi_version())));
      else result->NotImplemented();
    });
  }
 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};
}
void PicakeepImageEnginePluginCApiRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar) {
  auto *windows_registrar = flutter::PluginRegistrarManager::GetInstance()
    ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);
  windows_registrar->AddPlugin(std::make_unique<ImageEnginePlugin>(windows_registrar));
}
