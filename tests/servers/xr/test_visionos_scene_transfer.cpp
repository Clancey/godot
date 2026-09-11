/**************************************************************************/
/*  test_visionos_scene_transfer.cpp                                      */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md).   */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                     */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining   */
/* a copy of this software and associated documentation files (the         */
/* "Software"), to deal in the Software without restriction, including     */
/* without limitation the rights to use, copy, modify, merge, publish,     */
/* distribute, sublicense, and/or sell copies of the Software, and to      */
/* permit persons to whom the Software is furnished to do so, subject to   */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,         */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,    */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE       */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

#include "tests/test_macros.h"

TEST_FORCE_LINK(test_visionos_scene_transfer)

#ifdef METAL_ENABLED

#include "core/io/marshalls.h"
#include "core/string/print_string.h"
#include "drivers/metal/rendering_context_driver_metal.h"

#include "modules/visionos_xr/visionos_scene_transfer.h"

namespace TestVisionOSSceneTransfer {

struct DepthPyramidFixture {
	NS::SharedPtr<MTL::Texture> texture;
	Vector<NS::SharedPtr<MTL::Texture>> views;
	NS::SharedPtr<MTL::ComputePipelineState> tiles_pipeline;
	NS::SharedPtr<MTL::ComputePipelineState> mip_pipeline;

	DepthPyramidFixture(MTL::Device *p_device, MTL::Library *p_library, uint32_t p_width, uint32_t p_height) {
		NS::Error *error = nullptr;
		auto tiles = NS::TransferPtr(p_library->newFunction(NS::String::string("scene_depth_tiles", NS::UTF8StringEncoding)));
		auto mip = NS::TransferPtr(p_library->newFunction(NS::String::string("scene_depth_mip", NS::UTF8StringEncoding)));
		tiles_pipeline = NS::TransferPtr(p_device->newComputePipelineState(tiles.get(), &error));
		REQUIRE_MESSAGE(tiles_pipeline, (error ? error->localizedDescription()->utf8String() : "No depth tiles pipeline"));
		mip_pipeline = NS::TransferPtr(p_device->newComputePipelineState(mip.get(), &error));
		REQUIRE_MESSAGE(mip_pipeline, (error ? error->localizedDescription()->utf8String() : "No depth mip pipeline"));
		auto shape = visionos_scene_depth_pyramid_shape(p_width, p_height);
		auto descriptor = NS::TransferPtr(MTL::TextureDescriptor::alloc()->init());
		descriptor->setTextureType(MTL::TextureType2DArray);
		descriptor->setPixelFormat(MTL::PixelFormatR32Float);
		descriptor->setWidth(shape.width);
		descriptor->setHeight(shape.height);
		descriptor->setMipmapLevelCount(shape.levels);
		descriptor->setArrayLength(2);
		descriptor->setStorageMode(MTL::StorageModePrivate);
		descriptor->setUsage(MTL::TextureUsageShaderRead | MTL::TextureUsageShaderWrite | MTL::TextureUsagePixelFormatView);
		texture = NS::TransferPtr(p_device->newTexture(descriptor.get()));
		REQUIRE(texture);
		for (uint32_t level = 0; level < shape.levels; level++) {
			views.push_back(NS::TransferPtr(texture->newTextureView(MTL::PixelFormatR32Float, MTL::TextureType2DArray, NS::Range::Make(level, 1), NS::Range::Make(0, 2))));
			REQUIRE(views[level]);
		}
	}

