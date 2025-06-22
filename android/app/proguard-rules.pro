# Flutter Wrapper
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.embedding.** { *; }

# Google Play Core (for Flutter embedding)
-keep class com.google.android.play.core.** { *; }
-dontwarn com.google.android.play.core.**

# MediaPipe and Google Auto Value
-keep class com.google.auto.value.** { *; }
-keep class com.google.mediapipe.** { *; }
-keep class com.google.protobuf.** { *; }
-dontwarn com.google.auto.value.**
-dontwarn com.google.mediapipe.**

# Protocol Buffers
-keep class * extends com.google.protobuf.GeneratedMessageLite { *; }
-keep class com.google.protobuf.Internal$ProtoMethodMayReturnNull
-keep class com.google.protobuf.Internal$ProtoNonnullApi
-keep class com.google.protobuf.ProtoField
-keep class com.google.protobuf.ProtoPresenceBits
-keep class com.google.protobuf.ProtoPresenceCheckedField

# Error Prone annotations
-keep class com.google.errorprone.annotations.** { *; }
-dontwarn com.google.errorprone.annotations.**

# Java language model
-keep class javax.lang.model.** { *; }
-dontwarn javax.lang.model.**

# OkHttp and SSL
-keep class org.bouncycastle.jsse.** { *; }
-keep class org.conscrypt.** { *; }
-keep class org.openjsse.** { *; }
-dontwarn org.bouncycastle.jsse.**
-dontwarn org.conscrypt.**
-dontwarn org.openjsse.**

# Sherpa ONNX
-keep class com.k2fsa.sherpa.onnx.** { *; }

# Keep all native methods
-keepclasseswithmembernames class * {
    native <methods>;
}

# Keep all classes with JNI methods
-keep class * {
    @com.google.protobuf.ProtoField *;
}

# AudioPlayers
-keep class xyz.luan.audioplayers.** { *; }

# Record plugin
-keep class com.llfbandit.record.** { *; }

# File picker
-keep class com.mr.flutter.plugin.filepicker.** { *; }

# Permission handler
-keep class com.baseflow.permissionhandler.** { *; }

# Path provider
-keep class io.flutter.plugins.pathprovider.** { *; }

# Shared preferences
-keep class io.flutter.plugins.sharedpreferences.** { *; }

# Keep all Flutter plugin classes
-keep class io.flutter.plugins.** { *; }

# Keep all enum classes
-keepclassmembers enum * {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}

# Keep all Parcelable classes
-keep class * implements android.os.Parcelable {
    public static final android.os.Parcelable$Creator *;
} 