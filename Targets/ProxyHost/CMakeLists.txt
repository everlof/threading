cmake_minimum_required(VERSION 3.25)
project(ThreadingProxy VERSION 0.3.0 LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)
option(THREADING_PROXY_SANITIZERS "Instrument the helper and its dependencies" OFF)

if(THREADING_PROXY_SANITIZERS)
  if(MSVC)
    message(FATAL_ERROR "Use the Clang/GCC sanitizer lane; Windows runs the native MSVC suite")
  endif()
  add_compile_options(-fsanitize=address,undefined -fno-omit-frame-pointer)
  add_link_options(-fsanitize=address,undefined)
endif()

# Retained, hash-pinned upstream sources: configuration never accesses the network.
function(proxy_unpack name digest directory)
  set(archive "${CMAKE_CURRENT_SOURCE_DIR}/third_party/${name}")
  file(SHA256 "${archive}" actual)
  if(NOT actual STREQUAL digest)
    message(FATAL_ERROR "Dependency checksum mismatch: ${name}")
  endif()
  set(destination "${CMAKE_CURRENT_BINARY_DIR}/dependencies/${digest}")
  if(NOT EXISTS "${destination}/${directory}/CMakeLists.txt")
    file(ARCHIVE_EXTRACT INPUT "${archive}" DESTINATION "${destination}")
  endif()
  set(${directory}_SOURCE_DIR "${destination}/${directory}" PARENT_SCOPE)
endfunction()

proxy_unpack(libuv-v1.53.0.tar.gz cb0d6dd2128d5a95bd242c6cc982a24fe608fa93da57b6b4ec763b0018c53e64 libuv-v1.53.0)
proxy_unpack(llhttp-release-v9.4.3.tar.gz 1eb813c7437b31a87496a1cd3ed79f00746720f5e7e29c79b42c02cb69f36c39 llhttp-release-v9.4.3)
proxy_unpack(mbedtls-4.1.1.tar.bz2 3359a349e23db3d5536fcee032ae7b2ecbfc08972fab643089b5cbf2a375c98c mbedtls-4.1.1)
proxy_unpack(cjson-v1.7.19.tar.gz 7fa616e3046edfa7a28a32d5f9eacfd23f92900fe1f8ccd988c1662f30454562 cJSON-1.7.19)
proxy_unpack(zlib-1.3.2.tar.gz bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16 zlib-1.3.2)
# Inflate only: never modify captured/forwarded representation bytes.
add_library(proxy_zlib STATIC
  "${zlib-1.3.2_SOURCE_DIR}/adler32.c" "${zlib-1.3.2_SOURCE_DIR}/crc32.c"
  "${zlib-1.3.2_SOURCE_DIR}/inflate.c" "${zlib-1.3.2_SOURCE_DIR}/inffast.c"
  "${zlib-1.3.2_SOURCE_DIR}/inftrees.c" "${zlib-1.3.2_SOURCE_DIR}/zutil.c")
target_include_directories(proxy_zlib SYSTEM PUBLIC "${zlib-1.3.2_SOURCE_DIR}")
set(ENABLE_PROGRAMS OFF CACHE BOOL "" FORCE)
set(ENABLE_TESTING OFF CACHE BOOL "" FORCE)
set(GEN_FILES OFF CACHE BOOL "" FORCE)
set(MBEDTLS_FATAL_WARNINGS OFF CACHE BOOL "" FORCE)
set(USE_STATIC_MBEDTLS_LIBRARY ON CACHE BOOL "" FORCE)
set(USE_SHARED_MBEDTLS_LIBRARY OFF CACHE BOOL "" FORCE)
add_subdirectory("${mbedtls-4.1.1_SOURCE_DIR}" dependencies/mbedtls-build EXCLUDE_FROM_ALL)
add_library(proxy_json STATIC "${cJSON-1.7.19_SOURCE_DIR}/cJSON.c")
target_include_directories(proxy_json SYSTEM PUBLIC "${cJSON-1.7.19_SOURCE_DIR}")
target_compile_definitions(proxy_json PRIVATE CJSON_NESTING_LIMIT=32)
set(LIBUV_BUILD_SHARED OFF CACHE BOOL "" FORCE)
set(LIBUV_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LIBUV_BUILD_BENCH OFF CACHE BOOL "" FORCE)
add_subdirectory("${libuv-v1.53.0_SOURCE_DIR}" dependencies/libuv-build EXCLUDE_FROM_ALL)

