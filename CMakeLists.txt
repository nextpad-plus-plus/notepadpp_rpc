cmake_minimum_required(VERSION 3.20)
project(notepadpp_rpc VERSION 1.0.3 LANGUAGES CXX OBJCXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0")
set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64")

set(NPP_MACOS_DIR "${CMAKE_SOURCE_DIR}/../../notepad-plus-plus-macos")
set(NPP_WIN_DIR "${CMAKE_SOURCE_DIR}/../../notepad-plus-plus")
set(SCINTILLA_INCLUDE "${NPP_WIN_DIR}/scintilla/include")
set(NPP_PLUGIN_INCLUDE "${NPP_MACOS_DIR}/src")

add_library(notepadpp_rpc SHARED src/notepadpp_rpc.mm)
target_include_directories(notepadpp_rpc PRIVATE
    ${NPP_PLUGIN_INCLUDE}
    ${SCINTILLA_INCLUDE})
target_link_libraries(notepadpp_rpc PRIVATE "-framework Cocoa")
set(PLUGIN_INSTALL_DIR "$ENV{HOME}/Library/Application Support/Nextpad++/plugins/notepadpp_rpc")
set_target_properties(notepadpp_rpc PROPERTIES PREFIX "" SUFFIX ".dylib")
# Stamp version into the dylib Mach-O current_version (Plugins Admin reads it).
target_link_options(notepadpp_rpc PRIVATE "-Wl,-current_version,${PROJECT_VERSION}")
install(TARGETS notepadpp_rpc DESTINATION "${PLUGIN_INSTALL_DIR}")
