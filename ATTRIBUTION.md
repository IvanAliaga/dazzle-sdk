# Attribution / Atribuciones

Dazzle is built on top of [Valkey](https://valkey.io/), an open-source,
in-memory data store governed by the Linux Foundation. Portions of the
Dazzle codebase — specifically the Valkey server core downloaded by
`sdk/android/src/main/cpp/CMakeLists.txt` and `sdk/ios/build.sh`, plus
the build-time patches in `versions/` — are derivative works of
Valkey and remain under the Valkey license.

Dazzle se construye sobre [Valkey](https://valkey.io/), un almacén de
datos en memoria open-source bajo gobernanza de la Linux Foundation.
Partes del código de Dazzle — en concreto el núcleo Valkey que
descargan `sdk/android/src/main/cpp/CMakeLists.txt` y
`sdk/ios/build.sh`, junto con los parches en `versions/` — son obras
derivadas de Valkey y conservan su licencia original.

---

## Valkey — BSD 3-Clause License

```
Copyright (c) 2024-present, Valkey contributors.
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

 * Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.
 * Neither the name of Valkey nor the names of its contributors may be used
   to endorse or promote products derived from this software without specific
   prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
THE POSSIBILITY OF SUCH DAMAGE.
```

Upstream source / fuente original: <https://github.com/valkey-io/valkey>

---

## What Dazzle adds / Qué añade Dazzle

Nothing in Dazzle's own codebase copies Valkey source verbatim. The
Valkey core is fetched at build time (`FetchContent` on Android,
`git clone` on iOS) and patched with the diffs under `versions/`.

Lo que sí es original de Dazzle y está bajo Apache-2.0 (ver
[LICENSE](LICENSE)):

- `core/transport/` — the new I/O pipeline (pipe → SPSC ring → io_uring)
- `core/cache/` — snapshot cache for lock-free reads
- `core/platform/` — iOS bridge (dazzle_ios.c/h)
- `core/compat/` — v8/v9/v10+ shims
- `sdk/android/` — AAR library + demo app (JNI + Kotlin)
- `sdk/ios/` — XCFramework + Swift API + demo app
- `sdk/flutter/dazzle_flutter/` — Flutter plugin (Dart + dart:ffi + bridges)
- `sdk/react-native/dazzle-react-native/` — RN package (TS + JSI / NativeModule)
- `samples/` — twelve production-shaped chat samples
- `versions/*/patches/*.patch` — build-time patches applied to the
  upstream Valkey tree (these are derivative works distributed under
  the Valkey license; redistributing them is allowed because we ship
  only the *diffs*, not the patched source).

Ni `core/` ni `sdk/` copian código Valkey línea a línea. Se descarga
upstream en build time y se parchea in situ.

---

## Trademarks / Marcas

"Valkey" is a trademark of the Linux Foundation. Dazzle does not use
the Valkey mark in its name, logos, or marketing except in factual
statements about the underlying dependency (e.g. "built on Valkey" in
this README).

"Valkey" es una marca de la Linux Foundation. Dazzle no usa esta marca
en su nombre ni en materiales de marketing salvo como referencia
factual a la dependencia subyacente.

---

## llama.cpp — MIT License

Dazzle's `LlamaCppClient` adapter links llama.cpp at build time
through the Android `sdk/android/src/main/cpp/CMakeLists.txt`
`FetchContent` block. llama.cpp is licensed under MIT and remains
so; Dazzle's JNI shim + Kotlin / Swift / Dart / TS wrappers are
Apache-2.0.

```
MIT License

Copyright (c) 2023-2024 The ggml authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

Upstream source / fuente original: <https://github.com/ggerganov/llama.cpp>
