#!/usr/bin/env python3
"""Generate the image-filter golden fixture from the ORIGINAL Android sources.

The Kotlin colour model (`ImageFilters.kt`, only `R.string` ids stubbed) samples each case's LUT, and the
ORIGINAL C++ kernel (`shaft_image_filter.cpp`, its `namespace {}` copied verbatim) renders a procedural
test image with it. The SHA-256 of every rendered image plus `FilterState.fileTag()` land in
`Shaft-iOSTests/ImageFilterFixtures/golden.txt`; `ImageFilterTests` renders the same cases with the Swift
port and must match byte for byte.

Needs Android Studio (bundled kotlinc + JBR) and clang++.
  python3 scripts/gen-image-filter-golden.py [/path/to/Pixiv-Shaft]
"""
from pathlib import Path
import hashlib
import os
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
shaft = Path(sys.argv[1]) if len(sys.argv) > 1 else root.parent / "Pixiv-Shaft"
studio = Path("/Applications/Android Studio.app/Contents")
kotlinc = studio / "plugins/Kotlin/kotlinc/bin/kotlinc"
java_home = studio / "jbr/Contents/Home"
fixtures = root / "Shaft-iOSTests/ImageFilterFixtures"
cases_file = fixtures / "cases.txt"

work = Path(tempfile.mkdtemp(prefix="image-filter-golden-"))
env = dict(os.environ, JAVA_HOME=str(java_home), PATH=f"{java_home}/bin:" + os.environ["PATH"])

# ── Kotlin: the Android colour model, resource ids stubbed ────────────────
model = (shaft / "app/src/main/java/ceui/pixiv/ui/filter/ImageFilters.kt").read_text()
model = model.replace("import ceui.lisa.R\n", "").replace("import androidx.annotation.StringRes\n", "")
model = model.replace("@StringRes ", "")
model = re.sub(r"R\.string\.[a-z0-9_]+", "0", model)
(work / "ImageFilters.kt").write_text(model)
(work / "Golden.kt").write_text('''package ceui.pixiv.ui.filter
import java.io.DataOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

fun main(args: Array<String>) {
    val out = File(args[1])
    out.mkdirs()
    val tags = StringBuilder()
    for (line in File(args[0]).readLines()) {
        if (line.isBlank() || line.startsWith("#")) continue
        val f = line.trim().split(Regex("\\\\s+"))
        val adjust = f[3].split(",").map { it.toInt() }
        val state = FilterState(FilterPreset.fromKey(f[1]), f[2].toInt(), adjust)
        val lut = FilterLut.forState(state)
        val vig = FilterLut.vignette(state.vignette())
        val buf = ByteBuffer.allocate(16 + (lut?.size ?: 0) * 4 + (vig?.size ?: 0) * 4).order(ByteOrder.LITTLE_ENDIAN)
        buf.putInt(lut?.size ?: 0); buf.putInt(vig?.size ?: 0); buf.putFloat(state.grain()); buf.putInt(0)
        lut?.forEach { buf.putFloat(it) }
        vig?.forEach { buf.putFloat(it) }
        File(out, f[0] + ".bin").writeBytes(buf.array())
        tags.append(f[0]).append(' ').append(state.fileTag()).append('\\n')
    }
    File(out, "tags.txt").writeText(tags.toString())
}
''')
subprocess.run([str(kotlinc), "ImageFilters.kt", "Golden.kt", "-include-runtime", "-d", "golden.jar", "-nowarn"],
               cwd=work, env=env, check=True)
subprocess.run([str(java_home / "bin/java"), "-cp", "golden.jar", "ceui.pixiv.ui.filter.GoldenKt",
                str(cases_file), str(work / "luts")], cwd=work, env=env, check=True)

