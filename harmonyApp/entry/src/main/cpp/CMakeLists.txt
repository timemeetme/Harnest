cmake_minimum_required(VERSION 3.4.1)
project(harness_napi)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(QUICKJS_C_SOURCES
    quickjs/quickjs.c
    quickjs/cutils.c
    quickjs/libregexp.c
    quickjs/libunicode.c
    quickjs/dtoa.c
)

add_compile_definitions(
    CONFIG_ALL=1
    CONFIG_BIGINT=1
    CONFIG_VERSION="2026-06-04"
    JS_ENABLE_ESM=1
    _GNU_SOURCE
)

if(CMAKE_C_COMPILER_ID MATCHES "Clang|GNU")
    add_compile_options(-w)
endif()

add_library(harness_napi SHARED
    harness_engine.cpp
    napi_init.cpp
    ScriptEngine.cpp
    ${QUICKJS_C_SOURCES}
)

target_include_directories(harness_napi PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/quickjs
)

target_link_libraries(harness_napi PRIVATE
    ace_napi.z
    hilog_ndk.z
)

set_target_properties(harness_napi PROPERTIES
    OUTPUT_NAME "harness_napi"
)
