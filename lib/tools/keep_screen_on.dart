import 'package:flutter/services.dart';
import 'package:picakeep/foundation/app.dart';


void setKeepScreenOn() async{
  if(!App.isMobile)  return;
  var channel = const MethodChannel("com.github.pacalini.pica_comic/keepScreenOn");
  await channel.invokeMethod("set");
}

void cancelKeepScreenOn() async{
  if(!App.isMobile)  return;
  var channel = const MethodChannel("com.github.pacalini.pica_comic/keepScreenOn");
  await channel.invokeMethod("cancel");
}