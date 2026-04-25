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
}

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

    // Expose the debug + release variants to the local Maven repo so
    // the Flutter plugin (which is itself an AAR and therefore can't
    // consume another AAR as a direct file dep) can reference us via
    // `implementation "dev.dazzle:dazzle-sdk:<version>"`.
    publishing {
        singleVariant("debug") { withSourcesJar() }
        singleVariant("release") { withSourcesJar() }
    }
}

afterEvaluate {
    publishing {
        publications {
            register<MavenPublication>("debug") {
                from(components["debug"])
                groupId    = "dev.dazzle"
                artifactId = "dazzle-sdk"
                version    = "1.0.0-beta.3"
            }
            register<MavenPublication>("release") {
                from(components["release"])
                groupId    = "dev.dazzle"
                artifactId = "dazzle-sdk"
                version    = "1.0.0-beta.3"
            }
        }
        repositories {
            maven {
                name = "LocalFileRepo"
                url  = uri("${rootProject.layout.buildDirectory.get()}/maven-repo")
            }
        }
    }
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
