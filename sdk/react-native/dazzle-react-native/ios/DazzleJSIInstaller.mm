// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Installs the Dazzle JSI HostObject onto the React Native
// `jsi::Runtime*` owned by the bridge. Called from
// DazzleReactNative's -setBridge:, which is the earliest point where
// the runtime is actually live. Silent no-op if the runtime isn't
// available (fall back to the sync bridge).

#import <Foundation/Foundation.h>
#import <React/RCTBridge.h>
#import <React/RCTBridge+Private.h>
#import <objc/message.h>

#import "../cpp/DazzleJSI.h"

// Objective-C wrapper exposed to the rest of the pod. Header-less by
// design — DazzleReactNative.mm calls it via a forward declaration.
@interface DazzleJSIInstaller : NSObject
+ (BOOL)installOnBridge:(RCTBridge *)bridge;
@end

@implementation DazzleJSIInstaller

// `-[RCTCxxBridge runtime]` returns a raw `void *` (the
// `facebook::jsi::Runtime *`). ObjC's `performSelector:` only knows
// about `id` returns, so we go through objc_msgSend with an explicit
// function-pointer cast.
+ (void *)rawRuntimeFromBridge:(RCTBridge *)bridge selector:(SEL)sel
{
  if (![bridge respondsToSelector:sel]) return NULL;
  using Fn = void *(*)(id, SEL);
  return ((Fn)objc_msgSend)(bridge, sel);
}

+ (BOOL)installOnBridge:(RCTBridge *)bridge
{
  if (!bridge) return NO;

  // RN 0.70+ exposes `runtime` on RCTCxxBridge once the bundle is
  // loaded. We try the direct path first; fall back to polling via
  // the CxxBridge class introspection on older versions.
  void *raw = [self rawRuntimeFromBridge:bridge
                                selector:@selector(runtime)];
  if (raw) {
    auto *rt = reinterpret_cast<facebook::jsi::Runtime *>(raw);
    dazzle::installJsi(*rt);
    return YES;
  }
  Class cxxCls = NSClassFromString(@"RCTCxxBridge");
  if (cxxCls && [bridge isKindOfClass:cxxCls]) {
    raw = [self rawRuntimeFromBridge:bridge
                            selector:NSSelectorFromString(@"runtime")];
    if (raw) {
      auto *rt = reinterpret_cast<facebook::jsi::Runtime *>(raw);
      dazzle::installJsi(*rt);
      return YES;
    }
  }
  return NO;
}

@end
