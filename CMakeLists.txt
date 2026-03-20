cmake_minimum_required(VERSION 3.20)
project(MetalWhisper
    VERSION 0.1.0
    LANGUAGES CXX OBJCXX)

# ── macOS deployment target ──────────────────────────────────────────────────
if(NOT CMAKE_OSX_DEPLOYMENT_TARGET)
    set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0" CACHE STRING "Minimum macOS version")
endif()

# ── C++ and Obj-C++ standards ────────────────────────────────────────────────
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

# ── Find CTranslate2 ────────────────────────────────────────────────────────
# Default: look in third_party/ctranslate2-mps (from scripts/setup_dependencies.sh).
# Fallback: sibling CTranslate2/build/install (local build).
# Override with: cmake -DCT2_INSTALL_PREFIX=/your/path ..
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/third_party/ctranslate2-mps/lib/libctranslate2.dylib")
    set(_CT2_DEFAULT "${CMAKE_CURRENT_SOURCE_DIR}/third_party/ctranslate2-mps")
else()
    set(_CT2_DEFAULT "${CMAKE_CURRENT_SOURCE_DIR}/../CTranslate2/build/install")
endif()
set(CT2_INSTALL_PREFIX "${_CT2_DEFAULT}"
    CACHE PATH "Path to CTranslate2 install prefix")
list(APPEND CMAKE_PREFIX_PATH "${CT2_INSTALL_PREFIX}")

find_package(ctranslate2 REQUIRED)

# ── Find ONNX Runtime ──────────────────────────────────────────────────────
set(ONNXRUNTIME_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/onnxruntime-osx-arm64-1.21.0")
find_library(ONNXRUNTIME_LIB onnxruntime PATHS "${ONNXRUNTIME_DIR}/lib" NO_DEFAULT_PATH)

# ── Apple frameworks ─────────────────────────────────────────────────────────
find_library(FOUNDATION_FRAMEWORK Foundation REQUIRED)
find_library(METAL_FRAMEWORK Metal REQUIRED)
find_library(ACCELERATE_FRAMEWORK Accelerate REQUIRED)
find_library(AVFOUNDATION_FRAMEWORK AVFoundation REQUIRED)
find_library(COMPRESSION_LIB compression REQUIRED)

# ── MetalWhisper shared library ──────────────────────────────────────────────
file(GLOB MW_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/src/*.mm")

add_library(MetalWhisper SHARED ${MW_SOURCES})

target_include_directories(MetalWhisper
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/src>
        $<INSTALL_INTERFACE:include>
    PRIVATE
        "${ONNXRUNTIME_DIR}/include"
)

target_link_libraries(MetalWhisper
    PUBLIC
        CTranslate2::ctranslate2
    PRIVATE
        ${FOUNDATION_FRAMEWORK}
        ${METAL_FRAMEWORK}
        ${ACCELERATE_FRAMEWORK}
        ${AVFOUNDATION_FRAMEWORK}
        ${COMPRESSION_LIB}
        ${ONNXRUNTIME_LIB}
)

# Disable ARC for all Obj-C++ sources (architecture decision #5)
target_compile_options(MetalWhisper PRIVATE -fno-objc-arc)

# Set library version and install name
set_target_properties(MetalWhisper PROPERTIES
    VERSION ${PROJECT_VERSION}
    SOVERSION 0
    # macOS install name for the dylib
    INSTALL_NAME_DIR "@rpath"
    BUILD_WITH_INSTALL_RPATH OFF
    INSTALL_RPATH "@loader_path;@loader_path/../lib"
    BUILD_RPATH "${CMAKE_BINARY_DIR};${CT2_INSTALL_PREFIX}/lib;${ONNXRUNTIME_DIR}/lib"
    MACOSX_RPATH ON
)

# ── CLI tool ─────────────────────────────────────────────────────────────────
# Target name mw_cli avoids case-insensitive collision with MetalWhisper on macOS.
# OUTPUT_NAME produces the desired "metalwhisper" binary.
add_executable(mw_cli cli/metalwhisper.mm)
target_link_libraries(mw_cli
    PRIVATE
        MetalWhisper
        ${FOUNDATION_FRAMEWORK}
        ${AVFOUNDATION_FRAMEWORK}
)
target_compile_options(mw_cli PRIVATE -fno-objc-arc)
set_target_properties(mw_cli PROPERTIES
    OUTPUT_NAME metalwhisper
    INSTALL_RPATH "@loader_path/../lib"
    BUILD_RPATH "${CMAKE_BINARY_DIR};${CT2_INSTALL_PREFIX}/lib;${ONNXRUNTIME_DIR}/lib"
    MACOSX_RPATH ON
)
install(TARGETS mw_cli RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})

# ── Test executables ─────────────────────────────────────────────────────────
file(GLOB MW_TESTS "${CMAKE_CURRENT_SOURCE_DIR}/tests/*.mm")

foreach(test_source ${MW_TESTS})
    get_filename_component(test_name ${test_source} NAME_WE)
    add_executable(${test_name} ${test_source})
    target_link_libraries(${test_name}
        PRIVATE
            MetalWhisper
            ${FOUNDATION_FRAMEWORK}
            ${AVFOUNDATION_FRAMEWORK}
            ${ACCELERATE_FRAMEWORK}
            ${COMPRESSION_LIB}
    )
    target_include_directories(${test_name} PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/tests)
    target_compile_options(${test_name} PRIVATE -fno-objc-arc)
    set_target_properties(${test_name} PROPERTIES
        INSTALL_RPATH "@loader_path/../lib"
        BUILD_RPATH "${CMAKE_BINARY_DIR};${CT2_INSTALL_PREFIX}/lib;${ONNXRUNTIME_DIR}/lib"
        MACOSX_RPATH ON
    )
endforeach()

# ── Install rules ────────────────────────────────────────────────────────────
include(GNUInstallDirs)

install(TARGETS MetalWhisper
    EXPORT MetalWhisperTargets
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
)

# Install public headers
install(FILES
    src/MetalWhisper.h
    src/MWTranscriber.h
    src/MWTranscriptionOptions.h
    src/MWAudioDecoder.h
    src/MWFeatureExtractor.h
    src/MWConstants.h
    src/MWTokenizer.h
    src/MWHelpers.h
    src/MWModelManager.h
    src/MWVoiceActivityDetector.h
    DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}/MetalWhisper
)

# Install CTranslate2 dylib alongside MetalWhisper so the install is self-contained.
# Resolves symlinks to find the real file, then installs versioned + unversioned links.
file(GLOB CT2_DYLIBS "${CT2_INSTALL_PREFIX}/lib/libctranslate2*.dylib")
install(FILES ${CT2_DYLIBS}
    DESTINATION ${CMAKE_INSTALL_LIBDIR}
)

# Install ONNX Runtime dylib alongside MetalWhisper.
file(GLOB ORT_DYLIBS "${ONNXRUNTIME_DIR}/lib/libonnxruntime*.dylib")
install(FILES ${ORT_DYLIBS}
    DESTINATION ${CMAKE_INSTALL_LIBDIR}
)

# Install test binaries
foreach(test_source ${MW_TESTS})
    get_filename_component(test_name ${test_source} NAME_WE)
    install(TARGETS ${test_name}
        RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
    )
endforeach()
