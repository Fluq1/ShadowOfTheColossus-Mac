#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
mkdir -p out
# Windows: MSYS2 CLANG64 (packages in packaging/windows/README.md). The GPU library is static
# there and CMake links bb-probe.exe as well; no PGO (GCC-only flags), LTO off by default.
case $(uname -s) in
MINGW*|MSYS*)
    # shellcheck source=msys2-env.sh
    source ./msys2-env.sh
    for tool in clang cmake ninja pkg-config; do
        command -v "$tool" >/dev/null || { echo "Need $tool from MSYS2 CLANG64 (packaging/windows/README.md)." >&2; exit 1; }
    done
    if [[ ! -f gpu/third_party/fsr-vulkan/CMakeLists.txt || ! -f gpu/third_party/imgui/imgui.h ||
          ! -f gpu/third_party/xbyak/xbyak/xbyak.h ]]; then
        git submodule update --init --recursive
    fi
    for patch in gpu/patches/fsr-vulkan/*.patch; do
        if ! git -C gpu/third_party/fsr-vulkan apply --reverse --check "$PWD/$patch" 2>/dev/null; then
            git -C gpu/third_party/fsr-vulkan apply "$PWD/$patch"
        fi
    done
    # sotc: llvm-windres, binutils windres fails on build paths with spaces ("Unable to create
    # temp file").
    cmake -S gpu -B out/gpu -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DBB_PGO=off \
        -DBB_LTO="${BB_LTO:-OFF}" -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
        -DCMAKE_RC_COMPILER=llvm-windres >/dev/null
    echo "GPU library and loader: LTO ${BB_LTO:-OFF}"
    if ! ninja -C out/gpu bb-probe bb-gpu-capabilities bb-play > out/gpu-build.log 2>&1; then
        grep -v '^\[' out/gpu-build.log | tail -40 >&2
        echo 'Build failed (full log: out/gpu-build.log)' >&2; exit 1
    fi
    cp out/gpu/bb-probe.exe out/gpu/bb-gpu-capabilities.exe out/gpu/bb-play.exe out/
    echo "Built $PWD/out/bb-probe.exe"
    exit 0
    ;;
Darwin)
    # macOS / Apple Silicon: the guest's x86-64 code runs natively, so every binary is built for
    # x86_64 and runs under Rosetta 2. Vulkan is MoltenVK. Dependencies live in an x86_64 Homebrew
    # (HOMEBREW_X86) plus the locally built x86_64 libs in DEPS_X86; header-only deps come from the
    # native arm64 Homebrew (BREW_H) or the vendored headers under third_party/headers.
    HOMEBREW_X86=${HOMEBREW_X86:-$HOME/homebrew-x86}
    DEPS_X86=${DEPS_X86:-$HOME/sotc-deps/x86}
    BREW_H=${BREW_H:-/opt/homebrew}
    CC=${CC:-clang}
    export PKG_CONFIG_PATH="$DEPS_X86/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
    for tool in cmake ninja pkg-config "$CC"; do
        command -v "$tool" >/dev/null || { echo "Need $tool (see docs)." >&2; exit 1; }
    done
    for dep in \
        "$HOMEBREW_X86/opt/fmt/lib/cmake/fmt" \
        "$HOMEBREW_X86/opt/zydis/lib/cmake/zydis" \
        "$HOMEBREW_X86/opt/molten-vk/lib/libMoltenVK.dylib" \
        "$BREW_H/opt/vulkan-headers/include" \
        "$DEPS_X86/lib/pkgconfig/sdl3.pc" \
        "$DEPS_X86/lib/pkgconfig/libavcodec.pc" \
        "third_party/headers/tsl-robin-map/include/tsl/robin_map.h" \
        "third_party/headers/vma/include/vk_mem_alloc.h"; do
        [[ -e $dep ]] || { echo "Missing dependency: $dep (see packaging/macos/README.md)." >&2; exit 1; }
    done
    if [[ ! -f gpu/third_party/fsr-vulkan/CMakeLists.txt || ! -f gpu/third_party/imgui/imgui.h ||
          ! -f gpu/third_party/xbyak/xbyak/xbyak.h ]]; then
        git submodule update --init --recursive
    fi
    for patch in gpu/patches/fsr-vulkan/*.patch; do
        if ! git -C gpu/third_party/fsr-vulkan apply --reverse --check "$PWD/$patch" 2>/dev/null; then
            git -C gpu/third_party/fsr-vulkan apply "$PWD/$patch"
        fi
    done
    cmake -S gpu -B out/gpu -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DBB_PGO=off \
        -DBB_LTO="${BB_LTO:-ON}" \
        -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}" \
        -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="${CXX:-clang++}" \
        -DCMAKE_C_FLAGS="-I$HOMEBREW_X86/opt/zycore-c/include" \
        -DCMAKE_CXX_FLAGS="-I$HOMEBREW_X86/opt/zycore-c/include" \
        -DCMAKE_SHARED_LINKER_FLAGS="-L$HOMEBREW_X86/opt/zycore-c/lib" \
        -DCMAKE_EXE_LINKER_FLAGS="-L$HOMEBREW_X86/opt/zycore-c/lib" \
        -DVulkan_INCLUDE_DIR="$BREW_H/opt/vulkan-headers/include" \
        -DVulkan_LIBRARY="$HOMEBREW_X86/opt/molten-vk/lib/libMoltenVK.dylib" \
        -DBOOST_ROOT="$BREW_H/opt/boost" \
        -Dfmt_DIR="$HOMEBREW_X86/opt/fmt/lib/cmake/fmt" \
        -DZydis_DIR="$HOMEBREW_X86/opt/zydis/lib/cmake/zydis" \
        -DZycore_DIR="$HOMEBREW_X86/opt/zycore-c/lib/cmake/zycore" \
        -DTSL_ROBIN_MAP_INCLUDE_DIR="$PWD/third_party/headers/tsl-robin-map/include" \
        -DVMA_INCLUDE_DIR="$PWD/third_party/headers/vma/include" \
        -DGLSLANG_COMPILER="${GLSLANG_COMPILER:-$BREW_H/bin/glslang}" \
        -DBB_MACOS_FFMPEG="${BB_MACOS_FFMPEG:-ON}" \
        -DCMAKE_PREFIX_PATH="$HOMEBREW_X86/opt/fmt;$HOMEBREW_X86/opt/zydis;$HOMEBREW_X86/opt/molten-vk;$BREW_H/opt/boost;$DEPS_X86" \
        >/dev/null
    echo "GPU library: macOS x86_64, LTO ${BB_LTO:-ON}"
    if ! ninja -C out/gpu bbgpu > out/gpu-build.log 2>&1; then
        grep -v '^\[' out/gpu-build.log | tail -60 >&2
        echo 'GPU library build failed (full log: out/gpu-build.log)' >&2; exit 1
    fi
    if [[ ! -f out/gpu/libbbgpu.dylib ]]; then
        echo 'Expected out/gpu/libbbgpu.dylib was not produced.' >&2; exit 1
    fi
    gpu=(-Lout/gpu -lbbgpu -Wl,-rpath,@loader_path/gpu -Wl,-rpath,"$PWD/out/gpu"
         -Wl,-rpath,"$DEPS_X86/lib" -Wl,-rpath,"$HOMEBREW_X86/opt/molten-vk/lib")
    arch=(-arch x86_64 -isysroot "$(xcrun --show-sdk-path 2>/dev/null || echo /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk)")
    include=(-I "$BREW_H/opt/vulkan-headers/include" -I "$HOMEBREW_X86/opt/molten-vk/include")
    read -r -a sdl3_cflags <<< "$(pkg-config --cflags sdl3)"
    read -r -a sdl3_libs <<< "$(pkg-config --libs sdl3)"
    runtime=(src/runtime*.c)
    atrac9=(third_party/LibAtrac9/C/src/*.c)
    if [[ ! -f out/libatrac9.a || -n $(find third_party/LibAtrac9/C/src -newer out/libatrac9.a -name '*.c' 2>/dev/null) ]]; then
        rm -rf out/atrac9 && mkdir -p out/atrac9
        for source in "${atrac9[@]}"; do
            "$CC" "${arch[@]}" -std=c99 -O2 -g -w -c "$source" -o "out/atrac9/$(basename "${source%.c}").o"
        done
        ar rcs out/libatrac9.a out/atrac9/*.o
    fi
    # Low 4 GiB must stay mappable (guest image below 2 GiB, thread-control blocks via LDT),
    # so the executable is non-PIE with a one-page __PAGEZERO and a high image base; TCB_SPACE
    # reserves [0x4000,4 GiB) at a 32-bit address the LDT descriptor can encode.
    macld=(-Wl,-no_pie,-no_fixup_chains,-no_huge,-pagezero_size,0x4000,-segaddr,TCB_SPACE,0x4000,-image_base,0x700000000000)
    "$CC" "${arch[@]}" -std=c11 -O2 -g -Wall -Wextra -Werror -pthread "${include[@]}" "${sdl3_cflags[@]}" \
        -I. -Isrc src/probe.c "${runtime[@]}" src/vulkan_smoke.c out/libatrac9.a -lm \
        "${gpu[@]}" -L"$HOMEBREW_X86/opt/molten-vk/lib" -lMoltenVK "${sdl3_libs[@]}" \
        "${macld[@]}" -Wl,-export_dynamic -o out/bb-probe
    echo "Built $PWD/out/bb-probe"
    "$CC" "${arch[@]}" -std=c11 -O2 -Wall -Wextra -Werror "${include[@]}" "${sdl3_libs[@]}" \
        -L"$HOMEBREW_X86/opt/molten-vk/lib" -lMoltenVK tools/gpu_capabilities.c -o out/bb-gpu-capabilities
    "$CC" "${arch[@]}" -std=c11 -O2 -g -Wall -Wextra -Werror -pthread "${include[@]}" "${sdl3_cflags[@]}" \
        -I. -Isrc tests/test_pad.c "${gpu[@]}" -L"$HOMEBREW_X86/opt/molten-vk/lib" -lMoltenVK "${sdl3_libs[@]}" \
        "${macld[@]}" -Wl,-export_dynamic -o out/pad-test && echo "Built out/pad-test"
    for t in runtime sema; do
        case $t in runtime) src=tests/test_runtime.c;; sema) src=tests/test_sema.c;; esac
        "$CC" "${arch[@]}" -std=c11 -O2 -g -Wall -Wextra -Werror -pthread "${include[@]}" "${sdl3_cflags[@]}" \
            -I. -Isrc "$src" "${runtime[@]}" out/libatrac9.a -lm "${gpu[@]}" \
            -L"$HOMEBREW_X86/opt/molten-vk/lib" -lMoltenVK "${sdl3_libs[@]}" \
            "${macld[@]}" -Wl,-export_dynamic -o "out/$t-test" && echo "Built out/$t-test"
    done
    "$CC" "${arch[@]}" -std=c11 -O2 -g -Wall -Wextra -Werror -pthread -Isrc tests/test_file_mods.c "${macld[@]}" -o out/file-mods-test && echo "Built out/file-mods-test"
    "$CC" "${arch[@]}" -std=c11 -D_GNU_SOURCE -O2 -g -Wall -Wextra -Werror -I. -Isrc tests/test_content.c src/runtime_content.c -o out/content-test && echo "Built out/content-test"
    exit 0
    ;;
esac
if [[ -z ${CC:-} ]]; then
    CC=$(command -v cc || command -v gcc || true)
    if [[ -z $CC ]]; then
        for candidate in /nix/store/*-gcc-wrapper-*/bin/gcc; do
            if [[ -x $candidate ]]; then CC=$candidate; break; fi
        done
    fi
