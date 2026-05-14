# The following variables contains the files used by the different stages of the build process.
set(embedded_system_default_default_XC8_FILE_TYPE_assemble)
set_source_files_properties(${embedded_system_default_default_XC8_FILE_TYPE_assemble} PROPERTIES LANGUAGE ASM)

# For assembly files, add "." to the include path for each file so that .include with a relative path works
foreach(source_file ${embedded_system_default_default_XC8_FILE_TYPE_assemble})
        set_source_files_properties(${source_file} PROPERTIES INCLUDE_DIRECTORIES "$<PATH:NORMAL_PATH,$<PATH:REMOVE_FILENAME,${source_file}>>")
endforeach()

set(embedded_system_default_default_XC8_FILE_TYPE_assemblePreprocess)
set_source_files_properties(${embedded_system_default_default_XC8_FILE_TYPE_assemblePreprocess} PROPERTIES LANGUAGE ASM)

# For assembly files, add "." to the include path for each file so that .include with a relative path works
foreach(source_file ${embedded_system_default_default_XC8_FILE_TYPE_assemblePreprocess})
        set_source_files_properties(${source_file} PROPERTIES INCLUDE_DIRECTORIES "$<PATH:NORMAL_PATH,$<PATH:REMOVE_FILENAME,${source_file}>>")
endforeach()

set(embedded_system_default_default_XC8_FILE_TYPE_compile "${CMAKE_CURRENT_SOURCE_DIR}/../../../newmain.c")
set_source_files_properties(${embedded_system_default_default_XC8_FILE_TYPE_compile} PROPERTIES LANGUAGE C)
set(embedded_system_default_default_XC8_FILE_TYPE_link)
set(embedded_system_default_image_name "default.elf")
set(embedded_system_default_image_base_name "default")

# The output directory of the final image.
set(embedded_system_default_output_dir "${CMAKE_CURRENT_SOURCE_DIR}/../../../out/embedded_system")

# The full path to the final image.
set(embedded_system_default_full_path_to_image ${embedded_system_default_output_dir}/${embedded_system_default_image_name})

# Potential output file extensions
set(output_extensions
    .hex
    .hxl
    .mum
    .o
    .sdb
    .sym
    .cmf)
list(TRANSFORM output_extensions PREPEND "${embedded_system_default_output_dir}/${embedded_system_default_image_base_name}")
