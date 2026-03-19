cmake_minimum_required(VERSION 3.20)
project(MetalWhisper
    VERSION 0.1.0
    LANGUAGES CXX OBJCXX)

# ── C++ and Obj-C++ standards ────────────────────────────────────────────────
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

# ── Find CTranslate2 ────────────────────────────────────────────────────────
# Use the installed CTranslate2 from the sibling build directory.
# Override with -DCMAKE_PREFIX_PATH=<path> if installed elsewhere.
list(APPEND CMAKE_PREFIX_PATH
    "/Users/smileijp/projects/branch/CTranslate2/build/install")

find_package(ctranslate2 REQUIRED)

# ── Apple frameworks ─────────────────────────────────────────────────────────
find_library(FOUNDATION_FRAMEWORK Foundation REQUIRED)
find_library(METAL_FRAMEWORK Metal REQUIRED)
find_library(ACCELERATE_FRAMEWORK Accelerate REQUIRED)

# ── MetalWhisper shared library ──────────────────────────────────────────────
file(GLOB MW_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/src/*.mm")

add_library(MetalWhisper SHARED ${MW_SOURCES})

target_include_directories(MetalWhisper
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/src>
        $<INSTALL_INTERFACE:include>
)

target_link_libraries(MetalWhisper
    PUBLIC
        CTranslate2::ctranslate2
    PRIVATE
        ${FOUNDATION_FRAMEWORK}
        ${METAL_FRAMEWORK}
        ${ACCELERATE_FRAMEWORK}
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
    BUILD_RPATH "${CMAKE_BINARY_DIR};/Users/smileijp/projects/branch/CTranslate2/build/install/lib"
    MACOSX_RPATH ON
)

# ── Test executables ─────────────────────────────────────────────────────────
file(GLOB MW_TESTS "${CMAKE_CURRENT_SOURCE_DIR}/tests/*.mm")

foreach(test_source ${MW_TESTS})
    get_filename_component(test_name ${test_source} NAME_WE)
    add_executable(${test_name} ${test_source})
    target_link_libraries(${test_name}
        PRIVATE
            MetalWhisper
            ${FOUNDATION_FRAMEWORK}
    )
    target_compile_options(${test_name} PRIVATE -fno-objc-arc)
    set_target_properties(${test_name} PROPERTIES
        INSTALL_RPATH "@loader_path/../lib"
        BUILD_RPATH "${CMAKE_BINARY_DIR};/Users/smileijp/projects/branch/CTranslate2/build/install/lib"
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
install(FILES src/MWTranscriber.h
    DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}/MetalWhisper
)

# Install test binaries
foreach(test_source ${MW_TESTS})
    get_filename_component(test_name ${test_source} NAME_WE)
    install(TARGETS ${test_name}
        RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
    )
endforeach()
