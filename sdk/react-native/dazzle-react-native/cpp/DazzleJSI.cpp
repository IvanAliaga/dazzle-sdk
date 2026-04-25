// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0

#include "DazzleJSI.h"

#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

// ── C symbols provided by libvalkey-server (shipped inside the
//    Dazzle AAR on Android, inside libvalkey-server.a on iOS). Declared
//    `weak` so this library links even if the consumer hasn't pulled
//    the Dazzle runtime yet — a dlsym lookup at first call decides.
extern "C" {

__attribute__((weak)) char *valkey_direct_command(int argc, const char **argv);
__attribute__((weak)) void  valkey_direct_free(char *result);
__attribute__((weak)) int   dazzle_snapshot_hgetall_typed(
    const char *key, char **out_fields, char **out_values, int max_pairs);
__attribute__((weak)) int   dazzle_snapshot_smembers_typed(
    const char *key, char **out_members, int max_members);
__attribute__((weak)) int   dazzle_snapshot_zrange_by_score_typed(
    const char *key, double min_score, double max_score,
    char **out_members, int max_members);
__attribute__((weak)) int   dazzle_snapshot_get_string_typed(
    const char *key, char *out, int cap);

} // extern "C"

using namespace facebook::jsi;

namespace {

// Convert argv[i].asArray.getValueAtIndex(i).asString -> owned
// std::vector<std::string>. The raw pointer vector lives alongside so
// the C API can take `const char **`.
struct Argv {
    std::vector<std::string> owned;
    std::vector<const char *> ptrs;
};

Argv buildArgv(Runtime &rt, const Value &arg) {
    Argv out;
    auto arr = arg.asObject(rt).asArray(rt);
    auto len = arr.length(rt);
    out.owned.reserve(len);
    out.ptrs.reserve(len);
    for (size_t i = 0; i < len; i++) {
        out.owned.push_back(
            arr.getValueAtIndex(rt, i).asString(rt).utf8(rt));
        out.ptrs.push_back(out.owned.back().c_str());
    }
    return out;
}

Value makeDazzleCommand(Runtime &rt) {
    return Function::createFromHostFunction(
        rt, PropNameID::forAscii(rt, "dazzleCommand"), 1,
        [](Runtime &rt, const Value &, const Value *args,
           size_t count) -> Value {
            if (!valkey_direct_command || !valkey_direct_free) {
                throw JSError(rt,
                    "Dazzle native runtime not linked — call "
                    "DazzleServer.start() first or add the Dazzle "
                    "Android AAR / iOS xcframework to the app target.");
            }
            if (count < 1 || !args[0].isObject()) {
                throw JSError(rt, "dazzleCommand expects an argv array");
            }
            Argv argv = buildArgv(rt, args[0]);
            char *reply = valkey_direct_command(
                static_cast<int>(argv.ptrs.size()), argv.ptrs.data());
            if (!reply) return Value::undefined();
            auto s = String::createFromUtf8(rt, reply);
            valkey_direct_free(reply);
            return Value(rt, s);
        });
}

// Returns a flattened [f0, v0, f1, v1, ...] array, or null on miss.
Value makeSnapHGetAll(Runtime &rt) {
    return Function::createFromHostFunction(
        rt, PropNameID::forAscii(rt, "snapHGetAll"), 1,
        [](Runtime &rt, const Value &, const Value *args,
           size_t count) -> Value {
            if (!dazzle_snapshot_hgetall_typed) return Value::null();
            if (count < 1 || !args[0].isString()) {
                throw JSError(rt, "snapHGetAll expects a key string");
            }
            auto key = args[0].asString(rt).utf8(rt);
            static constexpr int kMax = 64;
            char *fields[kMax] = {nullptr};
            char *values[kMax] = {nullptr};
            int n = dazzle_snapshot_hgetall_typed(
                key.c_str(), fields, values, kMax);
            if (n < 0) return Value::null();
            auto out = Array(rt, static_cast<size_t>(n) * 2);
            for (int i = 0; i < n; i++) {
                out.setValueAtIndex(rt, static_cast<size_t>(i) * 2,
                    String::createFromUtf8(rt, fields[i] ? fields[i] : ""));
                out.setValueAtIndex(rt, static_cast<size_t>(i) * 2 + 1,
                    String::createFromUtf8(rt, values[i] ? values[i] : ""));
                if (fields[i] && valkey_direct_free) valkey_direct_free(fields[i]);
                if (values[i] && valkey_direct_free) valkey_direct_free(values[i]);
            }
            return Value(rt, out);
        });
}

Value makeSnapZRangeByScore(Runtime &rt) {
    return Function::createFromHostFunction(
        rt, PropNameID::forAscii(rt, "snapZRangeByScore"), 4,
        [](Runtime &rt, const Value &, const Value *args,
           size_t count) -> Value {
            if (!dazzle_snapshot_zrange_by_score_typed) return Value::null();
            if (count < 4) {
                throw JSError(rt,
                    "snapZRangeByScore expects (key, min, max, maxMembers)");
            }
            auto key = args[0].asString(rt).utf8(rt);
            double min = args[1].asNumber();
            double max = args[2].asNumber();
            int maxMembers =
                static_cast<int>(args[3].asNumber());
            if (maxMembers <= 0) maxMembers = 1;
            if (maxMembers > 1024) maxMembers = 1024;
            std::vector<char *> members(
                static_cast<size_t>(maxMembers), nullptr);
            int n = dazzle_snapshot_zrange_by_score_typed(
                key.c_str(), min, max, members.data(), maxMembers);
            if (n < 0) return Value::null();
            auto out = Array(rt, static_cast<size_t>(n));
            for (int i = 0; i < n; i++) {
                out.setValueAtIndex(rt, i,
                    String::createFromUtf8(
                        rt, members[i] ? members[i] : ""));
                if (members[i] && valkey_direct_free)
                    valkey_direct_free(members[i]);
            }
            return Value(rt, out);
        });
}

Value makeSnapSMembers(Runtime &rt) {
    return Function::createFromHostFunction(
        rt, PropNameID::forAscii(rt, "snapSMembers"), 2,
        [](Runtime &rt, const Value &, const Value *args,
           size_t count) -> Value {
            if (!dazzle_snapshot_smembers_typed) return Value::null();
            if (count < 2) {
                throw JSError(rt,
                    "snapSMembers expects (key, maxMembers)");
            }
            auto key = args[0].asString(rt).utf8(rt);
            int maxMembers = static_cast<int>(args[1].asNumber());
            if (maxMembers <= 0) maxMembers = 1;
            if (maxMembers > 1024) maxMembers = 1024;
            std::vector<char *> members(
                static_cast<size_t>(maxMembers), nullptr);
            int n = dazzle_snapshot_smembers_typed(
                key.c_str(), members.data(), maxMembers);
            if (n < 0) return Value::null();
            auto out = Array(rt, static_cast<size_t>(n));
            for (int i = 0; i < n; i++) {
                out.setValueAtIndex(rt, i,
                    String::createFromUtf8(
                        rt, members[i] ? members[i] : ""));
                if (members[i] && valkey_direct_free)
                    valkey_direct_free(members[i]);
            }
            return Value(rt, out);
        });
}

Value makeSnapGet(Runtime &rt) {
    return Function::createFromHostFunction(
        rt, PropNameID::forAscii(rt, "snapGet"), 1,
        [](Runtime &rt, const Value &, const Value *args,
           size_t count) -> Value {
            if (!dazzle_snapshot_get_string_typed) return Value::null();
            if (count < 1 || !args[0].isString()) {
                throw JSError(rt, "snapGet expects a key string");
            }
            auto key = args[0].asString(rt).utf8(rt);
            // Most Dazzle strings fit in 256 B (the snapshot cap);
            // grow dynamically for the cap+1 case to keep symmetry
            // with the RESP path.
            std::string buf(512, '\0');
            int len = dazzle_snapshot_get_string_typed(
                key.c_str(), buf.data(),
                static_cast<int>(buf.size()));
            if (len < 0) return Value::null();
            if (len > static_cast<int>(buf.size())) {
                // Rarely hit; retry with the exact size.
                buf.assign(static_cast<size_t>(len) + 1, '\0');
                len = dazzle_snapshot_get_string_typed(
                    key.c_str(), buf.data(),
                    static_cast<int>(buf.size()));
                if (len < 0) return Value::null();
            }
            buf.resize(static_cast<size_t>(len));
            return Value(rt, String::createFromUtf8(rt, buf));
        });
}

} // namespace

namespace dazzle {

void installJsi(Runtime &rt) {
    Object dz(rt);
    dz.setProperty(rt, "dazzleCommand",      makeDazzleCommand(rt));
    dz.setProperty(rt, "snapHGetAll",        makeSnapHGetAll(rt));
    dz.setProperty(rt, "snapZRangeByScore",  makeSnapZRangeByScore(rt));
    dz.setProperty(rt, "snapSMembers",       makeSnapSMembers(rt));
    dz.setProperty(rt, "snapGet",            makeSnapGet(rt));
    rt.global().setProperty(rt, "__dazzle", std::move(dz));
}

} // namespace dazzle
