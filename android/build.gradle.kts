allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// A compileSdk floor of 36 for every plugin. `androidx.credentials`
// (passkey sign-in, via passkeys_android) and
// `flutter_plugin_android_lifecycle` require modules that depend on them
// to compile against API 36, and some plugins pin a lower compileSdk in
// their own build.gradle, which Gradle refuses at
// `checkDebugAarMetadata`. compileSdk only decides which APIs code may
// call; targetSdk (runtime behaviour) is untouched. A floor: nothing is
// lowered. Reflection, so it depends on no AGP type. Same as iAkauntan's.
subprojects {
    afterEvaluate {
        val android = extensions.findByName("android")
        if (android != null) {
            val floor = 36
            val getter = android.javaClass.methods.single {
                it.name == "getCompileSdk" && it.parameterCount == 0
            }
            val setter = android.javaClass.methods.single {
                it.name == "setCompileSdk" && it.parameterCount == 1 &&
                    (it.parameterTypes[0] == Integer::class.java ||
                        it.parameterTypes[0] == Int::class.javaPrimitiveType)
            }
            val current = getter.invoke(android) as? Int
            if (current == null || current < floor) {
                setter.invoke(android, floor)
                logger.info("compileSdk raised to $floor for ${project.name}")
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
