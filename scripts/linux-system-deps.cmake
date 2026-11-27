if(PROJECT_NAME STREQUAL "Android-Emulator")
  # This source revision disables TCMalloc when gfxstream is enabled.
  set(TCMALLOC_FOUND TRUE)

  # Match the Linux toolchain's SDK package layout with the native compiler.
  set(RUNTIME_OS_PROPERTIES
      "LINK_FLAGS>=-Wl,-rpath,'$ORIGIN/lib64:$ORIGIN' -Wl,--disable-new-dtags")

  include(CMakePushCheckState)
  include(CheckSymbolExists)
  cmake_push_check_state(RESET)
  set(CMAKE_REQUIRED_DEFINITIONS -D_GNU_SOURCE)
  check_symbol_exists(memfd_create "sys/mman.h" HAVE_MEMFD_CREATE)
  cmake_pop_check_state()
  if(HAVE_MEMFD_CREATE)
    set_property(SOURCE util/memfd.c APPEND PROPERTY COMPILE_DEFINITIONS CONFIG_MEMFD)
  endif()

  include(CheckIncludeFile)
  check_include_file(stropts.h HAVE_STROPTS_H)
  if(NOT HAVE_STROPTS_H)
    # Keep the emulator's curl feature configuration and use the host's header availability.
    set(curl_config "${CMAKE_CURRENT_SOURCE_DIR}/android/third_party/libcurl/linux-x86_64/curl_config.h")
    file(CONFIGURE OUTPUT "${CMAKE_BINARY_DIR}/host-curl/curl_config.h"
         CONTENT "#include \"@curl_config@\"\n#undef HAVE_STROPTS_H\n" @ONLY)
    cmake_language(DEFER CALL target_include_directories curl BEFORE PRIVATE "${CMAKE_BINARY_DIR}/host-curl")
  endif()
endif()
