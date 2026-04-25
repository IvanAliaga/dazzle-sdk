allprojects {
    repositories {
        google()
        mavenCentral()
        // Local file-URL maven repo produced by
        // `samples/_scripts/link_flutter.sh android`. Dev flow only —
        // once the Dazzle SDK is on a public Maven this disappears.
        maven {
            url = uri("$rootDir/../../../sdk/android/build/maven-repo")
        }
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
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
