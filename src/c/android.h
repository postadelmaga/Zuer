// JNI + NDK per src/android_jni.zig (fullscreen immersivo, SAF, Bitmap).
// Include path: il sysroot del NDK, vedi lo step `android` in build.zig.
#include "jni.h"
#include "android/native_activity.h"
#include "android/bitmap.h" // libjnigraphics: i pixel di un android.graphics.Bitmap
