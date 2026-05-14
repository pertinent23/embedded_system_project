include("${CMAKE_CURRENT_LIST_DIR}/rule.cmake")
include("${CMAKE_CURRENT_LIST_DIR}/file.cmake")

set(embedded_system_default_library_list )

# Handle files with suffix (s|as|asm|AS|ASM|As|aS|Asm), for group default-XC8
if(embedded_system_default_default_XC8_FILE_TYPE_assemble)
add_library(embedded_system_default_default_XC8_assemble OBJECT ${embedded_system_default_default_XC8_FILE_TYPE_assemble})
    embedded_system_default_default_XC8_assemble_rule(embedded_system_default_default_XC8_assemble)
    list(APPEND embedded_system_default_library_list "$<TARGET_OBJECTS:embedded_system_default_default_XC8_assemble>")

endif()

# Handle files with suffix S, for group default-XC8
if(embedded_system_default_default_XC8_FILE_TYPE_assemblePreprocess)
add_library(embedded_system_default_default_XC8_assemblePreprocess OBJECT ${embedded_system_default_default_XC8_FILE_TYPE_assemblePreprocess})
    embedded_system_default_default_XC8_assemblePreprocess_rule(embedded_system_default_default_XC8_assemblePreprocess)
    list(APPEND embedded_system_default_library_list "$<TARGET_OBJECTS:embedded_system_default_default_XC8_assemblePreprocess>")

endif()

# Handle files with suffix [cC], for group default-XC8
if(embedded_system_default_default_XC8_FILE_TYPE_compile)
add_library(embedded_system_default_default_XC8_compile OBJECT ${embedded_system_default_default_XC8_FILE_TYPE_compile})
    embedded_system_default_default_XC8_compile_rule(embedded_system_default_default_XC8_compile)
    list(APPEND embedded_system_default_library_list "$<TARGET_OBJECTS:embedded_system_default_default_XC8_compile>")

endif()


# Main target for this project
add_executable(embedded_system_default_image_iIcVxxPP ${embedded_system_default_library_list})

set_target_properties(embedded_system_default_image_iIcVxxPP PROPERTIES
    OUTPUT_NAME "default"
    SUFFIX ".elf"
    ADDITIONAL_CLEAN_FILES "${output_extensions}"
    RUNTIME_OUTPUT_DIRECTORY "${embedded_system_default_output_dir}")
target_link_libraries(embedded_system_default_image_iIcVxxPP PRIVATE ${embedded_system_default_default_XC8_FILE_TYPE_link})

# Add the link options from the rule file.
embedded_system_default_link_rule( embedded_system_default_image_iIcVxxPP)