	void encode(MTL::CommandBuffer *p_command, MTL::Texture *p_depth, const simd_float4 *p_bounds) {
		for (uint32_t level = 0; level < views.size(); level++) {
			auto encoder = p_command->computeCommandEncoder();
			REQUIRE(encoder);
			auto target = views[level].get();
			encoder->setTexture(target, 1);
			if (level == 0) {
				encoder->setComputePipelineState(tiles_pipeline.get());
				encoder->setTexture(p_depth, 0);
				encoder->setBytes(p_bounds, 2 * sizeof(simd_float4), 0);
				encoder->dispatchThreadgroups(MTL::Size(target->width(), target->height(), 2), MTL::Size(16, 16, 1));
			} else {
				encoder->setComputePipelineState(mip_pipeline.get());
				encoder->setTexture(views[level - 1].get(), 0);
				encoder->dispatchThreadgroups(MTL::Size((target->width() + 7) / 8, (target->height() + 7) / 8, 2), MTL::Size(8, 8, 1));
			}
			encoder->endEncoding();
		}
	}
};

TEST_CASE("[visionOS][Metal] Source depth hierarchy preserves single texels and excludes layer padding") {
	float invalid = 0;
	SUBCASE("Finite reverse-Z depths and poisoned outside-viewport padding") {}
	SUBCASE("NaN remains a conservative blocker") {
		invalid = NAN;
	}
	SUBCASE("Infinity remains a conservative blocker") {
		invalid = INFINITY;
	}
	SUBCASE("Negative depth remains a conservative blocker") {
		invalid = -1;
	}
	RenderingContextDriverMetal context;
	REQUIRE(context.initialize() == OK);
	auto device = context.get_metal_device();
	NS::Error *error = nullptr;
	auto options = NS::TransferPtr(MTL::CompileOptions::alloc()->init());
	auto library = NS::TransferPtr(device->newLibrary(NS::String::string(VISIONOS_SCENE_TRANSFER_SHADER, NS::UTF8StringEncoding), options.get(), &error));
	REQUIRE_MESSAGE(library, (error ? error->localizedDescription()->utf8String() : "No hierarchy library"));
	constexpr uint32_t width = 65, height = 33;
	DepthPyramidFixture pyramid(device, library.get(), width, height);
	CHECK(pyramid.texture->width() == 4);
	CHECK(pyramid.texture->height() == 2);
	CHECK(pyramid.views.size() == 3);
	auto descriptor = NS::TransferPtr(MTL::TextureDescriptor::alloc()->init());
	descriptor->setTextureType(MTL::TextureType2DArray);
	descriptor->setPixelFormat(MTL::PixelFormatR32Float);
	descriptor->setWidth(width);
	descriptor->setHeight(height);
	descriptor->setArrayLength(2);
	descriptor->setStorageMode(MTL::StorageModeShared);
	descriptor->setUsage(MTL::TextureUsageShaderRead);
	auto source = NS::TransferPtr(device->newTexture(descriptor.get()));
	REQUIRE(source);
	simd_float4 bounds[] = { simd_make_float4(0, 0, width, height),
		visionos_scene_physical_bounds(simd_make_float2(3.25f, 2.25f), simd_make_float2(63, 31), width, height) };
	Vector<float> pixels[2];
	for (uint32_t eye = 0; eye < 2; eye++) {
		pixels[eye].resize(width * height);
		for (uint32_t y = 0; y < height; y++) {
			for (uint32_t x = 0; x < width; x++) {
				bool inside = x >= bounds[eye].x && x < bounds[eye].z && y >= bounds[eye].y && y < bounds[eye].w;
				pixels[eye].ptrw()[y * width + x] = inside ? 0 : 1;
			}
		}
		uint32_t x = bounds[eye].z - 1, y = bounds[eye].w - 1;
		pixels[eye].ptrw()[y * width + x] = eye ? 0.91f : 0.73f;
		if (invalid != 0) {
			pixels[eye].ptrw()[8 * width + 8] = invalid;
		}
		source->replaceRegion(MTL::Region(0, 0, 0, width, height, 1), 0, eye, pixels[eye].ptr(), width * 4, width * height * 4);
	}
	auto queue = NS::TransferPtr(device->newCommandQueue());
	auto command = queue->commandBuffer();
	pyramid.encode(command, source.get(), bounds);
	auto samples = NS::TransferPtr(device->newBuffer(4096, MTL::ResourceStorageModeShared));
	REQUIRE(samples);
	auto blit = command->blitCommandEncoder();
	Vector<size_t> offsets;
	size_t offset = 0;
	for (uint32_t level = 0; level < pyramid.views.size(); level++) {
		auto view = pyramid.views[level].get();
		for (uint32_t eye = 0; eye < 2; eye++) {
			offsets.push_back(offset);
			blit->copyFromTexture(view, eye, 0, MTL::Origin(0, 0, 0), MTL::Size(view->width(), view->height(), 1), samples.get(), offset, 256, view->height() * 256);
			offset += view->height() * 256;
		}
	}
	REQUIRE(offset <= samples->length());
	blit->endEncoding();
	command->commit();
	command->waitUntilCompleted();
	REQUIRE(command->status() == MTL::CommandBufferStatusCompleted);
	auto data = static_cast<const uint8_t *>(samples->contents());
	for (uint32_t level = 0; level < pyramid.views.size(); level++) {
		uint32_t span = 32 << level;
		auto view = pyramid.views[level].get();
		for (uint32_t eye = 0; eye < 2; eye++) {
			for (uint32_t y = 0; y < view->height(); y++) {
				for (uint32_t x = 0; x < view->width(); x++) {
					float expected = 0;
					for (uint32_t sy = y * span; sy < MIN((y + 1) * span, height); sy++) {
						for (uint32_t sx = x * span; sx < MIN((x + 1) * span, width); sx++) {
							if (sx >= bounds[eye].x && sx < bounds[eye].z && sy >= bounds[eye].y && sy < bounds[eye].w) {
								float value = pixels[eye][sy * width + sx];
								expected = MAX(expected, std::isfinite(value) && value >= 0 && value <= 1 ? value : 1);
							}
						}
					}
					CHECK(*reinterpret_cast<const float *>(data + offsets[level * 2 + eye] + y * 256 + x * 4) == expected);
				}
			}
		}
	}
}

static simd_float4x4 make_projection(float p_x, float p_y, float p_offset, bool p_infinite_far = false, float near = 0.1f, float far = 50.0f) {
	return { simd_make_float4(p_x, 0, 0, 0), simd_make_float4(0, p_y, 0, 0),
		simd_make_float4(p_offset, -p_offset * 0.5f, p_infinite_far ? 0 : near / (far - near), -1),
		simd_make_float4(0, 0, p_infinite_far ? near : far * near / (far - near), 0) };
}

TEST_CASE("[visionOS] Eye mapping preserves rays and transforms translated origins at their actual depth") {
	simd_float4x4 source = simd_matrix4x4(simd_quaternion(0.2f, simd_make_float3(0, 1, 0)));
	simd_float4x4 destination = simd_matrix4x4(simd_quaternion(-0.15f, simd_make_float3(1, 0, 0)));
	source.columns[3] = destination.columns[3] = simd_make_float4(-0.032f, 0.01f, 0.02f, 1);
	auto source_projection = make_projection(1.2f, 1.4f, 0.1f);
	auto destination_projection = make_projection(1.5f, 1.1f, -0.05f);
	VisionOSSceneTransferParameters parameters{};
	auto comparison = visionos_scene_transfer_eye_mapping(source, destination, source_projection, destination_projection, parameters);
	CHECK(comparison.compared);
	CHECK(comparison.original_mismatch);
	CHECK(comparison.rejection == VisionOSEyeTransformComparison::NONE);
	CHECK(comparison.rotation_degrees > 10);
	CHECK_FALSE(comparison.positional_reprojection);
	for (uint32_t axis = 0; axis < 3; axis++) {
		CHECK(comparison.translation_m[axis] == 0);
	}
	// A same-origin rotation maps the same ray at both near and far depths.
	auto near = simd_mul(parameters.destination_to_source, simd_make_float4(0.2f, -0.3f, 0.95f, 1));
	auto far = simd_mul(parameters.destination_to_source, simd_make_float4(0.2f, -0.3f, 0.05f, 1));
	CHECK(near.x / near.w == doctest::Approx(far.x / far.w));
	CHECK(near.y / near.w == doctest::Approx(far.y / far.w));
	for (float depth : { 0.05f, 0.3f, 0.95f }) {
		simd_float4 clip = simd_make_float4(0.2f, -0.3f, depth, 1);
		auto world = simd_mul(destination, simd_mul(simd_inverse(destination_projection), clip));
		auto expected = simd_mul(source_projection, simd_mul(simd_inverse(source), world));
		auto actual = simd_mul(parameters.destination_to_source, clip);
		auto round_trip = simd_mul(parameters.source_to_destination, actual);
		for (uint32_t axis = 0; axis < 3; axis++) {
			CHECK(actual[axis] / actual.w == doctest::Approx(expected[axis] / expected.w));
			CHECK(round_trip[axis] / round_trip.w == doctest::Approx(clip[axis]));
		}
	}
	for (uint32_t axis = 0; axis < 3; axis++) {
		for (float offset : { -0.00002f, 0.00002f, 0.001f }) {
			auto translated = destination;
			translated.columns[3][axis] += offset;
			comparison = visionos_scene_transfer_eye_mapping(source, translated, source_projection, destination_projection, parameters);
			CHECK(comparison.rejection == VisionOSEyeTransformComparison::NONE);
			CHECK(comparison.positional_reprojection);
			CHECK(parameters.positional_reprojection == 1);
			CHECK(comparison.translation_m[axis] == doctest::Approx(offset));
			CHECK(comparison.rotation_degrees > 10);
			for (float depth : { 0.05f, 0.3f, 0.95f }) {
				auto clip = simd_make_float4(0.2f, -0.3f, depth, 1);
				auto world = simd_mul(translated, simd_mul(simd_inverse(destination_projection), clip));
				auto expected = simd_mul(source_projection, simd_mul(simd_inverse(source), world));
				auto actual = simd_mul(parameters.destination_to_source, clip);
				for (uint32_t component = 0; component < 3; component++) {
					CHECK(actual[component] / actual.w == doctest::Approx(expected[component] / expected.w));
				}
			}
		}
	}
	auto invalid = source;
	invalid.columns[0].w = 0.1f;
	CHECK(visionos_scene_transfer_eye_mapping(invalid, destination, source_projection, destination_projection, parameters).rejection == VisionOSEyeTransformComparison::INVALID_TRANSFORM);
	invalid = source;
	invalid.columns[0] = simd_make_float4(0);
	CHECK(visionos_scene_transfer_eye_mapping(invalid, destination, source_projection, destination_projection, parameters).rejection == VisionOSEyeTransformComparison::INVALID_TRANSFORM);
	invalid = source;
	invalid.columns[0].x = NAN;
	CHECK(visionos_scene_transfer_eye_mapping(invalid, destination, source_projection, destination_projection, parameters).rejection == VisionOSEyeTransformComparison::INVALID_TRANSFORM);
	CHECK(visionos_scene_transfer_eye_mapping(source, destination, source_projection, simd_float4x4{}, parameters).rejection == VisionOSEyeTransformComparison::INVALID_PROJECTION);
}

TEST_CASE("[visionOS] Mixed loading remains transparent before scene or pipeline readiness") {
	for (double time : { 0.0, 0.25, 1.0, 31.0, 1000.0 }) {
		auto mixed = visionos_scene_loading_color(true, time);
		CHECK(simd_all(mixed == simd_make_double4(0, 0, 0, 0)));
		auto full = visionos_scene_loading_color(false, time);
		CHECK(full.x == doctest::Approx(0.02 + 0.01 * std::sin(time * 2.0)));
		CHECK((full.y == full.x));
		CHECK((full.z == full.x));
		CHECK(full.w == 1);
	}
}

TEST_CASE("[visionOS][Metal] Completed scene transfer preserves stereo depth and remaps native VRS") {
	bool asymmetric_eyes = false;
	bool rotated_eyes = false;
	bool near_clip = false;
	bool outside_frustum = false;
	bool infinite_far = false;
	bool background = false;
	bool positional = false;
	bool use_vrs = true;
	bool thin_occluder = false;
	bool cap_ramp = false;
	bool physical_depth_range = false;
	bool far_surface = false;
	bool mixed = false;
	bool source_is_srgb = false;
	bool transparent_foreground = false;
	float source_alpha = 1;
	enum Benchmark {
		NO_BENCHMARK,
		BASELINE,
		OBSERVED_PLANES,
		OBSERVED_SKY,
		CAP_SKY,
		SPARSE_SKY,
		MIXED_PLANES
	};
	Benchmark benchmark = NO_BENCHMARK;
	SUBCASE("Matching eye-layer profiles") {}
	SUBCASE("Independent asymmetric eye-layer profiles") {
		asymmetric_eyes = true;
	}
	SUBCASE("Independent source and destination eye rotations with asymmetric VRS") {
		asymmetric_eyes = rotated_eyes = true;
	}
	SUBCASE("Rotated eyes clip depth outside the destination near plane") {
		asymmetric_eyes = rotated_eyes = near_clip = true;
	}
	SUBCASE("Rotated eyes leave uncovered source rays transparent") {
		asymmetric_eyes = rotated_eyes = outside_frustum = true;
	}
	SUBCASE("Rotated eyes preserve infinite-far background depth") {
		asymmetric_eyes = rotated_eyes = infinite_far = background = true;
	}
	SUBCASE("Rotated eyes preserve clear background with a finite far plane") {
		asymmetric_eyes = rotated_eyes = background = true;
	}
	SUBCASE("Translated eyes preserve asymmetric stereo planes") {
		asymmetric_eyes = positional = true;
	}
	SUBCASE("Translated and rotated eyes preserve asymmetric stereo planes") {
		asymmetric_eyes = rotated_eyes = positional = true;
	}
	SUBCASE("Translated eyes clip surfaces at the destination near plane") {
		asymmetric_eyes = rotated_eyes = positional = near_clip = true;
	}
	SUBCASE("Translated eyes preserve directional background with finite far") {
		asymmetric_eyes = positional = background = true;
	}
	SUBCASE("Translated eyes preserve directional background with infinite far") {
		asymmetric_eyes = positional = background = infinite_far = true;
	}
	SUBCASE("Translated eyes preserve depth without rate maps") {
		asymmetric_eyes = positional = true;
		use_vrs = false;
	}
	SUBCASE("Translated rotated eyes preserve the physical 0.11 to 4000 meter range") {
		asymmetric_eyes = rotated_eyes = positional = physical_depth_range = true;
	}
	SUBCASE("Translated eyes preserve quantized surface depths near the physical far plane") {
		asymmetric_eyes = positional = physical_depth_range = far_surface = true;
	}
	SUBCASE("Translated eyes preserve thin occluders and mask disocclusion with asymmetric VRS") {
		asymmetric_eyes = positional = thin_occluder = true;
	}
	SUBCASE("Translated eyes preserve thin occluders and mask disocclusion without VRS") {
		asymmetric_eyes = positional = thin_occluder = true;
		use_vrs = false;
	}
	SUBCASE("Traversal exhaustion is transparent rather than fabricated surface or sky") {
		positional = background = thin_occluder = cap_ramp = true;
		use_vrs = false;
	}
	SUBCASE("Full physical stereo baseline GPU cost") {
		asymmetric_eyes = true;
		benchmark = BASELINE;
	}
	SUBCASE("Full physical stereo observed translation GPU cost and plane coverage") {
		asymmetric_eyes = positional = true;
		benchmark = OBSERVED_PLANES;
	}
	SUBCASE("Full physical stereo observed translation GPU cost and sky coverage") {
		asymmetric_eyes = positional = background = true;
		benchmark = OBSERVED_SKY;
	}
	SUBCASE("Full physical stereo bounded worst-case sky traversal") {
		asymmetric_eyes = positional = background = true;
		benchmark = CAP_SKY;
	}
	SUBCASE("Full physical stereo sparse-occluder empty-space traversal") {
		asymmetric_eyes = positional = background = thin_occluder = true;
		benchmark = SPARSE_SKY;
	}
	SUBCASE("Mixed opaque linear color retains geometry and converts to Display P3") {
		mixed = asymmetric_eyes = rotated_eyes = true;
	}
	SUBCASE("Mixed sRGB color decodes before positional Display P3 transfer") {
		mixed = source_is_srgb = asymmetric_eyes = positional = true;
	}
	SUBCASE("Mixed partial alpha is already associated and must not be multiplied twice") {
		mixed = asymmetric_eyes = rotated_eyes = true;
		source_alpha = 0.5f;
	}
	SUBCASE("Mixed partial alpha sRGB transfer preserves asymmetric VRS and disocclusion") {
		mixed = source_is_srgb = asymmetric_eyes = positional = thin_occluder = true;
		source_alpha = 0.5f;
	}
	SUBCASE("Mixed partial alpha sRGB transfer works without VRS") {
		mixed = source_is_srgb = asymmetric_eyes = positional = true;
		use_vrs = false;
		source_alpha = 0.5f;
	}
	SUBCASE("Mixed alpha-zero source masks discard nonzero RGB and final depth") {
		mixed = asymmetric_eyes = positional = rotated_eyes = true;
		source_alpha = 0;
	}
	SUBCASE("Mixed transparent room mask still hides virtual surfaces behind its source depth") {
		mixed = asymmetric_eyes = positional = thin_occluder = transparent_foreground = true;
	}
	SUBCASE("Mixed transparent room mask and disocclusion work without VRS") {
		mixed = asymmetric_eyes = positional = thin_occluder = transparent_foreground = true;
		use_vrs = false;
	}
	SUBCASE("Mixed finite-far zero-depth background stays transparent") {
		mixed = asymmetric_eyes = positional = background = true;
	}
	SUBCASE("Mixed infinite-far zero-depth background stays transparent under rotation") {
		mixed = asymmetric_eyes = rotated_eyes = background = infinite_far = true;
	}
	SUBCASE("Full physical stereo mixed sRGB partial-alpha GPU cost") {
		mixed = source_is_srgb = asymmetric_eyes = positional = true;
		source_alpha = 0.5f;
		benchmark = MIXED_PLANES;
	}
	RenderingContextDriverMetal context;
	REQUIRE(context.initialize() == OK);
	MTL::Device *device = context.get_metal_device();
	REQUIRE(device->supportsRasterizationRateMap(2));
	NS::Error *error = nullptr;
	auto options = NS::TransferPtr(MTL::CompileOptions::alloc()->init());
	String shader = String(VISIONOS_SCENE_TRANSFER_SHADER) + R"METAL(
struct FixtureDepth { float depth [[depth(any)]]; };
fragment FixtureDepth scene_fixture_depth(Vertex in [[stage_in]], constant float4 *rectangles [[buffer(0)]], constant float &background [[buffer(1)]],
		constant uint &ramp [[buffer(2)]], constant float2 *ramp_parameters [[buffer(3)]]) {
	if (ramp) {
		float x = floor(in.position.x) + (in.layer ? 1.0 : 0.0);
		float2 p = ramp_parameters[in.layer];
		return {clamp(x * p.x + p.y - 0.0001, 0.0, 1.0)};
	}
	float4 r = rectangles[in.layer];
	bool foreground = all(in.position.xy >= r.xy) && all(in.position.xy < r.zw);
	return {foreground ? 0.8 : background};
}
)METAL";
	auto library = NS::TransferPtr(device->newLibrary(NS::String::string(shader.utf8().get_data(), NS::UTF8StringEncoding), options.get(), &error));
	if (!library) {
		FAIL_CHECK(String(error ? error->localizedDescription()->utf8String() : "No transfer library"));
		return;
	}
	auto pipeline_descriptor = NS::TransferPtr(MTL::RenderPipelineDescriptor::alloc()->init());
	auto vertex = NS::TransferPtr(library->newFunction(NS::String::string("scene_transfer_vertex", NS::UTF8StringEncoding)));
	auto fragment = NS::TransferPtr(library->newFunction(NS::String::string("scene_transfer_fragment", NS::UTF8StringEncoding)));
	pipeline_descriptor->setVertexFunction(vertex.get());
	pipeline_descriptor->setFragmentFunction(fragment.get());
	pipeline_descriptor->setInputPrimitiveTopology(MTL::PrimitiveTopologyClassTriangle);
	pipeline_descriptor->colorAttachments()->object(0)->setPixelFormat(MTL::PixelFormatRGBA16Float);
	pipeline_descriptor->setDepthAttachmentPixelFormat(MTL::PixelFormatDepth32Float_Stencil8);
	auto pipeline = NS::TransferPtr(device->newRenderPipelineState(pipeline_descriptor.get(), &error));
	if (!pipeline) {
		FAIL_CHECK(String(error ? error->localizedDescription()->utf8String() : "No transfer pipeline"));
		return;
	}
	auto depth_descriptor = NS::TransferPtr(MTL::DepthStencilDescriptor::alloc()->init());
	depth_descriptor->setDepthCompareFunction(MTL::CompareFunctionAlways);
	depth_descriptor->setDepthWriteEnabled(true);
	auto depth_state = NS::TransferPtr(device->newDepthStencilState(depth_descriptor.get()));

