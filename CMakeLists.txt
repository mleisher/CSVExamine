cmake_minimum_required(VERSION 3.20)
project(CSVExamine LANGUAGES CXX OBJCXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64")
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

set(NPP_MACOS_DIR "${CMAKE_SOURCE_DIR}/../../nextpad-plus-plus-macos")
#set(NPP_WIN_DIR "${CMAKE_SOURCE_DIR}/../../nextpad-plus-plus")
set(SCINTILLA_INCLUDE "${NPP_MACOS_DIR}/scintilla/include")
set(NPP_PLUGIN_INCLUDE "${NPP_MACOS_DIR}/src")

add_library(CSVExamine SHARED src/CSVExamine.mm)
target_include_directories(CSVExamine PRIVATE
    ${NPP_PLUGIN_INCLUDE}
    ${SCINTILLA_INCLUDE})
target_link_libraries(CSVExamine PRIVATE "-framework Cocoa")
set(PLUGIN_INSTALL_DIR "$ENV{HOME}/.nextpad++/plugins/CSVExamine")
set(PLUGIN_CONFIG_DIR "$ENV{HOME}/.nextpad++/plugins/Config")
set_target_properties(CSVExamine PROPERTIES PREFIX "" SUFFIX ".dylib")
install(TARGETS CSVExamine DESTINATION "${PLUGIN_INSTALL_DIR}")
install(FILES CSVExamine.ini DESTINATION "${PLUGIN_CONFIG_DIR}")
