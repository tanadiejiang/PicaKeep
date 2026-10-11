# Reader 066 PhotoView patch

Source: https://github.com/wgh136/photo_view

Locked revision: `a1255d1b5945aad4b7323303ec2ecdf0c90ffc4c` (`a1255d1`), version `0.14.0`.

The 16 library Dart files, package manifest and original MIT LICENSE were copied
from the existing locked local Pub checkout, without modifying that checkout.
All copied files are byte-identical except this one-line local Core change:

```diff
 void onScaleEnd(ScaleEndDetails details) async{
   if(stateChanged){
     await Future.delayed(const Duration(milliseconds: 200));
   }
+  if (!mounted) return;
   final double _scale = scale;
```

The guard prevents a retired Core's delayed gesture continuation from accessing
its disposed private AnimationControllers/context. Mounted behavior is unchanged.
This does not replace reader-local per-owner lease/listener/scale-state ownership.
The real gesture regression first reproduced the disposed Animator failure before
this guard. No exception suppression or delayed widget retirement is involved.
