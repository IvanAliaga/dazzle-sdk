# React Native JSI TurboModule — architecture

Post-beta.3 design note for shipping the **zero-copy hot path** on
React Native. Current beta.3 is shipping `isBlockingSynchronousMethod`
sync bridges, ~15 µs / call — this document covers the <1 µs
endgame.

## Why

The React Native bridge serialises every call as JSON. For a
`dazzleCommand(['HGET', 'k', 'f'])` the round-trip looks like:

```
JS → JSON.stringify(argv)          ~2 µs
   → bridge → Kotlin / ObjC        ~30 µs  (queue + thread hop)
   → decode ReadableArray          ~5 µs
   → DazzleServer.directCommand    ~1 µs
   → encode reply → bridge         ~5 µs
   → back to JS → JSON.parse       ~2 µs
                                   ---------
                                   ~45 µs async, ~15 µs sync
```

For the ChatAgent hot loop (say 50 turns × 3 primitives × per turn)
that's ~2 ms of overhead — noticeable on a moto g35. The native
Kotlin SDK does the same work in ~50 µs.

## JSI removes the serialisation

JSI (JavaScript Interface) is Hermes's / JSC's C++ entry point into
the JS engine. A `HostObject` registered at module install time is
**directly callable from JS** with no bridge, no JSON:

```cpp
class DazzleHostObject : public jsi::HostObject {
public:
  jsi::Value get(jsi::Runtime& rt, const jsi::PropNameID& name) override {
    auto method = name.utf8(rt);
    if (method == "dazzleCommand") {
      return jsi::Function::createFromHostFunction(rt, name, 1,
        [](jsi::Runtime& rt, const jsi::Value&,
           const jsi::Value* args, size_t count) -> jsi::Value {
          // args[0] is jsi::Array — read without JSON.
          auto arr = args[0].asObject(rt).asArray(rt);
          // Call dazzle_direct_command with the pre-split argv.
          std::vector<const char*> argv;
          for (size_t i = 0; i < arr.length(rt); i++) {
            auto s = arr.getValueAtIndex(rt, i).asString(rt).utf8(rt);
            argv.push_back(s.c_str());
          }
          char* reply = dazzle_direct_command(argv.size(), argv.data());
          jsi::Value out = jsi::String::createFromUtf8(rt, reply);
          dazzle_direct_free(reply);
          return out;
        });
    }
    // ... snapHGetAll, snapZRangeByScore, snapSMembers, snapGet, vsSearchDirect
    return jsi::Value::undefined();
  }
};
```

Registered as `globalThis.__dazzle` the first time the module is
initialised — the TypeScript shim already prefers a sync variant
when available.

## Android integration

Adds one C++ TU + CMake target to the plugin:

```
sdk/react-native/dazzle-react-native/android/
├── src/main/java/dev/dazzle/rn/DazzleReactNativeModule.kt
├── src/main/jni/
│   ├── DazzleJSI.cpp      ← HostObject definition
│   └── CMakeLists.txt     ← links libvalkey-server.a + react-native-jsi
└── build.gradle           ← externalNativeBuild { cmake { ... } }
```

The install path:

1. Kotlin `DazzleReactNativeModule` exposes `@ReactMethod fun
   installJsiBindings(): Boolean` — the sync bridge, not on the JS
   thread yet.
2. That JNI-calls `dazzle_jsi_install` with the
   `CatalystInstanceImpl.getJavaScriptContextHolder().get()` runtime
   pointer.
3. The C++ side casts to `jsi::Runtime*`, instantiates the
   HostObject, and calls `runtime.global().setProperty(runtime,
   "__dazzle", ...)`.

Consumer apps call `await DazzleServer.shared.start()` as today —
the install is invoked from inside `start()` once we have a bridge
handle.

## iOS integration

Simpler — RCTBridge already exposes the runtime via
`RCTCxxBridge._runtime` or (in new arch) the TurboModule runtime
executor. The Swift bridge calls `dazzle_jsi_install` with the
runtime pointer on the JS queue.

## Expected perf

On moto g35 5G, measured against the Kotlin SDK:

| Call path                  | Latency / call |
|----------------------------|----------------|
| Kotlin native JNI          |   1–2 µs       |
| Swift native JNI / cshim   |   1–2 µs       |
| **RN JSI (this doc)**      | **1–2 µs**     |
| RN sync bridge (beta.3)    |  15 µs         |
| RN async bridge (pre-beta) | 100 µs         |

## Timeline

- beta.3: sync bridges ship; JSI design doc lands (this file).
- beta.4: JSI binding for `dazzleCommand` + the 4 snap* methods.
  5-7 days of careful work (CMake integration on Android is the
  long pole).
- GA: JSI for every primitive including `VectorIndex.*Direct`.

Consumer-facing API doesn't change: the TS shim already switches
paths based on feature detection, so upgrading is a drop-in.
