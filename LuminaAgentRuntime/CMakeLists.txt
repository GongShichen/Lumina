cmake_minimum_required(VERSION 3.22)

project(LuminaAgentRuntime LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(LUMINA_BUILD_SHARED "Build the shared LuminaAgentRuntimeCore library" ON)
option(LUMINA_BUILD_STATIC "Build the static LuminaAgentRuntimeCore library" ON)
option(LUMINA_BUILD_LINUX_SAMPLE "Build the Linux C ABI conformance sample" ON)
option(LUMINA_BUILD_ANDROID_JNI "Build the Android JNI binding when JNI is available" OFF)

set(LUMINA_RUNTIME_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/Sources/LuminaAgentRuntimeCore")

set(LUMINA_RUNTIME_SOURCES
    "${LUMINA_RUNTIME_ROOT}/Callbacks/src/Callbacks.cpp"
    "${LUMINA_RUNTIME_ROOT}/Context/src/ContextManager.cpp"
    "${LUMINA_RUNTIME_ROOT}/Contract/src/Contract.cpp"
    "${LUMINA_RUNTIME_ROOT}/Envelope/src/TaskEnvelopeBuilder.cpp"
    "${LUMINA_RUNTIME_ROOT}/Hooks/src/Hooks.cpp"
    "${LUMINA_RUNTIME_ROOT}/Json/src/Json.cpp"
    "${LUMINA_RUNTIME_ROOT}/Observation/src/ObservationBuilder.cpp"
    "${LUMINA_RUNTIME_ROOT}/Pipeline/src/AgentPipeline.cpp"
    "${LUMINA_RUNTIME_ROOT}/Planner/src/PlannerInputBuilder.cpp"
    "${LUMINA_RUNTIME_ROOT}/ReAct/src/ReAct.cpp"
    "${LUMINA_RUNTIME_ROOT}/Runtime/src/LuminaAgentRuntime.cpp"
    "${LUMINA_RUNTIME_ROOT}/Runtime/src/Runtime.cpp"
    "${LUMINA_RUNTIME_ROOT}/Session/src/Session.cpp"
    "${LUMINA_RUNTIME_ROOT}/Status/src/RunStatus.cpp"
    "${LUMINA_RUNTIME_ROOT}/Streaming/src/StreamingModelRunner.cpp"
    "${LUMINA_RUNTIME_ROOT}/Tool/src/ToolExecutor.cpp"
    "${LUMINA_RUNTIME_ROOT}/Tool/src/ToolRegistry.cpp"
    "${LUMINA_RUNTIME_ROOT}/Trace/src/TraceRecorder.cpp"
)

set(LUMINA_RUNTIME_INCLUDE_DIRS
    "${LUMINA_RUNTIME_ROOT}/Budget/include"
    "${LUMINA_RUNTIME_ROOT}/Callbacks/include"
    "${LUMINA_RUNTIME_ROOT}/Context/include"
    "${LUMINA_RUNTIME_ROOT}/Contract/include"
    "${LUMINA_RUNTIME_ROOT}/Envelope/include"
    "${LUMINA_RUNTIME_ROOT}/Hooks/include"
    "${LUMINA_RUNTIME_ROOT}/Json/include"
    "${LUMINA_RUNTIME_ROOT}/Observation/include"
    "${LUMINA_RUNTIME_ROOT}/Pipeline/include"
    "${LUMINA_RUNTIME_ROOT}/Planner/include"
    "${LUMINA_RUNTIME_ROOT}/ReAct/include"
    "${LUMINA_RUNTIME_ROOT}/Runtime/include"
    "${LUMINA_RUNTIME_ROOT}/Session/include"
    "${LUMINA_RUNTIME_ROOT}/Status/include"
    "${LUMINA_RUNTIME_ROOT}/Streaming/include"
    "${LUMINA_RUNTIME_ROOT}/Tool/include"
    "${LUMINA_RUNTIME_ROOT}/Trace/include"
)

function(configure_lumina_runtime_target target_name)
    target_sources(${target_name} PRIVATE ${LUMINA_RUNTIME_SOURCES})
    target_include_directories(${target_name}
        PUBLIC
            "$<BUILD_INTERFACE:${LUMINA_RUNTIME_ROOT}/Runtime/include>"
            "$<INSTALL_INTERFACE:include>"
        PRIVATE
            ${LUMINA_RUNTIME_INCLUDE_DIRS}
    )
    target_compile_features(${target_name} PUBLIC cxx_std_17)
endfunction()

if(LUMINA_BUILD_SHARED)
    add_library(lumina_agent_runtime_core SHARED)
    configure_lumina_runtime_target(lumina_agent_runtime_core)
    set_target_properties(lumina_agent_runtime_core PROPERTIES
        OUTPUT_NAME "lumina_agent_runtime_core"
        PUBLIC_HEADER "${LUMINA_RUNTIME_ROOT}/Runtime/include/LuminaAgentRuntime.h"
    )
endif()

if(LUMINA_BUILD_STATIC)
    add_library(lumina_agent_runtime_core_static STATIC)
    configure_lumina_runtime_target(lumina_agent_runtime_core_static)
    set_target_properties(lumina_agent_runtime_core_static PROPERTIES
        OUTPUT_NAME "lumina_agent_runtime_core"
        PUBLIC_HEADER "${LUMINA_RUNTIME_ROOT}/Runtime/include/LuminaAgentRuntime.h"
    )
endif()

if(LUMINA_BUILD_LINUX_SAMPLE AND LUMINA_BUILD_STATIC)
    add_executable(lumina_runtime_linux_fake_conformance
        Bindings/Linux/samples/fake_conformance_host.cpp
    )
    target_link_libraries(lumina_runtime_linux_fake_conformance
        PRIVATE lumina_agent_runtime_core_static
    )
endif()

if(LUMINA_BUILD_ANDROID_JNI)
    find_package(JNI REQUIRED)
    add_library(lumina_agent_runtime_android_jni SHARED
        Bindings/Android/jni/lumina_runtime_jni.cpp
    )
    target_link_libraries(lumina_agent_runtime_android_jni
        PRIVATE lumina_agent_runtime_core_static JNI::JNI
    )
    target_include_directories(lumina_agent_runtime_android_jni PRIVATE ${JNI_INCLUDE_DIRS})
endif()

install(
    FILES "${LUMINA_RUNTIME_ROOT}/Runtime/include/LuminaAgentRuntime.h"
    DESTINATION include
)
