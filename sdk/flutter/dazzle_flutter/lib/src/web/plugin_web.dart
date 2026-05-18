// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Flutter web plugin entry — required by the platforms.web declaration in
// pubspec.yaml. Stays minimal because the public API surface lives in
// `DazzleWeb` (see dazzle_web.dart).  Method-channel calls fall through
// to UnimplementedError on web for the iOS/Android-only primitives.

import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class DazzleWebPlugin {
  static void registerWith(Registrar registrar) {
    DazzleFlutterWebInterface.instance = _DazzleWebStub();
  }
}

/// Platform-interface stub that other parts of the SDK can target.
abstract class DazzleFlutterWebInterface extends PlatformInterface {
  DazzleFlutterWebInterface() : super(token: _token);
  static final Object _token = Object();
  static DazzleFlutterWebInterface _instance = DazzleFlutterWebInterface._stub();
  static DazzleFlutterWebInterface get instance => _instance;
  static set instance(DazzleFlutterWebInterface impl) {
    PlatformInterface.verifyToken(impl, _token);
    _instance = impl;
  }
  factory DazzleFlutterWebInterface._stub() = _DazzleWebStub;
}

class _DazzleWebStub extends DazzleFlutterWebInterface {}
