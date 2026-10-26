# SPDX-License-Identifier: LGPL-2.1-or-later
cmake_minimum_required(VERSION 3.20)
project(wine_gdi_upscalers LANGUAGES C CXX OBJCXX)
if(NOT APPLE)
    message(FATAL_ERROR "This library implements macOS Wine GDI presentation")
endif()
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_OBJCXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)
add_compile_options("-ffile-prefix-map=${CMAKE_CURRENT_SOURCE_DIR}=/usr/src/wine-gdi-upscalers"
                    "-ffile-prefix-map=${NCNN_SOURCE_DIR}=/usr/src/ncnn")
find_package(Python3 REQUIRED COMPONENTS Interpreter)
find_program(XCRUN xcrun REQUIRED)
set(NCNN_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(NCNN_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(NCNN_BUILD_BENCHMARK OFF CACHE BOOL "" FORCE)
set(NCNN_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(NCNN_VULKAN OFF CACHE BOOL "" FORCE)
set(NCNN_OPENMP OFF CACHE BOOL "" FORCE)
set(NCNN_SHARED_LIB OFF CACHE BOOL "" FORCE)
set(NCNN_INSTALL_SDK OFF CACHE BOOL "" FORCE)
set(NCNN_AVX512 OFF CACHE BOOL "" FORCE)
set(NCNN_VERSION 20240410 CACHE STRING "" FORCE)
if(NOT EXISTS "${NCNN_SOURCE_DIR}/CMakeLists.txt" OR NOT EXISTS "${WGDI_MODEL_DIR}/up2x-no-denoise.bin")
    message(FATAL_ERROR "Use scripts/build-gdi-upscalers.py to prepare locked sources and models")
endif()
# Include the fixed model's operations and ncnn's internal conversion helpers.
# This keeps unrelated image operators out of the Wine presentation library.
set(MODEL_LAYERS Input Convolution Split Pooling BinaryOp Crop Deconvolution InnerProduct
                 ReLU Sigmoid Clip Mish HardSwish Gemm Packing Padding Flatten Reshape Cast Interp)
file(STRINGS "${NCNN_SOURCE_DIR}/src/CMakeLists.txt" LAYER_DECLARATIONS REGEX "^ncnn_add_layer\\(")
foreach(DECLARATION IN LISTS LAYER_DECLARATIONS)
    string(REGEX MATCH "ncnn_add_layer\\(([A-Za-z0-9_]+)" MATCHED "${DECLARATION}")
    set(LAYER "${CMAKE_MATCH_1}")
    string(TOLOWER "${LAYER}" LOWER_LAYER)
    if(LAYER IN_LIST MODEL_LAYERS)
        set(WITH_LAYER_${LOWER_LAYER} ON CACHE BOOL "" FORCE)
    else()
        set(WITH_LAYER_${LOWER_LAYER} OFF CACHE BOOL "" FORCE)
    endif()
endforeach()
# ncnn 20240410 consults CMAKE_SYSTEM_PROCESSOR before Apple's -arch flag.
# Select the same single architecture for its optimized layer registry.
set(CMAKE_SYSTEM_PROCESSOR "${CMAKE_OSX_ARCHITECTURES}")
add_subdirectory("${NCNN_SOURCE_DIR}" ncnn EXCLUDE_FROM_ALL)

set(RESOURCES "${CMAKE_CURRENT_BINARY_DIR}/gdi-upscalers")
set(GENERATOR "${CMAKE_CURRENT_SOURCE_DIR}/../../scripts/generate-anime4k-metal.py")
set(GLSL "${CMAKE_CURRENT_SOURCE_DIR}/vendor/anime4k/Anime4K_Upscale_CNN_x2_S.glsl")
add_custom_command(OUTPUT "${RESOURCES}/anime4k.metallib"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${RESOURCES}"
    COMMAND ${Python3_EXECUTABLE} "${GENERATOR}" --output "${RESOURCES}/anime4k.metal"
    COMMAND ${XCRUN} -sdk macosx metal -c -std=macos-metal2.3 -mmacosx-version-min=11.0
            "-fmodules-cache-path=${CMAKE_CURRENT_BINARY_DIR}/metal-module-cache"
            "${RESOURCES}/anime4k.metal" -o "${RESOURCES}/anime4k.air"
    COMMAND ${XCRUN} -sdk macosx metal "${RESOURCES}/anime4k.air" -o "${RESOURCES}/anime4k.metallib"
    DEPENDS "${GENERATOR}" "${GLSL}" VERBATIM)
add_custom_target(anime4k_shaders ALL DEPENDS "${RESOURCES}/anime4k.metallib")
file(MAKE_DIRECTORY "${RESOURCES}/models-se")
configure_file("${WGDI_MODEL_DIR}/up2x-no-denoise.param" "${RESOURCES}/models-se/up2x-no-denoise.param" COPYONLY)
configure_file("${WGDI_MODEL_DIR}/up2x-no-denoise.bin" "${RESOURCES}/models-se/up2x-no-denoise.bin" COPYONLY)

add_library(winegdiupscalers SHARED src/api.cpp src/anime4k.mm src/realcugan.cpp src/coreml-client.cpp src/resize.mm)
target_include_directories(winegdiupscalers PUBLIC include PRIVATE src)
target_compile_options(winegdiupscalers PRIVATE -Wall -Wextra -Werror=return-type)
target_link_libraries(winegdiupscalers PRIVATE ncnn "-framework Foundation" "-framework Metal" "-framework Accelerate")
set_target_properties(winegdiupscalers PROPERTIES INSTALL_NAME_DIR "@rpath")
add_dependencies(winegdiupscalers anime4k_shaders)
set(WINE_UNIX_DIR "lib/wine/x86_64-unix" CACHE STRING "Wine Unix architecture directory")
install(TARGETS winegdiupscalers LIBRARY DESTINATION "${WINE_UNIX_DIR}")
install(FILES "${RESOURCES}/anime4k.metallib" DESTINATION "${WINE_UNIX_DIR}/gdi-upscalers")
install(DIRECTORY "${RESOURCES}/models-se" DESTINATION "${WINE_UNIX_DIR}/gdi-upscalers")
# Core ML helper is built separately for arm64 even when Wine is x86_64.
# A prepared bundle contains the helper, fixed-size compiled models and its
# provenance manifest. Missing dimensions use the existing CPU backend.
set(WGDI_COREML_BUNDLE "" CACHE PATH "Prepared arm64 Core ML resource bundle")
if(WGDI_COREML_BUNDLE)
    if(NOT EXISTS "${WGDI_COREML_BUNDLE}/winegdi-coreml-helper" OR
       NOT EXISTS "${WGDI_COREML_BUNDLE}/coreml/manifest.json")
        message(FATAL_ERROR "Core ML bundle requires signed helper and model manifest")
    endif()
    install(DIRECTORY "${WGDI_COREML_BUNDLE}/" DESTINATION "${WINE_UNIX_DIR}/gdi-upscalers")
    install(PROGRAMS "${WGDI_COREML_BUNDLE}/winegdi-coreml-helper"
            DESTINATION "${WINE_UNIX_DIR}/gdi-upscalers")
endif()
install(FILES vendor/anime4k/LICENSE DESTINATION "${WINE_UNIX_DIR}/gdi-upscalers/licenses" RENAME Anime4K-MIT.txt)
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../../licenses/RealCUGAN-ncnn-MIT.txt"
              "${CMAKE_CURRENT_SOURCE_DIR}/../../licenses/RealCUGAN-bilibili-MIT.txt"
              "${CMAKE_CURRENT_SOURCE_DIR}/../../licenses/ncnn-BSD-3-Clause.txt"
        DESTINATION "${WINE_UNIX_DIR}/gdi-upscalers/licenses")

include(CTest)
if(BUILD_TESTING)
    add_executable(gdi-coreml-client-test tests/coreml-client-test.cpp src/coreml-client.cpp)
    target_include_directories(gdi-coreml-client-test PRIVATE include src)
    target_compile_options(gdi-coreml-client-test PRIVATE -UNDEBUG)
    add_test(NAME gdi-coreml-client-failure-fallback COMMAND gdi-coreml-client-test)
    set_tests_properties(gdi-coreml-client-failure-fallback PROPERTIES TIMEOUT 10)
    add_executable(gdi-frame-diff-test tests/frame-diff-test.c)
    target_include_directories(gdi-frame-diff-test PRIVATE include)
    target_compile_options(gdi-frame-diff-test PRIVATE -UNDEBUG)
    add_test(NAME gdi-frame-difference-and-stability COMMAND gdi-frame-diff-test)
    add_executable(gdi-upscalers-test tests/api-test.cpp)
    target_link_libraries(gdi-upscalers-test PRIVATE winegdiupscalers)
    target_compile_options(gdi-upscalers-test PRIVATE -UNDEBUG)
    add_test(NAME gdi-upscalers-api-and-realcugan COMMAND gdi-upscalers-test "${RESOURCES}")
    set_tests_properties(gdi-upscalers-api-and-realcugan PROPERTIES TIMEOUT 90)
endif()
