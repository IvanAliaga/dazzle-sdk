// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Objective-C++ module that forwards JS calls to the native Swift
// `DazzleServer` living in `vendored/Sources/`. Same API layout as
// the Flutter plugin.

#import "DazzleReactNative.h"
#import <dazzle_react_native-Swift.h>

// Forward declaration — lives in DazzleJSIInstaller.mm.
@interface DazzleJSIInstaller : NSObject
+ (BOOL)installOnBridge:(RCTBridge *)bridge;
@end

@implementation DazzleReactNative

RCT_EXPORT_MODULE(DazzleReactNative)

- (NSArray<NSString *> *)supportedEvents {
  return @[@"onLlamaToken", @"onLiteRtToken", @"onFoundationToken"];
}

+ (BOOL)requiresMainQueueSetup { return NO; }

- (instancetype)init {
  self = [super init];
  if (self) {
    // Plug a weak-self-capturing closure into the Swift LLM bridges
    // so each streamed Delta lands back on `sendEventWithName:body:`.
    // ObjC++ doesn't accept `typeof(self)` — use `__typeof__` / an
    // explicit class name to keep the weak reference alive inside
    // the block.
    __weak DazzleReactNative *weakSelf = self;
    [DazzleLLMBridges shared].emit = ^(NSString *name, NSDictionary *body) {
      DazzleReactNative *strongSelf = weakSelf;
      if (!strongSelf) return;
      [strongSelf sendEventWithName:name body:body];
    };
  }
  return self;
}

- (void)invalidate {
  [DazzleLLMBridges shared].emit = nil;
  [super invalidate];
}

// RN sets `bridge` AFTER `-init`, so this is the earliest spot where
// we can reach the `jsi::Runtime*`. The installer is idempotent —
// re-running on a second setBridge: call is fine.
- (void)setBridge:(RCTBridge *)bridge
{
  [super setBridge:bridge];
  [DazzleJSIInstaller installOnBridge:bridge];
}

// ── Lifecycle ────────────────────────────────────────────────────

RCT_EXPORT_METHOD(start:(NSDictionary *)config
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
  [[DazzleRNBridge shared] startWithConfig:config
                                   resolve:resolve
                                    reject:reject];
}

RCT_EXPORT_METHOD(stop:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
  [[DazzleRNBridge shared] stopWithResolve:resolve reject:reject];
}

RCT_EXPORT_METHOD(isRunning:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
  resolve(@([[DazzleRNBridge shared] isRunning]));
}

RCT_EXPORT_METHOD(waitForReady:(nonnull NSNumber *)timeoutMs
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
  resolve(@([[DazzleRNBridge shared]
              waitForReadyWithTimeoutMs:timeoutMs.intValue]));
}

// ── Commands / snapshot cache ────────────────────────────────────

RCT_EXPORT_METHOD(dazzleCommand:(NSArray<NSString *> *)argv
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
  [[DazzleRNBridge shared] dazzleCommandWithArgv:argv
                                         resolve:resolve
                                          reject:reject];
}

