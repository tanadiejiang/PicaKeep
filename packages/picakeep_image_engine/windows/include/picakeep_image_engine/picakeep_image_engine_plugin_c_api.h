#ifndef PICAKEEP_IMAGE_ENGINE_PLUGIN_C_API_H
#define PICAKEEP_IMAGE_ENGINE_PLUGIN_C_API_H
#include <flutter_plugin_registrar.h>
#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FLUTTER_PLUGIN_EXPORT __declspec(dllimport)
#endif
#ifdef __cplusplus
extern "C" {
#endif
FLUTTER_PLUGIN_EXPORT void PicakeepImageEnginePluginCApiRegisterWithRegistrar(
  FlutterDesktopPluginRegistrarRef registrar);
#ifdef __cplusplus
}
#endif
#endif
