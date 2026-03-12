# ─── App entry point (must not be obfuscated — referenced by AndroidManifest) ─
-keep class com.ione.vpn.** { *; }

# ─── Flutter ──────────────────────────────────────────────────────────────────
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# ─── Google Play Core (referenced by Flutter engine, not used by this app) ────
-dontwarn com.google.android.play.core.splitcompat.SplitCompatApplication
-dontwarn com.google.android.play.core.splitinstall.SplitInstallException
-dontwarn com.google.android.play.core.splitinstall.SplitInstallManager
-dontwarn com.google.android.play.core.splitinstall.SplitInstallManagerFactory
-dontwarn com.google.android.play.core.splitinstall.SplitInstallRequest$Builder
-dontwarn com.google.android.play.core.splitinstall.SplitInstallRequest
-dontwarn com.google.android.play.core.splitinstall.SplitInstallSessionState
-dontwarn com.google.android.play.core.splitinstall.SplitInstallStateUpdatedListener
-dontwarn com.google.android.play.core.tasks.OnFailureListener
-dontwarn com.google.android.play.core.tasks.OnSuccessListener
-dontwarn com.google.android.play.core.tasks.Task

# ─── WireGuard / wireguard_flutter_plus ───────────────────────────────────────
-keep class com.wireguard.** { *; }
-keep interface com.wireguard.** { *; }
-keep class orban.group.wireguard_flutter.** { *; }

# ─── Klaxon (JSON parser used by wireguard_flutter_plus) ──────────────────────
-keep class com.beust.klaxon.** { *; }
-keepclassmembers class com.beust.klaxon.** { *; }
-keepclassmembers class * {
    @com.beust.klaxon.Json *;
}

# ─── Kotlin coroutines ────────────────────────────────────────────────────────
-keepclassmembernames class kotlinx.** {
    volatile <fields>;
}
-keep class kotlinx.coroutines.** { *; }

# ─── Kotlin reflection ────────────────────────────────────────────────────────
-keep class kotlin.reflect.** { *; }
-keep class kotlin.Metadata { *; }
-dontwarn kotlin.reflect.jvm.internal.**

# ─── flutter_secure_storage ───────────────────────────────────────────────────
-keep class com.it_nomads.fluttersecurestorage.** { *; }

# ─── OkHttp / Dio ─────────────────────────────────────────────────────────────
-dontwarn okhttp3.**
-dontwarn okio.**
-keep class okhttp3.** { *; }
-keep interface okhttp3.** { *; }

# ─── General Android safety ───────────────────────────────────────────────────
-keepclasseswithmembernames class * {
    native <methods>;
}
-keepclassmembers class * implements android.os.Parcelable {
    public static final android.os.Parcelable$Creator CREATOR;
}
-keepclassmembers enum * {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}
-dontwarn javax.annotation.**
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**
