// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import com.vanniktech.maven.publish.AndroidSingleVariantLibrary
import com.vanniktech.maven.publish.SonatypeHost

buildscript {
    dependencies {
        classpath("io.objectbox:objectbox-gradle-plugin:5.4.1")
    }
}

plugins {
    id("com.android.library") version "8.7.3"
    id("org.jetbrains.kotlin.android") version "2.2.21"
    id("com.android.application") version "8.7.3" apply false
    `maven-publish`
    // Vanniktech's plugin wraps Sonatype Central Portal upload + GPG
    // signing + POM generation. The legacy `nexus-publish` flow no
    // longer works with the new Central Portal endpoint introduced
    // in 2024. See https://vanniktech.github.io/gradle-maven-publish-plugin/
    id("com.vanniktech.maven.publish") version "0.30.0"
}

// Library coordinates — these are the strings users put into their
// `build.gradle.kts`:
//
//     implementation("com.ivanaliaga:dazzle-sdk:1.0.0-beta.5")
//
// `com.ivanaliaga` is the reverse-DNS of the maintainer's domain
// (verified via DNS TXT record on Sonatype Central Portal).
val dazzleGroupId = "com.ivanaliaga"
val dazzleArtifactId = "dazzle-sdk"
val dazzleVersion = "1.0.0-beta.6"

group = dazzleGroupId
version = dazzleVersion

