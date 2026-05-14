# Additional clean files
cmake_minimum_required(VERSION 3.16)

if("${CONFIG}" STREQUAL "" OR "${CONFIG}" STREQUAL "")
  file(REMOVE_RECURSE
  "/home/franck/Bureau/code/c/embedded-system/out/embedded_system/default.cmf"
  "/home/franck/Bureau/code/c/embedded-system/out/embedded_system/default.hex"
  "/home/franck/Bureau/code/c/embedded-system/out/embedded_system/default.hxl"
  "/home/franck/Bureau/code/c/embedded-system/out/embedded_system/default.mum"
  "/home/franck/Bureau/code/c/embedded-system/out/embedded_system/default.o"
  "/home/franck/Bureau/code/c/embedded-system/out/embedded_system/default.sdb"
  "/home/franck/Bureau/code/c/embedded-system/out/embedded_system/default.sym"
  )
endif()