# ── C++: the Android kernel, verbatim ─────────────────────────────────────
cpp = (shaft / "app/src/main/cpp/shaft_image_filter.cpp").read_text()
kernel = cpp[cpp.index("namespace {"):cpp.index("}  // namespace") + len("}  // namespace")]
kernel = re.sub(r"bool load_lut\(JNIEnv\* env.*?\n}\n\nbool lock\(.*?\n}\n", "", kernel, flags=re.S)
(work / "harness.cpp").write_text('''#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <system_error>
#include <thread>
#include <vector>
#if defined(__aarch64__)
#include <arm_neon.h>  // Apple silicon runs the same NEON path as Android arm64 devices
#endif
typedef int32_t jint;
''' + kernel + '''

// The JNI entry point's set-up, minus JNI: same conversions, same order.
static bool load(const std::vector<float>& values, int size, Kernel& k) {
    const auto n = static_cast<size_t>(size);
    const size_t count = n * n * n;
    k.lut.assign(count * 4, 0);
    constexpr float scale = 255.0f * (1 << kLutValueBits);
    for (size_t i = 0; i < count; ++i)
        for (size_t c = 0; c < 3; ++c)
            k.lut[i * 4 + c] = static_cast<int16_t>(std::lround(std::clamp(values[i * 3 + c], 0.0f, 1.0f) * scale));
    k.n = size; k.step_g = 4 * size; k.step_b = 4 * size * size;
    for (int v = 0; v < 256; ++v) {
        const float pos = static_cast<float>(v) * static_cast<float>(size - 1) / 255.0f;
        auto i = static_cast<int>(pos);
        int32_t f = static_cast<int32_t>(std::lround((pos - static_cast<float>(i)) * 256.0f));
        if (i >= size - 1) { i = size - 2; f = 256; }
        k.off_r[v] = 4 * i; k.off_g[v] = k.step_g * i; k.off_b[v] = k.step_b * i;
        k.frac[v] = static_cast<uint16_t>(f);
    }
    k.lut_on = true;
    return true;
}

// Same procedural picture as ImageFilterTests.procedural(): gradients, flat blocks, noise, translucency.
static void procedural(std::vector<uint8_t>& px, uint32_t w, uint32_t h) {
    px.resize(static_cast<size_t>(w) * h * 4);
    for (uint32_t y = 0; y < h; ++y) for (uint32_t x = 0; x < w; ++x) {
        uint32_t n = hash2(x, y);
        uint32_t r = (x * 255 / w + (n & 15)) & 255, g = (y * 255 / h) & 255, b = ((x ^ y) * 3 + (n >> 8 & 7)) & 255;
        if ((x / 16 + y / 16) % 5 == 0) { r = 200; g = 64; b = 32; }
        uint32_t a = (x * 3 < w) && (y * 2 < h) ? (n >> 16 & 255) : 255;
        uint8_t* p = &px[(static_cast<size_t>(y) * w + x) * 4];
        p[0] = static_cast<uint8_t>((r * a + 127) / 255);
        p[1] = static_cast<uint8_t>((g * a + 127) / 255);
        p[2] = static_cast<uint8_t>((b * a + 127) / 255);
        p[3] = static_cast<uint8_t>(a);
    }
}

int main(int argc, char** argv) {
    FILE* f = std::fopen(argv[1], "rb");
    int32_t lut_n, vig_n, pad; float grain;
    std::fread(&lut_n, 4, 1, f); std::fread(&vig_n, 4, 1, f); std::fread(&grain, 4, 1, f); std::fread(&pad, 4, 1, f);
    std::vector<float> lut(lut_n), vig(vig_n);
    std::fread(lut.data(), 4, lut_n, f); std::fread(vig.data(), 4, vig_n, f); std::fclose(f);
    const uint32_t w = std::atoi(argv[2]), h = std::atoi(argv[3]);
    Kernel k{};
    if (lut_n) load(lut, 33, k);
    if (vig_n) {
        k.vlut.resize(vig.size());
        for (size_t i = 0; i < vig.size(); ++i) k.vlut[i] = static_cast<uint16_t>(std::lround(std::clamp(vig[i], 0.0f, 1.0f) * 256.0f));
        k.vignette_on = true;
        k.cx = static_cast<float>(w) * 0.5f; k.cy = static_cast<float>(h) * 0.5f;
        k.inv_r2 = 1.0f / (k.cx * k.cx + k.cy * k.cy);
    }
    if (grain > 0) { k.grain_on = true; k.grain_amp_q8 = static_cast<int32_t>(std::lround(std::min(grain, 1.0f) * kGrainAmplitude * 256.0f)); }
    k.grain_cell = std::max(1U, std::min(w, h) / kGrainDensity);
    std::vector<uint8_t> src, dst;
    procedural(src, w, h);
    dst.resize(src.size());
    run(k, src.data(), w * 4, dst.data(), w * 4, w, h);
    FILE* o = std::fopen(argv[4], "wb");
    std::fwrite(dst.data(), 1, dst.size(), o);
    std::fclose(o);
    return 0;
}
''')
subprocess.run(["clang++", "-std=c++17", "-O2", "harness.cpp", "-o", "harness"], cwd=work, check=True)

tags = dict(line.split(" ", 1) for line in (work / "luts/tags.txt").read_text().splitlines())
lines = ["# Generated by scripts/gen-image-filter-golden.py from the Android Kotlin model + C++ kernel.",
         "# name sha256(rendered RGBA) fileTag"]
for line in cases_file.read_text().splitlines():
    if not line.strip() or line.startswith("#"):
        continue
    name, _, _, _, w, h = line.split()
    out = work / f"{name}.rgba"
    subprocess.run([str(work / "harness"), str(work / f"luts/{name}.bin"), w, h, str(out)], check=True)
    lines.append(f"{name} {hashlib.sha256(out.read_bytes()).hexdigest()} {tags[name]}")
(fixtures / "golden.txt").write_text("\n".join(lines) + "\n")
print(f"{len(lines) - 2} golden cases → {fixtures / 'golden.txt'}")
