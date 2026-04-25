#
# Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
# SPDX-License-Identifier: Apache-2.0
#
# CocoaPods spec for dazzle-react-native — mirrors the Flutter plugin's
# podspec. The native Dazzle iOS SDK lives as Swift sources +
# libvalkey-server.a (static archive from sdk/ios/build.sh).
# samples/_scripts/link_rn.sh rsyncs sdk/ios/Sources + cshim + the
# archive into ios/vendored/ before `pod install` runs.
#
# The `cpp/DazzleJSI.cpp` HostObject installs `globalThis.__dazzle`
# once the RN bridge exposes its `jsi::Runtime*` — ~1 µs hot path vs
# ~15 µs via the sync bridge.

require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name             = "dazzle-react-native"
  s.version          = package["version"]
  s.summary          = package["description"]
  s.description      = package["description"]
  s.homepage         = package["repository"]
  s.license          = { :type => "Apache-2.0" }
  s.author           = { "Ivan Aliaga" => "ivan.aliaga@urp.edu.pe" }
  s.source           = { :path => "." }

  s.platforms = { :ios => "17.0" }
  s.source_files     = [
    "ios/**/*.{h,m,mm,swift}",
    "ios/vendored/Sources/**/*.swift",
    "ios/vendored/dazzle_ios.c",
    "ios/vendored/include/*.h",
    "cpp/**/*.{h,cpp}",
  ]
  s.public_header_files = "ios/vendored/include/*.h"

  s.dependency "React-Core"
  s.dependency "React-jsi"
  s.frameworks  = "Accelerate", "Metal", "Foundation"
  s.libraries   = "c++", "z", "sqlite3"

  s.pod_target_xcconfig = {
    "DEFINES_MODULE"         => "YES",
    "STRIP_STYLE"            => "non-global",
    "DEAD_CODE_STRIPPING"    => "NO",
    "EXCLUDED_ARCHS[sdk=iphonesimulator*]" => "x86_64",
    "SWIFT_INCLUDE_PATHS"    => "$(inherited) $(PODS_TARGET_SRCROOT)/ios/vendored/include",
    # React-jsi headers are placed under `Pods/Headers/Public/React-jsi`
    # by the RN podfile; the cpp/ source needs them + the vendored
    # Dazzle headers on the include path.
    "HEADER_SEARCH_PATHS"    => '$(inherited) $(PODS_TARGET_SRCROOT)/ios/vendored/include $(PODS_TARGET_SRCROOT)/cpp "$(PODS_ROOT)/Headers/Public/React-jsi"',
    "CLANG_CXX_LANGUAGE_STANDARD" => "c++17",
    "CLANG_CXX_LIBRARY"      => "libc++",
    "SWIFT_VERSION"          => "5.9",
  }
  # The host app target links the final executable, so the linker
  # flags + search path for libvalkey-server must be exposed to the
  # CONSUMER, not just this pod.
  s.user_target_xcconfig = {
    "OTHER_LDFLAGS"        => "$(inherited) -lvalkey-server",
    "LIBRARY_SEARCH_PATHS" => "$(inherited) $(PODS_ROOT)/../../../../sdk/react-native/dazzle-react-native/ios/vendored/lib/ios-arm64",
  }
end