	uint32_t width = 512;
	uint32_t height = 384;
	auto make_map = [&](float p_edge, float p_center) {
		float rates[] = { p_edge, p_center, p_edge };
		auto layer = NS::TransferPtr(MTL::RasterizationRateLayerDescriptor::alloc()->init(MTL::Size(3, 3, 1), rates, rates));
		auto descriptor = NS::TransferPtr(MTL::RasterizationRateMapDescriptor::alloc()->init());
		descriptor->setScreenSize(MTL::Size(width, height, 1));
		descriptor->setLayer(layer.get(), 0);
		if (asymmetric_eyes) {
			float other_rates[] = { p_center, p_edge, p_center };
			auto other_layer = NS::TransferPtr(MTL::RasterizationRateLayerDescriptor::alloc()->init(MTL::Size(3, 3, 1), other_rates, rates));
			descriptor->setLayer(other_layer.get(), 1);
		} else {
			descriptor->setLayer(layer.get(), 1);
		}
		return NS::TransferPtr(device->newRasterizationRateMap(descriptor.get()));
	};
	if (benchmark != NO_BENCHMARK) {
		for (uint32_t axis = 0; axis < 2; axis++) {
			uint32_t target = axis ? 1792 : 1888;
			uint32_t low = target, high = 8192;
			while (low < high) {
				uint32_t middle = (low + high) / 2;
				(axis ? height : width) = middle;
				auto map = make_map(0.35f, 0.85f);
				REQUIRE(map);
				auto a = map->physicalSize(0), b = map->physicalSize(1);
				uint32_t extent = axis ? MAX(a.height, b.height) : MAX(a.width, b.width);
				if (extent >= target) {
					high = middle;
				} else {
					low = middle + 1;
				}
			}
			(axis ? height : width) = low;
		}
	}
	auto source_map = make_map(0.35f, 0.85f);
	auto destination_map = make_map(0.8f, 0.4f);
	REQUIRE(source_map);
	REQUIRE(destination_map);
	auto source_size = source_map->physicalSize(0);
	auto destination_size = destination_map->physicalSize(0);
	source_size.width = MAX(source_size.width, source_map->physicalSize(1).width);
	source_size.height = MAX(source_size.height, source_map->physicalSize(1).height);
	destination_size.width = MAX(destination_size.width, destination_map->physicalSize(1).width);
	destination_size.height = MAX(destination_size.height, destination_map->physicalSize(1).height);
	if (!use_vrs) {
		source_size = destination_size = MTL::Size(width, height, 1);
	}
	auto make_texture = [&](MTL::Size p_size, MTL::PixelFormat p_format, MTL::StorageMode p_storage) {
		auto descriptor = NS::TransferPtr(MTL::TextureDescriptor::alloc()->init());
		descriptor->setTextureType(MTL::TextureType2DArray);
		descriptor->setWidth(p_size.width);
		descriptor->setHeight(p_size.height);
		descriptor->setArrayLength(2);
		descriptor->setPixelFormat(p_format);
		descriptor->setStorageMode(p_storage);
		descriptor->setUsage(MTL::TextureUsageShaderRead | MTL::TextureUsageRenderTarget);
		return NS::TransferPtr(device->newTexture(descriptor.get()));
	};
	auto source_color = make_texture(source_size, MTL::PixelFormatRGBA16Float, MTL::StorageModeShared);
	auto source_depth = make_texture(source_size, MTL::PixelFormatDepth32Float_Stencil8, MTL::StorageModePrivate);
	auto destination_color = make_texture(destination_size, MTL::PixelFormatRGBA16Float, MTL::StorageModePrivate);
	auto destination_depth = make_texture(destination_size, MTL::PixelFormatDepth32Float_Stencil8, MTL::StorageModePrivate);
	REQUIRE(source_color);
	REQUIRE(source_depth);
	REQUIRE(destination_color);
	REQUIRE(destination_depth);
	DepthPyramidFixture pyramid(device, library.get(), source_size.width, source_size.height);
	Vector<uint16_t> pixels;
	pixels.resize(source_size.width * source_size.height * 4);
	for (uint32_t eye = 0; eye < 2; eye++) {
		auto center = MTL::Coordinate2D(width * 0.5f, height * 0.5f);
		if (use_vrs) {
			center = source_map->mapScreenToPhysicalCoordinates(center, eye);
		}
		for (uint32_t y = 0; y < source_size.height; y++) {
			for (uint32_t x = 0; x < source_size.width; x++) {
				auto logical = use_vrs ? source_map->mapPhysicalToScreenCoordinates(MTL::Coordinate2D(x + 0.5f, y + 0.5f), eye) : MTL::Coordinate2D(x + 0.5f, y + 0.5f);
				uint16_t *pixel = pixels.ptrw() + (y * source_size.width + x) * 4;
				float alpha = source_alpha;
				if (transparent_foreground && x + 0.5f >= std::floor(center.x) - 1 && x + 0.5f < std::floor(center.x) + 2 &&
						y + 0.5f >= std::floor(center.y) - 12 && y + 0.5f < std::floor(center.y) + 12) {
					alpha = 0;
				}
				// Deliberately poison alpha-zero RGB. Opaque/partial pixels model
				// Godot's scene blend followed by optional tonemap sRGB encoding.
				float association = alpha > 0 ? alpha : 1;
				Color color(logical.x / width * association, logical.y / height * association, float(eye) * association, alpha);
				if (source_is_srgb) {
					color = color.linear_to_srgb();
				}
				for (uint32_t channel = 0; channel < 4; channel++) {
					pixel[channel] = Math::make_half_float(color[channel]);
				}
			}
		}
		source_color->replaceRegion(MTL::Region(0, 0, 0, source_size.width, source_size.height, 1), 0, eye, pixels.ptr(), source_size.width * 8, source_size.width * source_size.height * 8);
	}
	auto queue = NS::TransferPtr(device->newCommandQueue());
	auto command = queue->commandBuffer();
	for (uint32_t eye = 0; eye < 2; eye++) {
		auto clear = MTL::RenderPassDescriptor::renderPassDescriptor();
		clear->depthAttachment()->setTexture(source_depth.get());
		clear->depthAttachment()->setSlice(eye);
		clear->depthAttachment()->setLoadAction(MTL::LoadActionClear);
		clear->depthAttachment()->setStoreAction(MTL::StoreActionStore);
		clear->depthAttachment()->setClearDepth(background ? 0 : (far_surface ? 0.000001 * (eye + 1) : (near_clip ? 0.98 : 0.25 + eye * 0.25)));
		auto encoder = command->renderCommandEncoder(clear);
		REQUIRE(encoder);
		encoder->endEncoding();
	}
	auto rate_data = NS::TransferPtr(device->newBuffer(source_map->parameterBufferSizeAndAlign().size, MTL::ResourceStorageModeShared));
	REQUIRE(rate_data);
	source_map->copyParameterDataToBuffer(rate_data.get(), 0);
	VisionOSSceneTransferParameters parameters[2] = {};
	simd_float4x4 source_eyes[2], destination_eyes[2], source_projections[2], destination_projections[2];
	MTL::Viewport viewports[2] = {};
	simd_float4 foreground_rectangles[2] = {};
	for (uint32_t eye = 0; eye < 2; eye++) {
		parameters[eye].destination_to_source = matrix_identity_float4x4;
		parameters[eye].destination_to_source.columns[3].x = 0.1f;
		parameters[eye].destination_to_source.columns[2].z = 2;
		parameters[eye].destination_to_source.columns[3].z = -0.2f;
		parameters[eye].source_to_destination = simd_inverse(parameters[eye].destination_to_source);
		if (rotated_eyes || positional || benchmark != NO_BENCHMARK) {
			source_eyes[eye] = simd_matrix4x4(simd_mul(simd_quaternion(0.12f + eye * 0.08f, simd_make_float3(0, 1, 0)), simd_quaternion(-0.08f, simd_make_float3(1, 0, 0))));
			destination_eyes[eye] = simd_matrix4x4(simd_mul(simd_quaternion(0.1f - eye * 0.04f, simd_make_float3(0, 0, 1)), simd_quaternion(outside_frustum ? -0.65f : -0.1f + eye * 0.03f, simd_make_float3(0, 1, 0))));
			source_eyes[eye].columns[3] = destination_eyes[eye].columns[3] = simd_make_float4(eye ? 0.032f : -0.032f, 0.01f, -0.02f, 1);
			if (!rotated_eyes) {
				source_eyes[eye] = destination_eyes[eye] = matrix_identity_float4x4;
				source_eyes[eye].columns[3] = destination_eyes[eye].columns[3] = simd_make_float4(eye ? 0.032f : -0.032f, 0.01f, -0.02f, 1);
			}
			if (positional) {
				destination_eyes[eye].columns[3] += thin_occluder ? simd_make_float4(eye ? -0.006f : 0.006f, eye ? 0.002f : -0.002f, 0, 0) : simd_make_float4(eye ? -0.002f : 0.002f, -0.001f, eye ? 0.003f : -0.003f, 0);
			}
			source_projections[eye] = make_projection(1.2f + eye * 0.2f, 1.4f - eye * 0.1f, eye ? -0.1f : 0.05f, infinite_far, physical_depth_range ? 0.11f : 0.1f, physical_depth_range ? 4000 : 50);
			destination_projections[eye] = make_projection(1.3f - eye * 0.1f, 1.2f + eye * 0.1f, eye ? 0.08f : -0.04f, infinite_far, physical_depth_range ? 0.11f : 0.1f, physical_depth_range ? 4000 : 50);
			if (cap_ramp) {
				destination_eyes[eye] = source_eyes[eye];
				destination_eyes[eye].columns[3].x += eye ? -0.1f : 0.1f;
				source_projections[eye] = destination_projections[eye] = make_projection(1.2f, 1.2f, 0);
			}
			if (benchmark != NO_BENCHMARK) {
				destination_eyes[eye] = source_eyes[eye];
				if (positional) {
					auto displacement = benchmark == CAP_SKY || benchmark == SPARSE_SKY ? simd_make_float4(eye ? -0.1f : 0.1f, 0, 0, 0) : simd_make_float4(eye ? -0.0001002f : 0.0001002f, eye ? -0.0000525f : 0.0000525f, eye ? 0.0009448f : 0.0006638f, 0);
					destination_eyes[eye].columns[3] += displacement;
				}
				source_projections[eye] = destination_projections[eye] = make_projection(1.2f, 1.2f, 0);
			}
			auto comparison = visionos_scene_transfer_eye_mapping(source_eyes[eye], destination_eyes[eye], source_projections[eye], destination_projections[eye], parameters[eye]);
			REQUIRE(comparison.rejection == VisionOSEyeTransformComparison::NONE);
			CHECK(comparison.original_mismatch == (benchmark != BASELINE));
		}
		parameters[eye].source_viewport = simd_make_float4(0, 0, width, height);
		parameters[eye].destination_viewport = parameters[eye].source_viewport;
		parameters[eye].has_rate_map = use_vrs;
		parameters[eye].alpha_blend = mixed;
		parameters[eye].source_is_srgb = source_is_srgb;
		viewports[eye] = { 0, 0, double(width), double(height), 0, 1 };
		auto screen = MTL::Coordinate2D(width * 0.5f, height * 0.5f);
		auto physical = use_vrs ? source_map->mapScreenToPhysicalCoordinates(screen, eye) : screen;
		foreground_rectangles[eye] = simd_make_float4(std::floor(physical.x) - 1, std::floor(physical.y) - 12, std::floor(physical.x) + 2, std::floor(physical.y) + 12);
	}
	if (thin_occluder) {
		auto descriptor = NS::TransferPtr(MTL::RenderPipelineDescriptor::alloc()->init());
		auto depth_fragment = NS::TransferPtr(library->newFunction(NS::String::string("scene_fixture_depth", NS::UTF8StringEncoding)));
		descriptor->setVertexFunction(vertex.get());
		descriptor->setFragmentFunction(depth_fragment.get());
		descriptor->setInputPrimitiveTopology(MTL::PrimitiveTopologyClassTriangle);
		descriptor->setDepthAttachmentPixelFormat(MTL::PixelFormatDepth32Float_Stencil8);
		auto fill_pipeline = NS::TransferPtr(device->newRenderPipelineState(descriptor.get(), &error));
		REQUIRE_MESSAGE(fill_pipeline, (error ? error->localizedDescription()->utf8String() : "No source depth pipeline"));
		auto fill_pass = MTL::RenderPassDescriptor::renderPassDescriptor();
		fill_pass->depthAttachment()->setTexture(source_depth.get());
		fill_pass->depthAttachment()->setLoadAction(MTL::LoadActionClear);
		fill_pass->depthAttachment()->setClearDepth(0);
		fill_pass->depthAttachment()->setStoreAction(MTL::StoreActionStore);
		fill_pass->setRenderTargetArrayLength(2);
		fill_pass->setRenderTargetWidth(width);
		fill_pass->setRenderTargetHeight(height);
		if (use_vrs) {
			fill_pass->setRasterizationRateMap(source_map.get());
		}
		auto fill = command->renderCommandEncoder(fill_pass);
		REQUIRE(fill);
		fill->setRenderPipelineState(fill_pipeline.get());
		fill->setDepthStencilState(depth_state.get());
		fill->setViewports(viewports, 2);
		fill->setFragmentBytes(foreground_rectangles, sizeof(foreground_rectangles), 0);
		float background_depth = background ? 0 : 0.1f;
		fill->setFragmentBytes(&background_depth, sizeof(background_depth), 1);
		uint32_t ramp = cap_ramp;
		simd_float2 ramp_parameters[2]{};
		for (uint32_t eye = 0; eye < 2; eye++) {
			float reference_ndc = 2.0f * (width * 0.5f + 0.5f) / width - 1.0f;
			float scale = source_projections[eye].columns[3].z / (1.2f * (eye ? -0.1f : 0.1f));
			ramp_parameters[eye] = simd_make_float2(scale * 2.0f / width, -scale * (1.0f + reference_ndc) - source_projections[eye].columns[2].z);
		}
		fill->setFragmentBytes(&ramp, sizeof(ramp), 2);
		fill->setFragmentBytes(ramp_parameters, sizeof(ramp_parameters), 3);
		fill->drawPrimitives(MTL::PrimitiveTypeTriangle, NS::UInteger(0), NS::UInteger(3), NS::UInteger(2));
		fill->endEncoding();
	}
	simd_float4 physical_bounds[2];
	for (uint32_t eye = 0; eye < 2; eye++) {
		auto high = MTL::Coordinate2D(width, height);
		if (use_vrs) {
			high = source_map->mapScreenToPhysicalCoordinates(high, eye);
		}
		physical_bounds[eye] = visionos_scene_physical_bounds(simd_make_float2(0, 0), simd_make_float2(high.x, high.y), source_size.width, source_size.height);
		parameters[eye].source_physical_bounds = physical_bounds[eye];
	}
	pyramid.encode(command, source_depth.get(), physical_bounds);
	Vector<simd_float2> sample_points[2];
	for (uint32_t eye = 0; eye < 2; eye++) {
		for (uint32_t point = 0; point < 9; point++) {
			sample_points[eye].push_back(simd_make_float2(width * (0.25f + 0.25f * (point % 3)), height * (0.25f + 0.25f * (point / 3))));
		}
		if (thin_occluder && !cap_ramp) {
			for (float depth : { 0.8f, 0.1f }) {
				for (int offset = -8; offset <= 8; offset++) {
					auto physical = MTL::Coordinate2D(foreground_rectangles[eye].x + 1.5f + offset, foreground_rectangles[eye].y + 12.5f);
					auto logical = use_vrs ? source_map->mapPhysicalToScreenCoordinates(physical, eye) : physical;
					auto source_clip = simd_make_float4(logical.x / width * 2 - 1, 1 - logical.y / height * 2, depth, 1);
					auto destination_clip = simd_mul(parameters[eye].source_to_destination, source_clip);
					sample_points[eye].push_back(simd_make_float2((destination_clip.x / destination_clip.w * 0.5f + 0.5f) * width, (0.5f - destination_clip.y / destination_clip.w * 0.5f) * height));
				}
			}
		}
	}
	const uint32_t sample_count = sample_points[0].size();
	REQUIRE(sample_points[1].size() == sample_count);
	auto pass = MTL::RenderPassDescriptor::renderPassDescriptor();
	pass->colorAttachments()->object(0)->setTexture(destination_color.get());
	pass->colorAttachments()->object(0)->setLoadAction(MTL::LoadActionClear);
	auto loading = visionos_scene_loading_color(mixed, 0);
	pass->colorAttachments()->object(0)->setClearColor(MTL::ClearColor::Make(loading.x, loading.y, loading.z, loading.w));
	pass->colorAttachments()->object(0)->setStoreAction(MTL::StoreActionStore);
	pass->depthAttachment()->setTexture(destination_depth.get());
	pass->depthAttachment()->setLoadAction(MTL::LoadActionClear);
	pass->depthAttachment()->setStoreAction(MTL::StoreActionStore);
	pass->setRenderTargetArrayLength(2);
	if (use_vrs) {
		pass->setRasterizationRateMap(destination_map.get());
	}
	pass->setRenderTargetWidth(width);
	pass->setRenderTargetHeight(height);
	auto encoder = command->renderCommandEncoder(pass);
	REQUIRE(encoder);
	encoder->setRenderPipelineState(pipeline.get());
	encoder->setDepthStencilState(depth_state.get());
	encoder->setViewports(viewports, 2);
	encoder->setFragmentBytes(parameters, sizeof(parameters), 0);
	encoder->setFragmentBuffer(rate_data.get(), 0, 1);
	encoder->setFragmentTexture(source_color.get(), 0);
	encoder->setFragmentTexture(source_depth.get(), 1);
	encoder->setFragmentTexture(pyramid.texture.get(), 2);
	encoder->drawPrimitives(MTL::PrimitiveTypeTriangle, NS::UInteger(0), NS::UInteger(3), NS::UInteger(2));
	encoder->endEncoding();
	auto samples = NS::TransferPtr(device->newBuffer(2 * sample_count * 512, MTL::ResourceStorageModeShared));
	REQUIRE(samples);
	auto blit = command->blitCommandEncoder();
	for (uint32_t eye = 0; eye < 2; eye++) {
		for (uint32_t point = 0; point < sample_count; point++) {
			auto screen = MTL::Coordinate2D(sample_points[eye][point].x, sample_points[eye][point].y);
			auto physical = use_vrs ? destination_map->mapScreenToPhysicalCoordinates(screen, eye) : screen;
			size_t offset = (eye * sample_count + point) * 512;
			blit->copyFromTexture(destination_color.get(), eye, 0, MTL::Origin(physical.x, physical.y, 0), MTL::Size(1, 1, 1), samples.get(), offset, 256, 256);
			blit->copyFromTexture(destination_depth.get(), eye, 0, MTL::Origin(physical.x, physical.y, 0), MTL::Size(1, 1, 1), samples.get(), offset + 256, 256, 256, MTL::BlitOptionDepthFromDepthStencil);
		}
	}
	blit->endEncoding();
	command->commit();
	command->waitUntilCompleted();
	REQUIRE_MESSAGE(command->status() == MTL::CommandBufferStatusCompleted, (command->error() ? command->error()->localizedDescription()->utf8String() : "Incomplete transfer"));
	const uint8_t *data = static_cast<const uint8_t *>(samples->contents());
	uint32_t opaque_samples = 0;
	uint32_t transparent_samples = 0;
	uint32_t foreground_samples[2] = {};
	uint32_t disoccluded_samples[2] = {};
	for (uint32_t eye = 0; eye < 2; eye++) {
		for (uint32_t point = 0; point < sample_count; point++) {
			CAPTURE(eye);
			CAPTURE(point);
			size_t offset = (eye * sample_count + point) * 512;
			if (cap_ramp) {
				if (point == 4) {
					for (uint32_t channel = 0; channel < 4; channel++) {
						CHECK(Math::half_to_float(decode_uint16(data + offset + channel * 2)) == 0);
					}
					CHECK(*reinterpret_cast<const float *>(data + offset + 256) == 0);
				}
				continue;
			}
			if (benchmark == SPARSE_SKY) {
				float alpha = Math::half_to_float(decode_uint16(data + offset + 6));
				CHECK((alpha == 0 || alpha == 1));
				float depth = *reinterpret_cast<const float *>(data + offset + 256);
				CHECK((depth >= 0 && depth <= 1));
				if (alpha == 0) {
					CHECK(depth == 0);
				}
				transparent_samples += alpha == 0;
				opaque_samples += alpha == 1;
				continue;
			}
			if (rotated_eyes || positional || benchmark != NO_BENCHMARK) {
				auto screen = MTL::Coordinate2D(sample_points[eye][point].x, sample_points[eye][point].y);
				auto physical = use_vrs ? destination_map->mapScreenToPhysicalCoordinates(screen, eye) : screen;
				auto center = MTL::Coordinate2D(std::floor(physical.x) + 0.5f, std::floor(physical.y) + 0.5f);
				auto logical = use_vrs ? destination_map->mapPhysicalToScreenCoordinates(center, eye) : center;
				auto view_point = simd_mul(simd_inverse(destination_projections[eye]), simd_make_float4(2 * logical.x / width - 1, 1 - 2 * logical.y / height, 0.5f, 1));
				auto head_direction = simd_mul(destination_eyes[eye], simd_make_float4(view_point.xyz, 0));
				auto source_direction = simd_mul(simd_inverse(source_eyes[eye]), head_direction);
				auto source_clip = simd_mul(source_projections[eye], source_direction);
				float sampled_depth = background ? 0 : (far_surface ? 0.000001f * (eye + 1) : (near_clip ? 0.98f : 0.25f + eye * 0.25f));
				bool disoccluded = false;
				if (!background) {
					auto origin = simd_mul(simd_inverse(source_eyes[eye]), destination_eyes[eye].columns[3]);
					auto intersect_plane = [&](float p_depth) {
						auto plane = simd_mul(simd_inverse(source_projections[eye]), simd_make_float4(0, 0, p_depth, 1));
						float distance = (plane.z / plane.w - origin.z) / source_direction.z;
						return simd_mul(source_projections[eye], origin + source_direction * distance);
					};
					if (thin_occluder) {
						auto foreground = intersect_plane(0.8f);
						auto foreground_screen = MTL::Coordinate2D((foreground.x / foreground.w * 0.5f + 0.5f) * width, (0.5f - foreground.y / foreground.w * 0.5f) * height);
						auto foreground_pixel = use_vrs ? source_map->mapScreenToPhysicalCoordinates(foreground_screen, eye) : foreground_screen;
						auto rectangle = foreground_rectangles[eye];
						bool in_foreground = foreground_pixel.x >= rectangle.x && foreground_pixel.x < rectangle.z && foreground_pixel.y >= rectangle.y && foreground_pixel.y < rectangle.w;
						sampled_depth = in_foreground ? 0.8f : 0.1f;
						source_clip = intersect_plane(sampled_depth);
						if (in_foreground) {
							foreground_samples[eye]++;
						} else {
							// Analytic two-plane oracle: a ray passing through the
							// old occluder's hidden volume cannot recover that space.
							auto behind = intersect_plane(0.1f);
							auto behind_screen = simd_make_float2((behind.x / behind.w * 0.5f + 0.5f) * width, (0.5f - behind.y / behind.w * 0.5f) * height);
							auto low = MTL::Coordinate2D(rectangle.x, rectangle.y);
							auto high = MTL::Coordinate2D(rectangle.z, rectangle.w);
							if (use_vrs) {
								low = source_map->mapPhysicalToScreenCoordinates(low, eye);
								high = source_map->mapPhysicalToScreenCoordinates(high, eye);
							}
							simd_float2 start = simd_make_float2(foreground_screen.x, foreground_screen.y);
							simd_float2 delta = behind_screen - start;
							float entry = 0, exit = 1;
							for (uint32_t axis = 0; axis < 2; axis++) {
								float a = axis ? low.y : low.x;
								float b = axis ? high.y : high.x;
								if (delta[axis] == 0) {
									if (start[axis] < a || start[axis] >= b) {
										entry = 2;
									}
								} else {
									float t0 = (a - start[axis]) / delta[axis];
									float t1 = (b - start[axis]) / delta[axis];
									entry = MAX(entry, MIN(t0, t1));
									exit = MIN(exit, MAX(t0, t1));
								}
							}
							disoccluded = entry < exit;
							disoccluded_samples[eye] += disoccluded;
						}
					} else {
						source_clip = intersect_plane(sampled_depth);
					}
				}
				auto source_ndc = source_clip.xyz / source_clip.w;
				float expected_x = source_ndc.x * 0.5f + 0.5f;
				float expected_y = 0.5f - source_ndc.y * 0.5f;
				auto head_point = simd_mul(source_eyes[eye], simd_mul(simd_inverse(source_projections[eye]), simd_make_float4(source_ndc.x, source_ndc.y, sampled_depth, 1)));
				auto destination_clip = simd_mul(destination_projections[eye], simd_mul(simd_inverse(destination_eyes[eye]), head_point));
				bool visible = !disoccluded && source_clip.w > 0 && expected_x >= 0 && expected_x <= 1 && expected_y >= 0 && expected_y <= 1 &&
						(background || (destination_clip.w > 0 && destination_clip.z >= 0 && destination_clip.z <= destination_clip.w));
				visible &= !mixed || (!background && source_alpha > 0 && !(transparent_foreground && sampled_depth == 0.8f));
				if (visible) {
					opaque_samples++;
					Color expected(expected_x, expected_y, float(eye), source_alpha);
					if (mixed) {
						expected = Color(
										   0.82246197f * expected_x + 0.17753803f * expected_y,
										   0.03319420f * expected_x + 0.96680580f * expected_y,
										   0.01708263f * expected_x + 0.07239744f * expected_y + 0.91051993f * eye,
										   1) *
								source_alpha;
					}
					for (uint32_t channel = 0; channel < 3; channel++) {
						float actual = Math::half_to_float(decode_uint16(data + offset + channel * 2));
						CHECK(actual == doctest::Approx(expected[channel]).epsilon(0.025));
						if (mixed && source_alpha < 1) {
							float passthrough = 0.2f + channel * 0.1f;
							CHECK(actual + passthrough * (1 - source_alpha) ==
									doctest::Approx(expected[channel] + passthrough * (1 - source_alpha)).epsilon(0.025));
						}
					}
					CHECK(Math::half_to_float(decode_uint16(data + offset + 6)) == source_alpha);
					CHECK(*reinterpret_cast<const float *>(data + offset + 256) == doctest::Approx(background ? 0 : destination_clip.z / destination_clip.w).epsilon(0.005));
				} else {
					transparent_samples++;
					for (uint32_t channel = 0; channel < 4; channel++) {
						CHECK(Math::half_to_float(decode_uint16(data + offset + channel * 2)) == 0);
					}
					CHECK(*reinterpret_cast<const float *>(data + offset + 256) == 0);
				}
				continue;
			}
			CHECK(Math::half_to_float(decode_uint16(data + offset)) == doctest::Approx(0.3f + 0.25f * (point % 3)).epsilon(0.025));
			CHECK(Math::half_to_float(decode_uint16(data + offset + 2)) == doctest::Approx(0.25f + 0.25f * (point / 3)).epsilon(0.025));
			CHECK(Math::half_to_float(decode_uint16(data + offset + 4)) == float(eye));
			CHECK(Math::half_to_float(decode_uint16(data + offset + 6)) == 1);
			CHECK(*reinterpret_cast<const float *>(data + offset + 256) == doctest::Approx((0.25f + eye * 0.25f + 0.2f) / 2));
		}
	}
	if ((rotated_eyes || positional) && !cap_ramp) {
		if (mixed && (source_alpha == 0 || background)) {
			CHECK(opaque_samples == 0);
			CHECK(transparent_samples > 0);
		} else {
			CHECK(opaque_samples > 0);
		}
		if (near_clip || outside_frustum) {
			CHECK(transparent_samples > 0);
		}
	}
	if (thin_occluder && !cap_ramp && benchmark != SPARSE_SKY) {
		for (uint32_t eye = 0; eye < 2; eye++) {
			CHECK(foreground_samples[eye] > 0);
			CHECK(disoccluded_samples[eye] > 0);
		}
	}
	if (benchmark == SPARSE_SKY) {
		CHECK(transparent_samples > 0);
	}
	if (cap_ramp) {
		// Changing only the iteration limit must recover the known sky on the
		// same ray, proving the production result came from bounded exhaustion.
		String reference_shader = shader.replace("visit < 64", "visit < 4096");
		REQUIRE(reference_shader != shader);
		auto reference_library = NS::TransferPtr(device->newLibrary(NS::String::string(reference_shader.utf8().get_data(), NS::UTF8StringEncoding), options.get(), &error));
		REQUIRE_MESSAGE(reference_library, (error ? error->localizedDescription()->utf8String() : "No unbounded reference library"));
		auto reference_fragment = NS::TransferPtr(reference_library->newFunction(NS::String::string("scene_transfer_fragment", NS::UTF8StringEncoding)));
		pipeline_descriptor->setFragmentFunction(reference_fragment.get());
		auto reference_pipeline = NS::TransferPtr(device->newRenderPipelineState(pipeline_descriptor.get(), &error));
		REQUIRE(reference_pipeline);
		auto reference = queue->commandBuffer();
		auto draw = reference->renderCommandEncoder(pass);
		REQUIRE(draw);
		draw->setRenderPipelineState(reference_pipeline.get());
		draw->setDepthStencilState(depth_state.get());
		draw->setViewports(viewports, 2);
		draw->setFragmentBytes(parameters, sizeof(parameters), 0);
		draw->setFragmentBuffer(rate_data.get(), 0, 1);
		draw->setFragmentTexture(source_color.get(), 0);
		draw->setFragmentTexture(source_depth.get(), 1);
		draw->setFragmentTexture(pyramid.texture.get(), 2);
		draw->drawPrimitives(MTL::PrimitiveTypeTriangle, NS::UInteger(0), NS::UInteger(3), NS::UInteger(2));
		draw->endEncoding();
		auto copy = reference->blitCommandEncoder();
		for (uint32_t eye = 0; eye < 2; eye++) {
			copy->copyFromTexture(destination_color.get(), eye, 0, MTL::Origin(width / 2, height / 2, 0), MTL::Size(1, 1, 1), samples.get(), eye * 512, 256, 256);
		}
		copy->endEncoding();
		reference->commit();
		reference->waitUntilCompleted();
		REQUIRE(reference->status() == MTL::CommandBufferStatusCompleted);
		data = static_cast<const uint8_t *>(samples->contents());
		for (uint32_t eye = 0; eye < 2; eye++) {
			CHECK(Math::half_to_float(decode_uint16(data + eye * 512 + 6)) == 1);
		}
	}
	if (benchmark != NO_BENCHMARK) {
		double first_gpu_ms = (command->GPUEndTime() - command->GPUStartTime()) * 1000.0;
		Vector<double> timings;
		Vector<double> construction;
		for (uint32_t frame = 0; frame < 20; frame++) {
			auto build = queue->commandBuffer();
			pyramid.encode(build, source_depth.get(), physical_bounds);
			build->commit();
			build->waitUntilCompleted();
			REQUIRE(build->status() == MTL::CommandBufferStatusCompleted);
			construction.push_back((build->GPUEndTime() - build->GPUStartTime()) * 1000.0);
			auto next = queue->commandBuffer();
			pyramid.encode(next, source_depth.get(), physical_bounds);
			auto draw = next->renderCommandEncoder(pass);
			REQUIRE(draw);
			draw->setRenderPipelineState(pipeline.get());
			draw->setDepthStencilState(depth_state.get());
			draw->setViewports(viewports, 2);
			draw->setFragmentBytes(parameters, sizeof(parameters), 0);
			draw->setFragmentBuffer(rate_data.get(), 0, 1);
			draw->setFragmentTexture(source_color.get(), 0);
			draw->setFragmentTexture(source_depth.get(), 1);
			draw->setFragmentTexture(pyramid.texture.get(), 2);
			draw->drawPrimitives(MTL::PrimitiveTypeTriangle, NS::UInteger(0), NS::UInteger(3), NS::UInteger(2));
			draw->endEncoding();
			next->commit();
			next->waitUntilCompleted();
			REQUIRE(next->status() == MTL::CommandBufferStatusCompleted);
			double elapsed = (next->GPUEndTime() - next->GPUStartTime()) * 1000.0;
			REQUIRE(elapsed > 0);
			timings.push_back(elapsed);
		}
		timings.sort();
		construction.sort();
		if (benchmark == SPARSE_SKY) {
			size_t depth_stride = (source_size.width * 4 + 255) & ~size_t(255);
			size_t depth_layer_bytes = depth_stride * source_size.height;
			auto source_samples = NS::TransferPtr(device->newBuffer(depth_layer_bytes * 2, MTL::ResourceStorageModeShared));
			auto tile_samples = NS::TransferPtr(device->newBuffer(pyramid.texture->height() * 256 * 2, MTL::ResourceStorageModeShared));
			REQUIRE(source_samples);
			REQUIRE(tile_samples);
			auto read = queue->commandBuffer();
			auto copy = read->blitCommandEncoder();
			for (uint32_t eye = 0; eye < 2; eye++) {
				copy->copyFromTexture(source_depth.get(), eye, 0, MTL::Origin(0, 0, 0), source_size, source_samples.get(), eye * depth_layer_bytes, depth_stride, depth_layer_bytes, MTL::BlitOptionDepthFromDepthStencil);
				copy->copyFromTexture(pyramid.texture.get(), eye, 0, MTL::Origin(0, 0, 0), MTL::Size(pyramid.texture->width(), pyramid.texture->height(), 1), tile_samples.get(), eye * pyramid.texture->height() * 256, 256, pyramid.texture->height() * 256);
			}
			copy->endEncoding();
			read->commit();
			read->waitUntilCompleted();
			REQUIRE(read->status() == MTL::CommandBufferStatusCompleted);
			for (uint32_t eye = 0; eye < 2; eye++) {
				uint64_t positive = 0, nonzero_tiles = 0;
				uint32_t min_x = source_size.width, min_y = source_size.height, max_x = 0, max_y = 0;
				auto data = static_cast<const uint8_t *>(source_samples->contents()) + eye * depth_layer_bytes;
				for (uint32_t y = 0; y < source_size.height; y++) {
					for (uint32_t x = 0; x < source_size.width; x++) {
						if (*reinterpret_cast<const float *>(data + y * depth_stride + x * 4) > 0) {
							positive++;
							min_x = MIN(min_x, x);
							min_y = MIN(min_y, y);
							max_x = MAX(max_x, x);
							max_y = MAX(max_y, y);
						}
					}
				}
				data = static_cast<const uint8_t *>(tile_samples->contents()) + eye * pyramid.texture->height() * 256;
				for (uint32_t y = 0; y < pyramid.texture->height(); y++) {
					for (uint32_t x = 0; x < pyramid.texture->width(); x++) {
						nonzero_tiles += *reinterpret_cast<const float *>(data + y * 256 + x * 4) > 0;
					}
				}
				CHECK(positive == 72);
				CHECK(min_x == uint32_t(foreground_rectangles[eye].x));
				CHECK(min_y == uint32_t(foreground_rectangles[eye].y));
				CHECK(max_x + 1 == uint32_t(foreground_rectangles[eye].z));
				CHECK(max_y + 1 == uint32_t(foreground_rectangles[eye].w));
				CHECK(nonzero_tiles == 2);
			}
		}
		uint64_t interior_pixels = 0, interior_holes = 0;
		{
			size_t stride = (destination_size.width * 8 + 255) & ~size_t(255);
			size_t layer_bytes = stride * destination_size.height;
			auto coverage = NS::TransferPtr(device->newBuffer(layer_bytes * 2, MTL::ResourceStorageModeShared));
			REQUIRE(coverage);
			auto readback = queue->commandBuffer();
			auto copy = readback->blitCommandEncoder();
			for (uint32_t eye = 0; eye < 2; eye++) {
				copy->copyFromTexture(destination_color.get(), eye, 0, MTL::Origin(0, 0, 0), destination_size, coverage.get(), eye * layer_bytes, stride, layer_bytes);
			}
			copy->endEncoding();
			readback->commit();
			readback->waitUntilCompleted();
			REQUIRE(readback->status() == MTL::CommandBufferStatusCompleted);
			auto bytes = static_cast<const uint8_t *>(coverage->contents());
			for (uint32_t eye = 0; eye < 2; eye++) {
				auto low = destination_map->mapScreenToPhysicalCoordinates(MTL::Coordinate2D(width * 0.1f, height * 0.1f), eye);
				auto high = destination_map->mapScreenToPhysicalCoordinates(MTL::Coordinate2D(width * 0.9f, height * 0.9f), eye);
				for (uint32_t y = uint32_t(low.y) + 1; y < uint32_t(high.y); y++) {
					if (benchmark == SPARSE_SKY) {
						auto logical = destination_map->mapPhysicalToScreenCoordinates(MTL::Coordinate2D(0, y + 0.5f), eye);
						if (logical.y > height * 0.45f && logical.y < height * 0.55f) {
							continue;
						}
					}
					for (uint32_t x = uint32_t(low.x) + 1; x < uint32_t(high.x); x++) {
						interior_pixels++;
						interior_holes += Math::half_to_float(decode_uint16(bytes + eye * layer_bytes + y * stride + x * 8 + 6)) != source_alpha;
					}
				}
			}
			CHECK(interior_pixels > 1000000);
			CHECK(interior_holes == 0);
		}
		print_line(vformat("visionOS transfer benchmark {\"case\":%d,\"device\":\"%s\",\"source_physical\":[%d,%d],\"destination_physical\":[%d,%d],\"logical\":[%d,%d],\"stereo\":true,\"native_vrs\":true,\"first_command_ms\":%f,\"includes_hierarchy_construction\":true,\"median_ms\":%f,\"p95_ms\":%f,\"max_ms\":%f,\"construction_p95_ms\":%f,\"hierarchy_allocated_bytes_per_output\":%d,\"interior_pixels\":%d,\"interior_holes\":%d,\"excluded_occluder_band\":%s}",
				benchmark, device->name()->utf8String(), source_size.width, source_size.height, destination_size.width, destination_size.height, width, height, first_gpu_ms, timings[10], timings[18], timings[19], construction[18], pyramid.texture->allocatedSize(), interior_pixels, interior_holes, benchmark == SPARSE_SKY ? "true" : "false"));
	}
}

} // namespace TestVisionOSSceneTransfer

#endif
