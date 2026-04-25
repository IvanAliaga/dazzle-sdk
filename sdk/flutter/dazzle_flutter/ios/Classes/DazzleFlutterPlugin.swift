// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// iOS side of dazzle_flutter. Register the method channel, forward
// start/stop/waitForReady/isRunning calls to `DazzleServer.shared` —
// the exact same API the native Swift SDK consumers use.

import Flutter
import Foundation

@objc public class DazzleFlutterPlugin: NSObject, FlutterPlugin {

    // Retained for the lifetime of the plugin so the bridge's channel
    // delegates don't get deallocated mid-stream.
    private static var fmBridge: AnyObject?
    private static var anthropicBridge: AnyObject?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "dev.dazzle.flutter",
            binaryMessenger: registrar.messenger()
        )
        let instance = DazzleFlutterPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)

        // Apple Foundation Models bridge — iOS/macOS 26+ only. On
        // older OSes we register a stub that replies `false` to the
        // `isAvailable` probe so Dart-side callers fall back cleanly.
        if #available(iOS 26.0, macOS 26.0, *) {
            fmBridge = FoundationModelsBridge(messenger: registrar.messenger())
        } else {
            let stub = FlutterMethodChannel(
                name: "dev.dazzle.flutter/foundation",
                binaryMessenger: registrar.messenger())
            stub.setMethodCallHandler { call, result in
                if call.method == "isAvailable" { result(false) }
                else { result(FlutterMethodNotImplemented) }
            }
        }

        // Anthropic bridge — works on all iOS versions; dormant
        // until the Dart-side `AnthropicClient` constructor invokes
        // `create`. Uses `URLSession` directly, no extra deps.
        anthropicBridge = AnthropicBridge(messenger: registrar.messenger())
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "start":      handleStart(call, result)
        case "stop":       handleStop(result)
        case "waitForReady": handleWaitForReady(call, result)
        case "isRunning":  result(DazzleServer.shared.isRunning)
        default:           result(FlutterMethodNotImplemented)
        }
    }

    // MARK: – Method handlers

    private func handleStart(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        do {
            if DazzleServer.shared.isRunning {
                result(nil); return
            }
            let cfg = parseConfig(call.arguments as? [String: Any])
            try DazzleServer.shared.start(config: cfg)
            result(nil)
        } catch {
            result(FlutterError(
                code: "DAZZLE_START_FAILED",
                message: "\(error)",
                details: nil
            ))
        }
    }

    private func handleStop(_ result: @escaping FlutterResult) {
        if DazzleServer.shared.isRunning {
            DazzleServer.shared.stop()
        }
        result(nil)
    }

    private func handleWaitForReady(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        let timeoutMs = args?["timeoutMs"] as? Int ?? 5000
        let ok = DazzleServer.shared.waitForReady(timeout: TimeInterval(timeoutMs) / 1000.0)
        result(ok)
    }

    // MARK: – Config parsing

    private func parseConfig(_ m: [String: Any]?) -> DazzleConfig {
        guard let m = m else { return DazzleConfig() }

        let maxMemory = (m["maxMemory"] as? String) ?? "64mb"

        let modules: Set<DazzleModule> = {
            let arr = m["modules"] as? [String] ?? []
            var set = Set<DazzleModule>()
            if arr.contains("vectorSearch") { set.insert(.vectorSearch) }
            return set
        }()

        let wipe: WipeTarget = {
            let arr = m["wipeOnStart"] as? [String] ?? []
            var opts: WipeTarget = []
            if arr.contains("aof") { opts.insert(.aof) }
            if arr.contains("rdb") { opts.insert(.rdb) }
            return opts
        }()

        let persistence: DazzlePersistence = {
            guard let p = m["persistence"] as? [String: Any] else { return .aof() }
            switch p["kind"] as? String {
            case "none": return .none
            case "rdb":  return .rdb()
            default:
                let fsync: AppendFsync
                switch p["fsync"] as? String {
                case "always": fsync = .always
                case "no":     fsync = .no
                default:       fsync = .everysec
                }
                return .aof(fsync: fsync)
            }
        }()

        return DazzleConfig(
            maxMemory:   maxMemory,
            persistence: persistence,
            wipeOnStart: wipe,
            modules:     modules
        )
    }
}
