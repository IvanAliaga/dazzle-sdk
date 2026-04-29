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

/// Namespace for Paper 2 (TFI) use-case variant types.
///
/// Used to keep the Paper 2 pipeline, view, storage-only harness and their
/// supporting record types (AnomalyDecision, RiskPrediction, CheckpointResult,
/// ReportScore, GroundTruth, SynthesisScore, SynthesisResult, ExperimentResults)
/// from colliding at the top level with the main baseline and the Valkey 8
/// precursor variant — all three sets of files coexist in the DazzleExperiment
/// target post-merge.
///
/// Paper-2-specific source files wrap their declarations in `extension Paper2 {}`
/// so the enclosing scope provides uniqueness without forcing every type to be
/// renamed individually. Intra-namespace references resolve without a prefix;
/// cross-namespace references use the qualified form (e.g. `Paper2.ExperimentView`).
enum Paper2 {}
