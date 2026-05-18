# macOS desktop podspec — uses the same in-process libdazzle_lite as
# the Linux / Windows targets.  Bundles the pre-built dylib into the
# app's Frameworks directory so dart:ffi can load it at runtime
# without a host C++ toolchain on consumer machines.

Pod::Spec.new do |s|
  s.name             = 'dazzle_flutter'
  s.version          = '1.0.0-beta.5'
  s.summary          = 'Dazzle SDK for Flutter macOS Desktop (libdazzle_lite via dart:ffi).'
  s.description      = <<-DESC
Dazzle SDK for Flutter on macOS Desktop. Embeds libdazzle_lite — same
HNSW vector search + hash KV the iOS / Android / Web targets ship,
in-process, persisted to disk.
                       DESC
  s.homepage         = 'https://github.com/IvanAliaga/dazzle-sdk'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Ivan Aliaga' => 'ivanaliaga22@gmail.com' }
  s.source           = { :path => '.' }

  s.platform         = :osx, '10.14'
  s.swift_version    = '5.0'

  s.source_files     = 'Classes/**/*'
  s.public_header_files = 'Classes/**/*.h'

  # Bundle the pre-built dylib.  Flutter's macos plugin tooling copies
  # it next to the built executable so dart:ffi resolves the default
  # path "libdazzle_lite.dylib" via @rpath.
  s.vendored_libraries = 'Frameworks/libdazzle_lite.dylib'
  s.preserve_paths     = 'Frameworks/libdazzle_lite.dylib'

  s.dependency 'FlutterMacOS'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE'    => 'YES',
    'OTHER_LDFLAGS'     => '-rpath @executable_path/../Frameworks',
  }
end
