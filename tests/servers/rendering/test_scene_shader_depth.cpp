/**************************************************************************/
/*  test_scene_shader_depth.cpp                                           */
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

#include "servers/rendering/shader_language.h"
#include "servers/rendering/shader_types.h"
#include "tests/test_macros.h"

#ifdef RD_ENABLED
#include "servers/rendering/renderer_rd/forward_clustered/scene_shader_forward_clustered.h"
#include "servers/rendering/renderer_rd/forward_mobile/scene_shader_forward_mobile.h"
#endif
#ifdef GLES3_ENABLED
#include "drivers/gles3/storage/material_storage.h"
#endif

TEST_FORCE_LINK(test_scene_shader_depth)

namespace TestSceneShaderDepth {

TEST_CASE("[SceneTree][DepthTest] Unconditional depth comparison is explicit and mutually exclusive") {
	ShaderLanguage::ShaderCompileInfo info;
	info.functions = ShaderTypes::get_singleton()->get_functions(RSE::SHADER_SPATIAL);
	info.render_modes = ShaderTypes::get_singleton()->get_modes(RSE::SHADER_SPATIAL);
	info.stencil_modes = ShaderTypes::get_singleton()->get_stencil_modes(RSE::SHADER_SPATIAL);
	info.shader_types = ShaderTypes::get_singleton()->get_types();
	for (const String depth_test : { "default", "inverted", "disabled", "always" }) {
		for (const String depth_draw : { "opaque", "always", "never" }) {
			ShaderLanguage language;
			CHECK(language.compile("shader_type spatial; render_mode depth_test_" + depth_test + ", depth_draw_" + depth_draw + "; void fragment() { ALPHA = 0.25; }", info) == OK);
		}
	}
	for (const String other : { "default", "inverted", "disabled", "always" }) {
		for (bool reverse : { false, true }) {
			ShaderLanguage language;
			String modes = reverse ? "depth_test_" + other + ", depth_test_always" : "depth_test_always, depth_test_" + other;
			CHECK(language.compile("shader_type spatial; render_mode " + modes + ";", info) == ERR_PARSE_ERROR);
		}
	}
}

#ifdef RD_ENABLED
template <typename ShaderData>
void check_rd_depth_states() {
	for (auto comparison : { ShaderData::DEPTH_TEST_ENABLED, ShaderData::DEPTH_TEST_ENABLED_INVERTED, ShaderData::DEPTH_TEST_DISABLED, ShaderData::DEPTH_TEST_ALWAYS }) {
		// This production policy routes nondefault comparisons to the alpha list,
		// excluding the ordinary prepass and its equal-depth color optimization.
		CHECK(ShaderData::depth_test_supports_prepass(comparison) == (comparison == ShaderData::DEPTH_TEST_ENABLED));
		for (auto draw : { ShaderData::DEPTH_DRAW_OPAQUE, ShaderData::DEPTH_DRAW_ALWAYS, ShaderData::DEPTH_DRAW_DISABLED }) {
			const RD::PipelineDepthStencilState state = ShaderData::make_depth_stencil_state(comparison, draw);
			CHECK(state.enable_depth_test == (comparison != ShaderData::DEPTH_TEST_DISABLED));
			CHECK(state.enable_depth_write == (comparison != ShaderData::DEPTH_TEST_DISABLED && draw != ShaderData::DEPTH_DRAW_DISABLED));
			CHECK_FALSE(state.enable_stencil);
			if (comparison != ShaderData::DEPTH_TEST_DISABLED) {
				RD::CompareOperator expected = RD::COMPARE_OP_GREATER_OR_EQUAL;
				if (comparison == ShaderData::DEPTH_TEST_ENABLED_INVERTED) {
					expected = RD::COMPARE_OP_LESS;
				} else if (comparison == ShaderData::DEPTH_TEST_ALWAYS) {
					expected = RD::COMPARE_OP_ALWAYS;
				}
				CHECK(state.depth_compare_operator == expected);
			}
		}
	}
}

TEST_CASE("[SceneTree][DepthTest] Mobile comparison and depth-write policies remain independent") {
	check_rd_depth_states<RendererSceneRenderImplementation::SceneShaderForwardMobile::ShaderData>();
}

TEST_CASE("[SceneTree][DepthTest] Forward Plus comparison and depth-write policies remain independent") {
	check_rd_depth_states<RendererSceneRenderImplementation::SceneShaderForwardClustered::ShaderData>();
}
#endif

#ifdef GLES3_ENABLED
TEST_CASE("[SceneTree][DepthTest] Compatibility uses enabled unconditional comparison without entering the prepass") {
	using ShaderData = GLES3::SceneShaderData;
	CHECK(ShaderData::get_depth_compare_operator(ShaderData::DEPTH_TEST_ALWAYS) == GL_ALWAYS);
	CHECK(ShaderData::get_depth_compare_operator(ShaderData::DEPTH_TEST_ENABLED) == GL_GEQUAL);
	CHECK(ShaderData::get_depth_compare_operator(ShaderData::DEPTH_TEST_ENABLED_INVERTED) == GL_LESS);
	CHECK(ShaderData::get_depth_compare_operator(ShaderData::DEPTH_TEST_DISABLED) == GL_GEQUAL);
	for (auto comparison : { ShaderData::DEPTH_TEST_ENABLED, ShaderData::DEPTH_TEST_ENABLED_INVERTED, ShaderData::DEPTH_TEST_DISABLED, ShaderData::DEPTH_TEST_ALWAYS }) {
		CHECK(ShaderData::depth_test_supports_prepass(comparison) == (comparison == ShaderData::DEPTH_TEST_ENABLED));
	}
}
#endif

} // namespace TestSceneShaderDepth
