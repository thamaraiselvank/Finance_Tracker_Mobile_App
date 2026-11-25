# ML Kit text recognition (screenshot reading for "Share to Finverse") refers
# to optional Chinese / Devanagari / Japanese / Korean recognisers. Finverse
# only bundles the Latin recogniser, so these classes are intentionally absent.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**

# ML Kit creates its components by reflection (listed in the manifest under
# MlKitComponentDiscoveryService). Keep the registrars and their constructors,
# or text recognition fails in release builds with a NullPointerException.
-keep class * implements com.google.firebase.components.ComponentRegistrar { <init>(); }
-keep class com.google.mlkit.** { *; }
