#include <jni.h>
#include "picakeep_image_engine.h"
extern "C" JNIEXPORT jint JNICALL
Java_lingxue_picakeep_image_1engine_PicakeepImageEnginePlugin_nativeAbiVersion(
  JNIEnv *, jobject) {
  return static_cast<jint>(pki_abi_version());
}
