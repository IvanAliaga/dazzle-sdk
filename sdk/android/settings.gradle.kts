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

pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
@Suppress("UnstableApiUsage")
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

// The root project (sdk/android) IS the Dazzle AAR library module.
// Subprojects:
//   :demo                — SDK demo app (sdk/android/demo/)
//   :samples-chat-*      — public samples
//   :experiment-*        — research apps; only included when the
//                          private `experiment/` checkout is present
//                          alongside this clone (i.e. on the
//                          maintainer's machine or in the private
//                          monorepo). Public consumers don't have
//                          experiment/ and these includes are
//                          skipped silently.
rootProject.name = "dazzle"
include(":demo")

// Conditionally include the research-app modules only when the
// `experiment/` directory is checked out alongside `sdk/android/`
// (two-up: ../../experiment). The public SDK distribution doesn't
// ship `experiment/`; on those clones every `include(":experiment-*")`
// would fail with "project does not exist". Wrapping the includes
// in this guard keeps both layouts buildable from the same file.
val experimentRoot = file("../../experiment")
if (experimentRoot.exists()) {
    include(":experiment-backends")
    project(":experiment-backends").projectDir =
        file("$experimentRoot/backends/android")
    include(":experiment-backends-app")
    project(":experiment-backends-app").projectDir =
        file("$experimentRoot/backends/android-app")
    include(":experiment")
    project(":experiment").projectDir =
        file("$experimentRoot/llm/android")
    include(":experiment-storage")
    project(":experiment-storage").projectDir =
        file("$experimentRoot/storage/android")
    include(":experiment-multiagent")
    project(":experiment-multiagent").projectDir =
        file("$experimentRoot/multiagent/android")
}

// Samples — standalone apps that show how a dev migrates their own
// code onto Dazzle. Each sample picks one of the three retrieval
// patterns (memory / IoT / knowledge base) and lets the user swap
// between the five LLM adapters in a single file.
include(":samples-chat-memory")
project(":samples-chat-memory").projectDir = file("../../samples/chat-memory/android")
include(":samples-chat-iot")
project(":samples-chat-iot").projectDir = file("../../samples/chat-iot/android")
include(":samples-chat-kb")
project(":samples-chat-kb").projectDir = file("../../samples/chat-kb/android")