fi
if [[ -z ${CC:-} ]]; then echo 'Install GCC/Clang or set CC.' >&2; exit 1; fi
# Dependencies come from pkg-config (Vulkan loader/headers, SDL3). On NixOS the
# environment is provided by shell.nix; re-enter it automatically if needed.
if ! { command -v pkg-config >/dev/null && pkg-config --exists vulkan sdl3 && command -v cmake >/dev/null && command -v ninja >/dev/null; }; then
    if [[ -z ${BB_IN_NIX_SHELL:-} ]] && command -v nix-shell >/dev/null; then
        exec env BB_IN_NIX_SHELL=1 nix-shell shell.nix --run "bash build.sh $*"
    fi
    echo 'Need pkg-config with vulkan and sdl3, cmake and ninja (see shell.nix).' >&2; exit 1
fi
read -r -a includes <<< "$(pkg-config --cflags vulkan sdl3)"
read -r -a libraries <<< "$(pkg-config --libs vulkan sdl3)"
# GPU library (shadPS4 video core + drivers), built by CMake into out/gpu/libbbgpu.so.
# BB_PGO: generate (instrumented build that writes pgo/ while the game runs), use, off.
# Default: use the profile in pgo/ when there is one. BB_LTO=OFF disables link-time optimization.
pgo=${BB_PGO:-}
if [[ -z $pgo ]]; then
    if [[ -n $(find pgo -name '*.gcda' -print -quit 2>/dev/null) ]]; then pgo=use; else pgo=off; fi
