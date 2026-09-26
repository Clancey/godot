/**************************************************************************/
/*  test_metal_shader_bindings.cpp                                        */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

#include "tests/test_macros.h"

TEST_FORCE_LINK(test_metal_shader_bindings)

#include "modules/modules_enabled.gen.h"

#if defined(METAL_ENABLED) && defined(MODULE_GLSLANG_ENABLED)

#include "core/io/marshalls.h"
#include "drivers/metal/rendering_context_driver_metal.h"
#include "drivers/metal/rendering_shader_container_metal.h"
#include "servers/rendering/rendering_device.h"

#include "modules/glslang/shader_compile.h"

namespace TestMetalShaderBindings {

TEST_CASE("[Metal] Layered rasterization map supplies the logical framebuffer extent") {
	RenderingContextDriverMetal context;
	REQUIRE(context.initialize() == OK);
	RenderingDevice rd;
	REQUIRE(rd.initialize(&context) == OK);
	MTL::Device *device = context.get_metal_device();
	if (String::utf8(device->name()->utf8String()).contains("Paravirtual")) {
		// Virtualized macOS GPUs (e.g. CI runners) advertise layered rate maps but leave the attachments unwritten.
		MESSAGE("Skipping: layered rasterization rate maps are not rendered by the paravirtual Metal device.");
		return;
	}
	REQUIRE(device->supportsRasterizationRateMap(2));
	float rates[] = { 0.35f, 0.55f, 0.35f };
	auto layer = NS::TransferPtr(MTL::RasterizationRateLayerDescriptor::alloc()->init(MTL::Size(3, 3, 1), rates, rates));
	auto descriptor = NS::TransferPtr(MTL::RasterizationRateMapDescriptor::alloc()->init());
	descriptor->setScreenSize(MTL::Size(4338, 3478, 1));
	descriptor->setLayer(layer.get(), 0);
	descriptor->setLayer(layer.get(), 1);
	auto map = NS::TransferPtr(device->newRasterizationRateMap(descriptor.get()));
	REQUIRE(map);
	MTL::Size physical = map->physicalSize(0);
	REQUIRE(physical.width < 4338);
	REQUIRE(physical.height < 3478);

	RD::TextureFormat format;
	format.texture_type = RD::TEXTURE_TYPE_2D_ARRAY;
	format.format = RD::DATA_FORMAT_R16G16B16A16_SFLOAT;
	format.width = physical.width;
	format.height = physical.height;
	format.array_layers = 2;
	format.usage_bits = RD::TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RD::TEXTURE_USAGE_CAN_COPY_FROM_BIT;
	RID color = rd.texture_create(format, RD::TextureView());
	format.format = RD::DATA_FORMAT_D32_SFLOAT_S8_UINT;
	format.usage_bits = RD::TEXTURE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | RD::TEXTURE_USAGE_CAN_COPY_FROM_BIT;
	RID depth = rd.texture_create(format, RD::TextureView());
	REQUIRE(color.is_valid());
	REQUIRE(depth.is_valid());
	RID rate = rd.texture_create_from_extension(RD::TEXTURE_TYPE_2D_ARRAY, RD::DATA_FORMAT_R8_UINT, RD::TEXTURE_SAMPLES_1,
			RD::TEXTURE_USAGE_VRS_ATTACHMENT_BIT | RD::TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RD::TEXTURE_USAGE_SAMPLING_BIT | RD::TEXTURE_USAGE_STORAGE_BIT,
			(uint64_t)map.get(), 4338, 3478, 1, 2, 1);
	REQUIRE(rate.is_valid());
	RID missing_map = rd.framebuffer_create({ color, depth }, RD::INVALID_ID, 2);
	RID with_map = rd.framebuffer_create({ color, depth, rate }, RD::INVALID_ID, 2);
	REQUIRE(missing_map.is_valid());
	REQUIRE(with_map.is_valid());
	const Rect2 region(0, 0, 4338, 3478);
	Vector<Color> clear = { Color(0, 0, 0, 1) };
	ERR_PRINT_OFF;
	CHECK(rd.draw_list_begin(missing_map, RD::DRAW_CLEAR_ALL, clear, 0, 0, region) == int64_t(RD::INVALID_ID));
	ERR_PRINT_ON;

	Vector<RD::ShaderStageSPIRVData> stages;
	stages.resize(2);
	String error;
	stages.write[0].shader_stage = RD::SHADER_STAGE_VERTEX;
	stages.write[0].spirv = compile_glslang_shader(RD::SHADER_STAGE_VERTEX, R"(
#version 450
#extension GL_EXT_multiview : require
layout(location = 0) flat out uint eye;
void main() {
	vec2 vertices[3] = vec2[](vec2(-0.8,-0.8), vec2(0.8,-0.8), vec2(0,0.8));
	gl_Position = vec4(vertices[gl_VertexIndex], 0.5, 1);
	eye = gl_ViewIndex;
}
)",
			RD::SHADER_LANGUAGE_VULKAN_VERSION_1_1, RD::SHADER_SPIRV_VERSION_1_3, &error);
	REQUIRE_MESSAGE(error.is_empty(), error);
	stages.write[1].shader_stage = RD::SHADER_STAGE_FRAGMENT;
	stages.write[1].spirv = compile_glslang_shader(RD::SHADER_STAGE_FRAGMENT, R"(
#version 450
layout(location = 0) flat in uint eye;
layout(location = 0) out vec4 color;
void main() { color = eye == 0 ? vec4(1,0,0,1) : vec4(0,1,0,1); }
)",
			RD::SHADER_LANGUAGE_VULKAN_VERSION_1_1, RD::SHADER_SPIRV_VERSION_1_3, &error);
	REQUIRE_MESSAGE(error.is_empty(), error);
	RID shader = rd.shader_create_from_spirv(stages);
	REQUIRE(shader.is_valid());
	RD::PipelineDepthStencilState depth_state;
	depth_state.enable_depth_test = true;
	depth_state.enable_depth_write = true;
	depth_state.depth_compare_operator = RD::COMPARE_OP_GREATER;
	RID pipeline = rd.render_pipeline_create(shader, rd.framebuffer_get_format(with_map), RD::INVALID_ID, RD::RENDER_PRIMITIVE_TRIANGLES,
			RD::PipelineRasterizationState(), RD::PipelineMultisampleState(), depth_state, RD::PipelineColorBlendState::create_disabled());
	REQUIRE(pipeline.is_valid());
	RD::DrawListID list = rd.draw_list_begin(with_map, RD::DRAW_CLEAR_ALL, clear, 0, 0, region);
	REQUIRE(list != int64_t(RD::INVALID_ID));
	rd.draw_list_bind_render_pipeline(list, pipeline);
	rd.draw_list_draw(list, false, 1, 3);
	rd.draw_list_end();
	rd.submit();
	rd.sync();
	auto queue = reinterpret_cast<MTL::CommandQueue *>(rd.get_driver_resource(RD::DRIVER_RESOURCE_COMMAND_QUEUE));
	auto native_depth = reinterpret_cast<MTL::Texture *>(rd.get_driver_resource(RD::DRIVER_RESOURCE_TEXTURE, depth));
	for (uint32_t eye = 0; eye < 2; eye++) {
		Vector<uint8_t> pixels = rd.texture_get_data(color, eye);
		MTL::Coordinate2D center = map->mapScreenToPhysicalCoordinates(MTL::Coordinate2D(2169, 1739), eye);
		size_t index = size_t(center.y) * physical.width + size_t(center.x);
		auto depth_sample = NS::TransferPtr(device->newBuffer(256, MTL::ResourceStorageModeShared));
		auto command = queue->commandBuffer();
		auto blit = command->blitCommandEncoder();
		blit->copyFromTexture(native_depth, eye, 0, MTL::Origin(center.x, center.y, 0), MTL::Size(1, 1, 1), depth_sample.get(), 0, 256, 256, MTL::BlitOptionDepthFromDepthStencil);
		blit->endEncoding();
		command->commit();
		command->waitUntilCompleted();
		REQUIRE(command->status() == MTL::CommandBufferStatusCompleted);
		REQUIRE(pixels.size() >= (index + 1) * 8);
		CHECK(Math::half_to_float(decode_uint16(pixels.ptr() + index * 8)) == (eye == 0 ? 1.0f : 0.0f));
		CHECK(Math::half_to_float(decode_uint16(pixels.ptr() + index * 8 + 2)) == (eye == 1 ? 1.0f : 0.0f));
		CHECK(*static_cast<float *>(depth_sample->contents()) == doctest::Approx(0.5f));
	}
	rd.free_rid(pipeline);
	rd.free_rid(shader);
	rd.free_rid(with_map);
	rd.free_rid(missing_map);
	rd.free_rid(rate);
	rd.free_rid(depth);
	rd.free_rid(color);
}

