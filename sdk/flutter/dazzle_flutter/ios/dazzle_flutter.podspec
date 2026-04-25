#
# Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
# SPDX-License-Identifier: Apache-2.0
#
# CocoaPods spec for the dazzle_flutter plugin. Links the prebuilt
# Dazzle.xcframework that sdk/ios/build.sh produces; both native Swift
# consumers and Flutter dart:ffi callers pull the same binary.
#

Pod::Spec.new do |s|
  s.name             = 'dazzle_flutter'
  s.version          = '1.0.0-beta.4'
  s.summary          = 'Dazzle SDK for Flutter — embedded DB + vector search + LLM agents.'
  s.description      = <<-DESC
Embedded, in-process Valkey-based database with vector search (HNSW_SQ8
via NEON SDOT) and ChatAgent runtime for on-device LLM agents. Links
the same Dazzle.xcframework native Swift apps use.
                       DESC
  s.homepage         = 'https://github.com/IvanAliaga/dazzle-sdk'
  s.license          = { :file => '../../../LICENSE' }
  s.author           = { 'Ivan Aliaga' => 'ivan.aliaga@urp.edu.pe' }

  s.source           = { :path => '.' }
  # Ship the Flutter plugin's own Classes AND vendor the Swift + C
  # sources of the Dazzle native iOS SDK so the plugin sees the
  # `DazzleServer`, `DazzleConfig`, etc. types directly. Matches what
  # the native iOS samples do (`project.yml` references `sdk/ios/Sources`).
  # Once the SDK ships as a proper Swift xcframework this collapses
  # back to `s.source_files = 'Classes/**/*'`.
  # CocoaPods requires `source_files` to live inside the pod dir, so
  # we vendor the Dazzle SDK Swift sources + C shim under
  # `Classes/vendored/` via samples/_scripts/link_flutter.sh (it
  # rsyncs sdk/ios/Sources/ and sdk/ios/cshim/). Once the SDK ships as
  # a Swift xcframework, this block collapses back to just
  # `Classes/**/*`.
  s.source_files     = [
    'Classes/**/*.swift',
    'Classes/**/*.c',
    'Classes/**/*.h',
  ]
  s.public_header_files = 'Classes/vendored/include/*.h'

  s.dependency 'Flutter'
  s.platform = :ios, '17.0'

  # Do NOT use `vendored_frameworks` here. Combined with the
  # `-force_load` OTHER_LDFLAGS below it causes 17 duplicate
  # symbols — CocoaPods also auto-links the archive via the
  # xcframework machinery and we end up with the .a pulled in
  # twice. Using `-force_load` alone keeps it to one link pass.

  # System frameworks the Dazzle binary + its static deps (llama.cpp,
  # hnswlib, simsimd) need at link time.
  s.frameworks   = 'Accelerate', 'Metal', 'Foundation'
  s.libraries    = 'c++', 'z', 'sqlite3'

  # pod_target_xcconfig keeps the static library symbols around for
  # dart:ffi process-level lookup AND points the Swift compiler at the
  # DazzleC modulemap packaged inside the xcframework so `import DazzleC`
  # resolves.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE'         => 'YES',
    'STRIP_STYLE'            => 'non-global',
    'DEAD_CODE_STRIPPING'    => 'NO',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'x86_64',
    # Make sure both our Swift glue and the C symbols from the xcframework
    # are visible when `DynamicLibrary.process()` does a runtime lookup.
    # We explicitly pull in libvalkey-server.a from the xcframework slice
    # matching the target SDK because CocoaPods' vendored_frameworks
    # machinery doesn't auto-link static-library xcframeworks reliably.
    # libvalkey-server.a contains duplicate copies of some Redis/Valkey
    # internals (e.g. adlist.o AND lib_adlist.o with identical symbols —
    # an artefact of the Valkey static-link build). -force_load would
    # pull both and generate "17 duplicate symbols"; plain library
    # inclusion (`-l`) lets the linker deduplicate by picking the first
    # archive member that resolves each undefined symbol.
    'OTHER_LDFLAGS'           => '$(inherited) -lvalkey-server',
    # SDK-conditional so the plugin links the matching static slice —
    # device build picks `ios-arm64`, simulator picks
    # `ios-arm64-simulator`. Without this, `flutter build ios
    # --simulator` fails with "built for iOS, linking for
    # iOS-simulator".
    'LIBRARY_SEARCH_PATHS[sdk=iphoneos*]'        => '$(inherited) $(PODS_TARGET_SRCROOT)/Classes/vendored/lib/ios-arm64',
    'LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*]' => '$(inherited) $(PODS_TARGET_SRCROOT)/Classes/vendored/lib/ios-arm64-simulator',
    # Expose the DazzleC C module (Dazzle.xcframework/*/Headers/module.modulemap)
    # to Swift's import resolver and add the headers to the include search
    # paths so it can resolve `import DazzleC`.
    # Point Swift's module-import resolver at the DazzleC modulemap we
    # ship inside Classes/vendored/include/. The rsync step in
    # link_flutter.sh copies dazzle_ios.h alongside it so Swift finds
    # the header when it parses the module.
    'SWIFT_INCLUDE_PATHS'    => '$(inherited) $(PODS_TARGET_SRCROOT)/Classes/vendored/include',
    'HEADER_SEARCH_PATHS'    => '$(inherited) $(PODS_TARGET_SRCROOT)/Classes/vendored/include',
  }

  # Propagate the simulator x86_64 exclusion to the *consumer* app
  # target as well. Without this, Xcode tries to compile the host app
  # for both arm64 and x86_64 simulator slices, the Swift compiler
  # generates `dazzle_flutter-Swift.h` with only the `__arm64__`
  # branch, and the x86_64 slice hits `#error unsupported Swift
  # architecture`. We're on Apple Silicon Macs where Rosetta is not
  # the build path anyone wants — restrict consumers to arm64-sim.
  s.user_target_xcconfig = {
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'x86_64',
  }

  s.swift_version = '5.9'
end
