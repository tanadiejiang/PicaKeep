package lingxue.picakeep.image_engine

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

/** Registration only: all codec operations use the versioned FFI C ABI. */
class PicakeepImageEnginePlugin : FlutterPlugin {
    private var channel: MethodChannel? = null
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "picakeep/image_engine")
        channel?.setMethodCallHandler { call, result ->
            if (call.method == "abiVersion") result.success(nativeAbiVersion())
            else result.notImplemented()
        }
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }
    private external fun nativeAbiVersion(): Int
    companion object { init { System.loadLibrary("picakeep_image_engine") } }
}