fi
mkdir -p pgo
# Submodules (git clone --recursive, or: git submodule update --init) and this port's changes
# to FSR-Vulkan (gpu/patches/fsr-vulkan), applied to its working tree once.
if [[ ! -f gpu/third_party/fsr-vulkan/CMakeLists.txt || ! -f gpu/third_party/imgui/imgui.h ]]; then
    git submodule update --init --recursive
fi
for patch in gpu/patches/fsr-vulkan/*.patch; do
    if ! git -C gpu/third_party/fsr-vulkan apply --reverse --check "$PWD/$patch" 2>/dev/null; then
        git -C gpu/third_party/fsr-vulkan apply "$PWD/$patch"
    fi
done
cmake -S gpu -B out/gpu -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DBB_PGO="$pgo" \
    -DBB_LTO="${BB_LTO:-ON}" -DBB_PGO_DIR="$PWD/pgo" >/dev/null
echo "GPU library: PGO $pgo, LTO ${BB_LTO:-ON}"
# A failed GPU build must stop here: an older libbbgpu.so would otherwise be used silently.
if ! ninja -C out/gpu bbgpu > out/gpu-build.log 2>&1; then
    grep -v '^\[' out/gpu-build.log | tail -40 >&2
    echo 'GPU library build failed (full log: out/gpu-build.log)' >&2; exit 1
fi
# $ORIGIN/gpu: packaged copies keep the library next to the binary without patching it.
gpu=(-Lout/gpu -lbbgpu -Wl,-rpath,'$ORIGIN/gpu' -Wl,-rpath,"$PWD/out/gpu" -rdynamic)
runtime=(src/runtime*.c)
# Third-party decoders: compiled once, without this project's -Werror policy.
atrac9=(third_party/LibAtrac9/C/src/*.c)
if [[ ! -f out/libatrac9.a || -n $(find third_party/LibAtrac9/C/src -newer out/libatrac9.a -name '*.c') ]]; then
    rm -rf out/atrac9 && mkdir -p out/atrac9
    for source in "${atrac9[@]}"; do "$CC" -std=c99 -O2 -g -w -c "$source" -o "out/atrac9/$(basename "${source%.c}").o"; done
    ar rcs out/libatrac9.a out/atrac9/*.o
fi
"$CC" -std=c11 -O2 -g -Wall -Wextra -Werror -pthread -no-pie "${includes[@]}" -I. -Isrc src/probe.c "${runtime[@]}" src/vulkan_smoke.c out/libatrac9.a -lm "${gpu[@]}" "${libraries[@]}" -o out/bb-probe
echo "Built $PWD/out/bb-probe"
# GPU check for run.sh (live_resolution=auto): links only the Vulkan loader.
"$CC" -std=c11 -O2 -Wall -Wextra -Werror tools/gpu_capabilities.c "${libraries[@]}" -o out/bb-gpu-capabilities
if [[ ${1:-} == --test ]]; then
    "$CC" -std=c11 -O2 -g -Wall -Wextra -Werror -pthread "${includes[@]}" -I. -Isrc tests/test_pad.c "${libraries[@]}" -o out/pad-test
    out/pad-test
    "$CC" -std=c11 -O2 -g -Wall -Wextra -Werror -pthread -I. -Isrc tests/test_runtime.c "${runtime[@]}" out/libatrac9.a -lm "${gpu[@]}" "${libraries[@]}" -o out/runtime-test
    out/runtime-test
    "$CC" -std=c11 -O2 -g -Wall -Wextra -Werror -pthread -Isrc tests/test_file_mods.c -o out/file-mods-test
    out/file-mods-test
    "$CC" -std=c11 -O2 -g -Wall -Wextra -Werror -pthread -I. -Isrc tests/test_sema.c "${runtime[@]}" out/libatrac9.a -lm "${gpu[@]}" "${libraries[@]}" -o out/sema-test
    out/sema-test
    "$CC" -std=c11 -D_GNU_SOURCE -O2 -g -Wall -Wextra -Werror -I. -Isrc tests/test_content.c src/runtime_content.c -o out/content-test
    out/content-test
fi
