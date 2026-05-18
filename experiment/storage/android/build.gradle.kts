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
        applicationId = "dev.dazzle.experiment.storage"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
        // Instrumentation runner for `am instrument` invocation. Tests
        // run with INSTRUMENTATION_PROCESS uid context which EMUI iAware
        // does not throttle the same way it does plain foreground apps.
        // This is the only viable launch path for the §5.9 RAG bench on
        // Kirin 659 / EMUI 9.1.0, where activity-launched runs get
        // demoted to WORKINGSET_BACKGROUND ~10 s after foreground grant
        // regardless of notification importance, app-ops whitelist, or
        // battery whitelist.
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
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
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    // androidTest dependencies for the iAware-bypassing instrumentation
    // entry point (RagE2EBenchTest). Pinned to the same versions as
    // the rest of the SDK demo / sample tree so the test APK stays
    // reproducible across CI / physical-device runs.
    androidTestImplementation("androidx.test:runner:1.6.1")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("junit:junit:4.13.2")
}