add_library(proxy_llhttp STATIC
  "${llhttp-release-v9.4.3_SOURCE_DIR}/src/api.c"
  "${llhttp-release-v9.4.3_SOURCE_DIR}/src/http.c"
  "${llhttp-release-v9.4.3_SOURCE_DIR}/src/llhttp.c")
target_include_directories(proxy_llhttp SYSTEM PUBLIC "${llhttp-release-v9.4.3_SOURCE_DIR}/include")

add_library(proxy_core STATIC src/http.c src/proxy.c src/tls.c src/capture.c)
target_include_directories(proxy_core PUBLIC src)
target_link_libraries(proxy_core PUBLIC uv_a proxy_llhttp mbedtls)
add_executable(threading-proxyd src/main.c src/output.c src/platform.c src/mcp.c src/capture_view.c)
target_link_libraries(threading-proxyd PRIVATE proxy_core proxy_json proxy_zlib)
if(UNIX AND NOT APPLE)
  target_link_libraries(threading-proxyd PRIVATE m)
endif()

foreach(target proxy_core threading-proxyd)
  if(MSVC)
    target_compile_options(${target} PRIVATE /W4 /WX)
    target_compile_definitions(${target} PRIVATE _CRT_SECURE_NO_WARNINGS)
  else()
    target_compile_options(${target} PRIVATE -Wall -Wextra -Wpedantic -Werror -Wconversion -Wshadow)
    target_compile_definitions(${target} PUBLIC _POSIX_C_SOURCE=200112L)
  endif()
endforeach()

include(CTest)
if(BUILD_TESTING)
  find_package(Python3 3.9 REQUIRED COMPONENTS Interpreter)
  find_program(PROXY_OPENSSL_EXECUTABLE openssl REQUIRED) # Ephemeral TLS fixture generation, never linked.
  add_test(NAME proxy-integration COMMAND "${Python3_EXECUTABLE}"
    "${CMAKE_CURRENT_SOURCE_DIR}/tests/integration.py" "$<TARGET_FILE:threading-proxyd>")
  set_tests_properties(proxy-integration PROPERTIES TIMEOUT 120)
  add_test(NAME proxy-tls COMMAND "${Python3_EXECUTABLE}"
    "${CMAKE_CURRENT_SOURCE_DIR}/tests/tls_integration.py" "$<TARGET_FILE:threading-proxyd>")
  set_tests_properties(proxy-tls PROPERTIES TIMEOUT 120)
  add_test(NAME proxy-mcp COMMAND "${Python3_EXECUTABLE}"
    "${CMAKE_CURRENT_SOURCE_DIR}/tests/mcp_integration.py" "$<TARGET_FILE:threading-proxyd>")
  set_tests_properties(proxy-mcp PROPERTIES TIMEOUT 150) # Includes real 90-second approval expiry.
  add_test(NAME proxy-provenance COMMAND "${Python3_EXECUTABLE}"
    "${CMAKE_CURRENT_SOURCE_DIR}/tests/provenance.py")
endif()

# A helper distribution carries its exact sources as well as original upstream notices.
install(TARGETS threading-proxyd RUNTIME DESTINATION bin)
install(FILES LICENSE THIRD_PARTY_NOTICES.md DESTINATION share/threading-proxyd)
install(DIRECTORY third_party/licenses/ DESTINATION share/threading-proxyd/licenses)
install(DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/" DESTINATION share/threading-proxyd/source
  PATTERN "build" EXCLUDE PATTERN ".build" EXCLUDE PATTERN "__pycache__" EXCLUDE)
