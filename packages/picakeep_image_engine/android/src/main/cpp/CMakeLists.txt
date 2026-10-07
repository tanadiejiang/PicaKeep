cmake_minimum_required(VERSION 3.22)
project(picakeep_image_android LANGUAGES C CXX)
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../../../../native" "${CMAKE_CURRENT_BINARY_DIR}/core")
target_sources(picakeep_image_engine PRIVATE jni_bridge.cpp)
if(ANDROID)
  # Both LOAD alignment and the RELRO end must match a 16 KiB page. Keep
  # these Android-only so Windows and codec pixel algorithms are unchanged.
  target_link_options(picakeep_image_engine PRIVATE
    "-Wl,-z,max-page-size=16384"
    "-Wl,-z,common-page-size=16384")
endif()