// ── Synchronous hot-path bridge ────────────────────────────────
//
// `dazzleCommand` + the `snap*` family also expose sync variants so
// the JS hot loop doesn't pay the 100 µs async bridge + microtask
// roundtrip on every call. Cuts effective overhead to ~15 µs, with
// the remaining gap vs the native Swift SDK being the JSON
// marshalling across the bridge. For zero-copy, upgrade to JSI
// (see docs/ROADMAP.md).

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(dazzleCommandSync:(NSArray<NSString *> *)argv)
{
  NSString *reply = [[DazzleRNBridge shared] dazzleCommandSyncWithArgv:argv];
  return reply ?: @"";
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(snapHGetAllSync:(NSString *)key)
{
  return [[DazzleRNBridge shared] snapHGetAllSyncWithKey:key];
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(snapZRangeByScoreSync:(NSString *)key
                                        min:(double)min
                                        max:(double)max
                                        maxMembers:(nonnull NSNumber *)maxMembers)
{
  return [[DazzleRNBridge shared]
      snapZRangeByScoreSyncWithKey:key
                               min:min
                               max:max
                        maxMembers:maxMembers.intValue];
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(snapSMembersSync:(NSString *)key
                                        maxMembers:(nonnull NSNumber *)maxMembers)
{
  return [[DazzleRNBridge shared] snapSMembersSyncWithKey:key
                                               maxMembers:maxMembers.intValue];
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(snapGetSync:(NSString *)key)
{
  return [[DazzleRNBridge shared] snapGetSyncWithKey:key];
}

RCT_EXPORT_METHOD(snapHGetAll:(NSString *)key
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
  [[DazzleRNBridge shared] snapHGetAllWithKey:key
                                      resolve:resolve
                                       reject:reject];
}

RCT_EXPORT_METHOD(snapZRangeByScore:(NSString *)key
                  min:(double)min
                  max:(double)max
                  maxMembers:(nonnull NSNumber *)maxMembers
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
  [[DazzleRNBridge shared] snapZRangeByScoreWithKey:key
                                                min:min
                                                max:max
                                         maxMembers:maxMembers.intValue
                                            resolve:resolve
                                             reject:reject];
}

RCT_EXPORT_METHOD(snapSMembers:(NSString *)key
                  maxMembers:(nonnull NSNumber *)maxMembers
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
  [[DazzleRNBridge shared] snapSMembersWithKey:key
                                    maxMembers:maxMembers.intValue
                                       resolve:resolve
                                        reject:reject];
}

RCT_EXPORT_METHOD(snapGet:(NSString *)key
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
  [[DazzleRNBridge shared] snapGetWithKey:key resolve:resolve reject:reject];
}

// ── Vector index ─────────────────────────────────────────────────

RCT_EXPORT_METHOD(vsCreate:(NSDictionary *)opts
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
  [[DazzleRNBridge shared] vsCreateWithOpts:opts resolve:resolve reject:reject];
}

RCT_EXPORT_METHOD(vsAddDirect:(NSString *)name
                  id:(NSString *)_id
                  vector:(NSArray<NSNumber *> *)vector
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
  [[DazzleRNBridge shared] vsAddDirectWithName:name
                                            id:_id
                                        vector:vector
                                       resolve:resolve
                                        reject:reject];
}

RCT_EXPORT_METHOD(vsAddBatchDirect:(NSString *)name
                  ids:(NSArray<NSString *> *)ids
                  flat:(NSArray<NSNumber *> *)flat
                  dim:(nonnull NSNumber *)dim
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
  [[DazzleRNBridge shared] vsAddBatchDirectWithName:name
                                                ids:ids
                                               flat:flat
                                                dim:dim.intValue
                                            resolve:resolve
                                             reject:reject];
}

RCT_EXPORT_METHOD(vsSearchDirect:(NSString *)name
                  query:(NSArray<NSNumber *> *)query
                  k:(nonnull NSNumber *)k
                  efRuntime:(nonnull NSNumber *)ef
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
  [[DazzleRNBridge shared] vsSearchDirectWithName:name
                                            query:query
                                                k:k.intValue
                                        efRuntime:ef.intValue
                                          resolve:resolve
                                           reject:reject];
}

// ── LLM adapters — real bridges into the native Swift SDK ──────

RCT_EXPORT_METHOD(llamaCreate:(NSDictionary *)opts
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
  [[DazzleLLMBridges shared] llamaCreateWithOpts:opts
                                         resolve:resolve
                                          reject:reject];
}
RCT_EXPORT_METHOD(llamaGenerate:(NSDictionary *)opts
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
  [[DazzleLLMBridges shared] llamaGenerateWithOpts:opts
                                           resolve:resolve
                                            reject:reject];
}
RCT_EXPORT_METHOD(llamaClose:(nonnull NSNumber *)handle
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
  [[DazzleLLMBridges shared] llamaCloseWithHandle:handle
                                          resolve:resolve
                                           reject:reject];
}

// LiteRT-LM is Android-only; the Swift side delegates to the same
// reject block so the JS-side `LiteRtLmClient` surfaces a clear error
// instead of appearing to work and then hanging forever.
RCT_EXPORT_METHOD(liteRtCreate:(NSDictionary *)opts
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
  reject(@"LITERT_UNAVAILABLE",
         @"LiteRtLmClient is Android-only today — use LlamaCppClient or "
         @"FoundationModelsClient on iOS.", nil);
}
RCT_EXPORT_METHOD(liteRtGenerate:(NSDictionary *)opts
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
  reject(@"LITERT_UNAVAILABLE",
         @"LiteRtLmClient is Android-only today.", nil);
}
RCT_EXPORT_METHOD(liteRtClose:(nonnull NSNumber *)handle
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) { resolve(nil); }

RCT_EXPORT_METHOD(fmIsAvailable:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
  [[DazzleLLMBridges shared] fmIsAvailableWithResolve:resolve
                                                reject:reject];
}

RCT_EXPORT_METHOD(fmGenerate:(NSDictionary *)opts
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
  [[DazzleLLMBridges shared] fmGenerateWithOpts:opts
                                        resolve:resolve
                                         reject:reject];
}

// ── Sample-test helpers ────────────────────────────────────────

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(getEnv:(NSString *)name)
{
  const char *v = getenv([name UTF8String]);
  if (v == NULL) return (NSString *)kCFNull;
  return @(v);
}

RCT_EXPORT_METHOD(writeReport:(NSString *)name
                  json:(NSString *)json
                  marker:(NSString *)marker
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
  NSError *error = nil;
  NSArray *paths = NSSearchPathForDirectoriesInDomains(
      NSDocumentDirectory, NSUserDomainMask, YES);
  if (paths.count == 0) {
    reject(@"WRITE_REPORT_FAILED", @"no Documents dir", nil);
    return;
  }
  NSString *dir = paths[0];
  NSString *jsonPath = [dir stringByAppendingPathComponent:
      [NSString stringWithFormat:@"sample_test_%@.json", name]];
  NSString *markerPath = [dir stringByAppendingPathComponent:
      @"experiment_backends_complete.marker"];
  [json writeToFile:jsonPath atomically:YES
           encoding:NSUTF8StringEncoding error:&error];
  if (error) {
    reject(@"WRITE_REPORT_FAILED", error.localizedDescription, error);
    return;
  }
  [marker writeToFile:markerPath atomically:YES
             encoding:NSUTF8StringEncoding error:&error];
  if (error) {
    reject(@"WRITE_REPORT_FAILED", error.localizedDescription, error);
    return;
  }
  resolve(nil);
}

// Kill the app process after the sample-test harness finishes so the
// next launch (springboard tap, devicectl, whatever) doesn't resume
// on the "Sample test completed" screen. Apple discourages `exit()`
// in production apps; for a headless-test sample shell this is
// fine and mirrors what flutter run --dart-define=SAMPLE_TEST=1 does.
RCT_EXPORT_METHOD(exitProcess:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
  resolve(nil);
  dispatch_after(
    dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
    dispatch_get_main_queue(), ^{
      exit(0);
    });
}

@end