android {
    namespace = "dev.dazzle.sdk"
    compileSdk = 35

    defaultConfig {
        minSdk = 26
        // Required so `./gradlew connectedAndroidTest` knows which runner to
        // invoke on the device. androidTest sources live in src/androidTest/.
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
        externalNativeBuild {
            cmake {
                cppFlags += ""
                arguments += listOf(
                    // c++_static: libdazzle.so now statically links the entire
                    // C++ runtime because the valkey-search module (hnswlib +
                    // simsimd) compiles into it. Keeping the runtime static
                    // keeps the APK self-contained with no external libc++
                    // dependency — mirrors the iOS xcframework posture.
                    "-DANDROID_STL=c++_static",
                    "-DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON"
                )
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

// ── Maven Central publishing — Vanniktech plugin ────────────────────
//
// This block configures the artefacts that `./gradlew
// publishToMavenCentral` will produce + upload to the Sonatype
// Central Portal. The plugin handles:
//   1. Generating sourcesJar + javadocJar.
//   2. Generating a POM with all the metadata Maven Central requires
//      (license, developers, SCM, description, URL).
//   3. Signing every artefact with the configured GPG key.
//   4. Bundling the result and POSTing it to the Central Portal.
//
// Credentials come from `~/.gradle/gradle.properties` (NEVER commit):
//
//     mavenCentralUsername=<sonatype-token-username>
//     mavenCentralPassword=<sonatype-token-password>
//     signingInMemoryKey=<armored GPG private key, \n-encoded>
//     signingInMemoryKeyId=<last 8 hex chars of GPG key ID>
//     signingInMemoryKeyPassword=<GPG passphrase>
//
// First-time setup walkthrough lives in PUBLISHING.md at the repo root.

mavenPublishing {
    // Sonatype Central Portal — the new endpoint (replaces s01.oss.sonatype.org).
    // `automaticRelease = false` means each push lands in a manual-review
    // staging area; flip to `true` once the first publish has been validated
    // and you trust the CI pipeline.
    publishToMavenCentral(SonatypeHost.CENTRAL_PORTAL, automaticRelease = false)
    signAllPublications()

    coordinates(dazzleGroupId, dazzleArtifactId, dazzleVersion)

    configure(AndroidSingleVariantLibrary(
        variant = "release",
        sourcesJar = true,
        // AGP's javaDocReleaseGeneration runs Dokka, which uses an ASM
        // version that can't read sealed classes (PermittedSubclasses
        // attribute). litertlm-android:0.10.0's `Backend.class` is a
        // Java 17 sealed class, so the task crashes:
        //   UnsupportedOperationException: PermittedSubclasses requires ASM9
        // We turn off the auto-Javadoc and attach an empty javadoc.jar
        // below — Sonatype Central only requires the artefact to exist.
        publishJavadocJar = false,
    ))

    pom {
        name.set("Dazzle SDK")
        description.set(
            "Embedded, in-process database for on-device LLM agents on " +
            "Android. Forks Valkey 9 and runs the server inside the app " +
            "process — no TCP loopback, no daemon. Includes typed " +
            "primitives, snapshot cache, HNSW vector search, ChatAgent " +
            "runtime, and five swappable LLMClient adapters."
        )
        inceptionYear.set("2026")
        url.set("https://github.com/IvanAliaga/dazzle-sdk")
        licenses {
            license {
                name.set("The Apache License, Version 2.0")
                url.set("https://www.apache.org/licenses/LICENSE-2.0.txt")
                distribution.set("repo")
            }
        }
        developers {
            developer {
                id.set("IvanAliaga")
                name.set("Ivan Aliaga")
                email.set("ivanaliaga22@gmail.com")
                url.set("https://github.com/IvanAliaga")
            }
        }
        scm {
            url.set("https://github.com/IvanAliaga/dazzle-sdk")
            connection.set("scm:git:git://github.com/IvanAliaga/dazzle-sdk.git")
            developerConnection.set("scm:git:ssh://git@github.com/IvanAliaga/dazzle-sdk.git")
        }
        issueManagement {
            system.set("GitHub Issues")
            url.set("https://github.com/IvanAliaga/dazzle-sdk/issues")
        }
    }
}

// ── Local-file Maven repo (for the Flutter plugin + RN package) ─────
//
// These plugins consume the AAR via `implementation
// "com.ivanaliaga:dazzle-sdk:<version>"` resolved from a repo-local
// file:// Maven mirror. Run:
//
//     ./gradlew publishToLocalFileRepoRepository
//
// to populate `sdk/android/build/maven-repo/` so a sibling Flutter /
// RN build can resolve us without the Central Portal round-trip.

// Empty placeholder javadoc.jar required by Sonatype Central — the
// AGP/Dokka pipeline can't generate a real one (see comment on
// `publishJavadocJar = false` above). Attached to the `maven`
// publication that Vanniktech created so it ends up in both the
// Central upload bundle and the local file-repo mirror.
val emptyJavadocJar = tasks.register<Jar>("emptyJavadocJar") {
    archiveClassifier.set("javadoc")
}

afterEvaluate {
    publishing {
        publications {
            named<MavenPublication>("maven") {
                artifact(emptyJavadocJar)
            }
            // Mirror the same release publication as the Central one,
            // keyed by the Vanniktech plugin under the same groupId so
            // local consumers see the artefact at exactly the same
            // coordinate as Maven Central does.
            register<MavenPublication>("localRelease") {
                from(components["release"])
                groupId    = dazzleGroupId
                artifactId = dazzleArtifactId
                version    = dazzleVersion
                artifact(emptyJavadocJar)
            }
        }
        repositories {
            maven {
                name = "LocalFileRepo"
                url  = uri("${rootProject.layout.buildDirectory.get()}/maven-repo")
            }
        }
    }

    // Gradle 8.9 implicit-dependency check: every publish task that
    // consumes the AAR signature has to declare the producer
    // explicitly. The `localRelease` publication reuses the artefacts
    // signed by `signMavenPublication` (Vanniktech), so wire all four
    // local publish tasks to depend on it.
    tasks.matching { it.name.startsWith("publishLocalReleasePublication") }
        .configureEach { dependsOn("signMavenPublication") }
    tasks.matching { it.name.startsWith("publishMavenPublication") }
        .configureEach { dependsOn("signLocalReleasePublication") }
}

dependencies {
    implementation("androidx.annotation:annotation:1.9.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")

    // LiteRT-LM runtime — `compileOnly` so the Dazzle AAR stays slim.
    // Consumers that actually instantiate `LiteRtLmClient(...)` must add
    //
    //     implementation("com.google.ai.edge.litertlm:litertlm-android:0.10.0")
    //
    // to THEIR app's build.gradle. Consumers that bring their own LLM
    // (cloud API, llama.cpp, Foundation Models, …) pay zero cost here.
    compileOnly("com.google.ai.edge.litertlm:litertlm-android:0.10.0")

    // Instrumented tests (src/androidTest/) — run on a connected device so the
    // JNI-backed libdazzle.so is loaded from the installed test APK. JVM unit
    // tests would need a mock because the primitives all route through JNI.
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:rules:1.6.1")
    androidTestImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")

    // Instrumented tests need the runtime impl because `compileOnly`
    // above doesn't provide one at test-run time.
    androidTestImplementation("com.google.ai.edge.litertlm:litertlm-android:0.10.0")
}
