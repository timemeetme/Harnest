# Ktor WebSocket + serialization reflection
-keep class io.ktor.** { *; }
-keep class kotlinx.serialization.** { *; }
-keepattributes *Annotation*, InnerClasses

# Ktor IntellijIdeaDebugDetector references JVM-only classes absent on Android.
# These are never called at runtime on Android — safe to suppress.
-dontwarn java.lang.management.ManagementFactory
-dontwarn java.lang.management.RuntimeMXBean
-dontwarn org.slf4j.impl.StaticLoggerBinder
-dontwarn kotlinx.coroutines.debug.**
-dontwarn kotlinx.coroutines.debug.internal.**