TEST_CASE("[Metal] Unused resources do not reserve direct binding slots") {
	using RDC = RenderingDeviceCommons;
	using Container = RenderingShaderContainerMetal;

	const String declarations = R"(
#version 450
layout(set = 0, binding = 0) uniform texture2D unused_textures[28];
layout(set = 0, binding = 1) uniform sampler unused_sampler;
layout(set = 1, binding = 0) uniform sampler2D vertex_texture;
layout(set = 1, binding = 1) uniform sampler2D shared_texture;
)";
	const String vertex_source = declarations + R"(
void main() {
	gl_Position = textureLod(vertex_texture, vec2(0.0), 0.0) +
			textureLod(shared_texture, vec2(0.0), 0.0);
}
)";
	const String fragment_source = declarations + R"(
layout(set = 2, binding = 0) uniform sampler2D material_textures[6];
layout(location = 0) out vec4 color;
void main() {
	color = texture(shared_texture, vec2(0.0));
	for (int i = 0; i < 6; i++) {
		color += texture(material_textures[i], vec2(0.0));
	}
}
)";

	LocalVector<RDC::ShaderStageSPIRVData> stages;
	stages.resize(2);
	stages[0].shader_stage = RDC::SHADER_STAGE_VERTEX;
	stages[1].shader_stage = RDC::SHADER_STAGE_FRAGMENT;
	String error;
	stages[0].spirv = compile_glslang_shader(stages[0].shader_stage, vertex_source, RDC::SHADER_LANGUAGE_VULKAN_VERSION_1_1, RDC::SHADER_SPIRV_VERSION_1_3, &error);
	REQUIRE_MESSAGE(error.is_empty(), error);
	REQUIRE_FALSE(stages[0].spirv.is_empty());
	stages[1].spirv = compile_glslang_shader(stages[1].shader_stage, fragment_source, RDC::SHADER_LANGUAGE_VULKAN_VERSION_1_1, RDC::SHADER_SPIRV_VERSION_1_3, &error);
	REQUIRE_MESSAGE(error.is_empty(), error);
	REQUIRE_FALSE(stages[1].spirv.is_empty());

	MetalDeviceProfile profile;
	profile.platform = MetalDeviceProfile::Platform::iOS;
	profile.gpu = MetalDeviceProfile::GPU::Apple2;
	profile.features.msl_version = 20300;

	bool argument_buffers = false;
	SUBCASE("Direct binding compacts unused declarations") {}
	SUBCASE("Argument buffer layout keeps unused declarations") {
		argument_buffers = true;
		profile.gpu = MetalDeviceProfile::GPU::Apple8;
		profile.features.use_argument_buffers = true;
	}

	Ref<Container> container;
	container.instantiate();
	container->set_device_profile(&profile);
	REQUIRE(container->set_code_from_spirv("unused_texture_slots", stages));
	auto reflection = container->get_metal_shader_reflection();
	REQUIRE(reflection.uniform_sets.size() == 3);
	REQUIRE(reflection.uniform_sets[0].size() == 2);
	REQUIRE(reflection.uniform_sets[1].size() == 2);
	REQUIRE(reflection.uniform_sets[2].size() == 1);
	if (argument_buffers) {
		CHECK(reflection.uniform_sets[0][0].arg_buffer.texture == 0);
		CHECK(reflection.uniform_sets[0][1].arg_buffer.sampler == 28);
		CHECK(reflection.uniform_sets[1][0].arg_buffer.texture == 0);
		CHECK(reflection.uniform_sets[1][1].arg_buffer.texture == 2);
		CHECK(reflection.uniform_sets[2][0].arg_buffer.texture == 0);
		CHECK(reflection.uniform_sets[2][0].arg_buffer.sampler == 6);
	} else {
		CHECK(reflection.uniform_sets[0][0].active_stages == 0);
		CHECK(reflection.uniform_sets[0][0].slot.texture == UINT32_MAX);
		CHECK(reflection.uniform_sets[0][1].slot.sampler == UINT32_MAX);
		CHECK(reflection.uniform_sets[1][0].active_stages == RDC::SHADER_STAGE_VERTEX_BIT);
		CHECK(reflection.uniform_sets[1][0].slot.texture == 0);
		CHECK(reflection.uniform_sets[1][1].active_stages == (RDC::SHADER_STAGE_VERTEX_BIT | RDC::SHADER_STAGE_FRAGMENT_BIT));
		CHECK(reflection.uniform_sets[1][1].slot.texture == 1);
		CHECK(reflection.uniform_sets[2][0].slot.texture == 2);
		CHECK(reflection.uniform_sets[2][0].array_length == 6);
	}

	Ref<Container> restored;
	restored.instantiate();
	PackedByteArray bytes = container->to_bytes();
	CHECK(restored->is_cache_compatible(bytes));
	REQUIRE(restored->from_bytes(bytes));
	auto restored_reflection = restored->get_metal_shader_reflection();
	CHECK(restored_reflection.uniform_sets[0][0].slot.texture == reflection.uniform_sets[0][0].slot.texture);
	CHECK(restored_reflection.uniform_sets[2][0].slot.texture == reflection.uniform_sets[2][0].slot.texture);

	// The fourth header word records the backend's native format version.
	encode_uint32(Container::FORMAT_VERSION - 1, bytes.ptrw() + 3 * sizeof(uint32_t));
	CHECK_FALSE(restored->is_cache_compatible(bytes));
	CHECK(restored->from_bytes(bytes));
	encode_uint32(Container::FORMAT_VERSION + 1, bytes.ptrw() + 3 * sizeof(uint32_t));
	CHECK_FALSE(restored->is_cache_compatible(bytes));
	encode_uint32(Container::FORMAT_VERSION, bytes.ptrw() + 3 * sizeof(uint32_t));
	encode_uint32(0, bytes.ptrw());
	CHECK_FALSE(restored->is_cache_compatible(bytes));
	bytes.resize(4);
	CHECK_FALSE(restored->is_cache_compatible(bytes));
}

} // namespace TestMetalShaderBindings

#endif // METAL_ENABLED && MODULE_GLSLANG_ENABLED
