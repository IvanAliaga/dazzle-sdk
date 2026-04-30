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

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

apply(plugin = "io.objectbox")

android {
    namespace = "dev.dazzle.experiment"
    compileSdk = 35

    defaultConfig {
        minSdk = 26
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
        // Benchmarks live in the debug APK but need real optimisation to be
        // meaningful — llama.cpp in CMAKE_BUILD_TYPE=Debug is 10-50× slower
        // than Release. RelWithDebInfo gives `-O2 -g` (optimised + symbols)
        // across every native target (llama, ggml, lmdb-jni, rocksdb-jni,
        // sqlitevec-jni, llamacpp-jni).
        externalNativeBuild {
            cmake {
                arguments += listOf("-DCMAKE_BUILD_TYPE=RelWithDebInfo")
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    // Root-level .kt files live in core/ to avoid including the module root as a
    // srcDir (which would cause Kotlin to compile build.gradle.kts as a source file).
    sourceSets {
        named("main") {
            java.srcDirs(
                "core",      // Dataset, StorageBackend, StorageOnlyTest, ScaleBenchmark
                "dazzle",
                "valkey",
                "sqlite",
                "objectbox",
                "inmemory",
                "lmdb",
                "rocksdb",
            )
            assets.srcDirs("assets")
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

dependencies {
    implementation(rootProject)
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.code.gson:gson:2.11.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
}
