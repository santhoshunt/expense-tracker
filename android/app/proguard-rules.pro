# Release shrinking (R8) keeps only what these rules and the libraries' own
# rules name. Flutter's Gradle plugin adds this file to the release build.

# WorkManager opens its Room database by calling the generated
# WorkDatabase_Impl's no-argument constructor through reflection. Room 2.6.1
# keeps the class but not the constructor, so without this rule every start
# crashed in androidx.startup (v1.23.0 and v1.24.0).
-keep class * extends androidx.room.RoomDatabase { <init>(); }

# flutter_local_notifications stores scheduled notifications as JSON and reads
# them back with a Gson TypeToken, which needs the generic signature of its
# anonymous subclass. Without these, rescheduling after a reboot crashed with
# "Missing type parameter".
-keepattributes Signature
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken
