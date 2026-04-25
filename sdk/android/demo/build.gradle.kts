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
    // Compose compiler plugin — required since Kotlin 2.0 for all
    // modules that consume `androidx.compose.*` APIs.
    id("org.jetbrains.kotlin.plugin.compose") version "2.2.21"
}

android {
    namespace = "dev.dazzle.demo"
    compileSdk = 35

    defaultConfig {
        applicationId = "dev.dazzle.demo"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
    }

    buildFeatures {
        // Enables the chat screen (`ChatActivity.kt`) which is Compose-
        // based. The legacy MainActivity keeps the Views path.
        compose = true
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
    implementation("com.google.android.material:material:1.12.0")

    // Compose for the ChatActivity screen. BOM pins every compose-* dep
    // so version bumps stay coherent.
    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")

    // Debug-only tooling — enables @Preview + the inspector without
    // bloating release builds.
    debugImplementation("androidx.compose.ui:ui-tooling")
}
