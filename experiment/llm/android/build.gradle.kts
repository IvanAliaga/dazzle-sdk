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
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "dev.dazzle.experiment"
    compileSdk = 35

    defaultConfig {
        applicationId = "dev.dazzle.experiment"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
        // Restrict native build to arm64 — RocksDB's toku_time.h doesn't
        // support x86_64 Android (no rdtsc equivalent defined).
        ndk {
            abiFilters += listOf("arm64-v8a")
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
    implementation(project(":experiment-backends"))
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    implementation("com.google.code.gson:gson:2.11.0")

    // litertlm-android – official Google SDK for Gemma 4 on-device inference
    // Model: gemma-4-E2B-it.litertlm (2.41 GB), download from:
    // huggingface-cli download litert-community/gemma-4-E2B-it-litert-lm gemma-4-E2B-it.litertlm
    implementation("com.google.ai.edge.litertlm:litertlm-android:0.10.0")

    // Coroutines to collect Flow<Message> from sendMessageAsync
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
}
