# Picked up by Flutter's Gradle plugin for a shrunk release build (beside its own rules).
# ML Kit text recognition (reading an ID card, 0281) links its Chinese,
# Devanagari, Japanese and Korean recognizers compile-only; only Latin is
# shipped, so R8 must not stop on the missing classes.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
