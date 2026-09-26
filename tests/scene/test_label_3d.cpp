/**************************************************************************/
/*  test_label_3d.cpp                                                     */
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

#include "core/io/dir_access.h"
#include "core/io/resource_loader.h"
#include "core/io/resource_saver.h"
#include "core/object/message_queue.h"
#include "scene/3d/label_3d.h"
#include "scene/resources/packed_scene.h"
#include "servers/rendering/rendering_server.h"
#include "tests/test_macros.h"
#include "tests/test_utils.h"

TEST_FORCE_LINK(test_label_3d)

#ifndef _3D_DISABLED

namespace TestLabel3D {

static String material_code(const Ref<BaseMaterial3D> &p_material) {
	return RS::get_singleton()->shader_get_code(p_material->get_shader_rid());
}

class DepthOffsetLabel : public Label3D {
public:
	using Label3D::_get_glyph_depth_offset;
	using Label3D::_get_glyph_render_priority;
};

TEST_CASE("[SceneTree][Label3D] Effective foreground comparison preserves render priorities for every alpha-cut mode") {
	DepthOffsetLabel *label = memnew(DepthOffsetLabel);
	for (auto alpha_cut : { Label3D::ALPHA_CUT_DISABLED, Label3D::ALPHA_CUT_DISCARD, Label3D::ALPHA_CUT_OPAQUE_PREPASS, Label3D::ALPHA_CUT_HASH }) {
		label->set_alpha_cut_mode(alpha_cut);
		for (bool always : { false, true }) {
			label->set_depth_test_always(always);
			for (bool no_depth : { false, true }) {
				label->set_draw_flag(Label3D::FLAG_DISABLE_DEPTH_TEST, no_depth);
				for (bool write_depth : { false, true }) {
					label->set_depth_draw_always(write_depth);
					for (int priority : { -128, -1, 0, 16, 127 }) {
						const bool uses_priority = alpha_cut == Label3D::ALPHA_CUT_DISABLED || (always && !no_depth);
						CHECK(label->_get_glyph_render_priority(priority) == (uses_priority ? priority : 0));
					}
				}
			}
		}
	}
	memdelete(label);
}

TEST_CASE("[SceneTree][Label3D] Glyph depth priorities preserve signed pixel offsets only for opted-in blending") {
	DepthOffsetLabel *label = memnew(DepthOffsetLabel);
	for (real_t pixel_size : { real_t(0.0005), real_t(0.005), real_t(0.02) }) {
		label->set_pixel_size(pixel_size);
		for (int priority : { -128, -1, 0, 1, 127 }) {
			label->set_depth_draw_always(false);
			CHECK(label->_get_glyph_depth_offset(priority) == 0.0);
			label->set_depth_draw_always(true);
			for (auto billboard : { BaseMaterial3D::BILLBOARD_DISABLED, BaseMaterial3D::BILLBOARD_ENABLED, BaseMaterial3D::BILLBOARD_FIXED_Y }) {
				label->set_billboard_mode(billboard);
				for (bool double_sided : { false, true }) {
					label->set_draw_flag(Label3D::FLAG_DOUBLE_SIDED, double_sided);
					for (bool fixed_size : { false, true }) {
						label->set_draw_flag(Label3D::FLAG_FIXED_SIZE, fixed_size);
						CHECK(label->_get_glyph_depth_offset(priority) == doctest::Approx(priority * pixel_size));
					}
				}
			}
		}
	}
	for (auto mode : { Label3D::ALPHA_CUT_DISCARD, Label3D::ALPHA_CUT_OPAQUE_PREPASS, Label3D::ALPHA_CUT_HASH }) {
		label->set_alpha_cut_mode(mode);
		CHECK(label->_get_glyph_depth_offset(-1) == 0.0);
		CHECK(label->_get_glyph_depth_offset(1) == 0.0);
	}
	label->set_alpha_cut_mode(Label3D::ALPHA_CUT_DISABLED);
	CHECK(label->_get_glyph_depth_offset(label->get_outline_render_priority()) < label->_get_glyph_depth_offset(label->get_render_priority()));
	memdelete(label);
}

TEST_CASE("[SceneTree][Label3D] Depth-writing text is opt-in and survives scene serialization") {
	Label3D *label = memnew(Label3D);
	CHECK_FALSE(label->is_depth_draw_always_enabled());
	CHECK_FALSE(bool(label->get("depth_draw_always")));
	CHECK_FALSE(label->is_depth_test_always_enabled());
	CHECK_FALSE(bool(label->get("depth_test_always")));
	label->set("depth_draw_always", true);
	label->set("depth_test_always", true);
	CHECK(label->is_depth_draw_always_enabled());
	CHECK(label->get_alpha_cut_mode() == Label3D::ALPHA_CUT_DISABLED);

	Ref<PackedScene> scene;
	scene.instantiate();
	REQUIRE(scene->pack(label) == OK);
	Node *instance = scene->instantiate();
	Label3D *restored = Object::cast_to<Label3D>(instance);
	REQUIRE(restored);
	CHECK(restored->is_depth_draw_always_enabled());
	CHECK(restored->is_depth_test_always_enabled());
	CHECK_FALSE(restored->get_draw_flag(Label3D::FLAG_DISABLE_DEPTH_TEST));
	restored->set_depth_test_always(false);
	CHECK_FALSE(bool(restored->get("depth_test_always")));
	CHECK(label->is_depth_test_always_enabled());
	restored->set_depth_draw_always(false);
	CHECK_FALSE(bool(restored->get("depth_draw_always")));
	CHECK(label->is_depth_draw_always_enabled());
	memdelete(instance);
	memdelete(label);
}

TEST_CASE("[SceneTree][Label3D] Depth-writing glyph variants do not contaminate shared material caches") {
	for (bool msdf : { false, true }) {
		for (bool billboard : { false, true }) {
			RID original_shader, depth_shader, repeated_shader;
			auto material = [&](bool p_depth, RID &r_shader) -> Ref<BaseMaterial3D> {
				return BaseMaterial3D::get_material_for_2d(false, BaseMaterial3D::TRANSPARENCY_ALPHA, true,
						billboard, false, msdf, false, false, BaseMaterial3D::TEXTURE_FILTER_LINEAR_WITH_MIPMAPS,
						BaseMaterial3D::ALPHA_ANTIALIASING_OFF, false, &r_shader, p_depth);
			};
			Ref<BaseMaterial3D> original = material(false, original_shader);
			Ref<BaseMaterial3D> depth = material(true, depth_shader);
			REQUIRE(original.is_valid());
			REQUIRE(depth.is_valid());
			CHECK(original != depth);
			CHECK(original_shader.is_valid());
			CHECK(depth_shader.is_valid());
			CHECK(original_shader != depth_shader);
			CHECK(original->get_depth_draw_mode() == BaseMaterial3D::DEPTH_DRAW_OPAQUE_ONLY);
			CHECK(depth->get_depth_draw_mode() == BaseMaterial3D::DEPTH_DRAW_ALWAYS);
			CHECK(depth->get_transparency() == BaseMaterial3D::TRANSPARENCY_ALPHA);
			CHECK(depth->get_flag(BaseMaterial3D::FLAG_ALBEDO_TEXTURE_MSDF) == msdf);
			CHECK(material(false, repeated_shader) == original);
			CHECK(repeated_shader == original_shader);
			CHECK(material(true, repeated_shader) == depth);
			CHECK(repeated_shader == depth_shader);

			for (RID shader : { original_shader, depth_shader }) {
				List<PropertyInfo> parameters;
				RS::get_singleton()->get_shader_parameter_list(shader, &parameters);
				bool has_depth_offset = false;
				for (const PropertyInfo &parameter : parameters) {
					has_depth_offset |= parameter.name == "glyph_depth_offset";
				}
				CHECK(has_depth_offset == (shader == depth_shader));
			}

			// The inner shader cache must distinguish exact-zero discard from
			// an ordinary depth-writing alpha material with the same public flags.
			Ref<BaseMaterial3D> ordinary = original->duplicate();
			REQUIRE(ordinary.is_valid());
			ordinary->set_depth_draw_mode(BaseMaterial3D::DEPTH_DRAW_ALWAYS);
			CHECK(ordinary->get_shader_rid() != depth_shader);
			CHECK(original->get_shader_rid() == original_shader);
		}
	}
}

TEST_CASE("[SceneTree][Label3D] Foreground glyph caches isolate comparison writing and legacy disable flags") {
	for (bool msdf : { false, true }) {
		for (bool billboard : { false, true }) {
			for (bool fixed_size : { false, true }) {
				for (bool no_depth : { false, true }) {
					for (bool write_depth : { false, true }) {
						RID original_shader;
						Ref<BaseMaterial3D> original = BaseMaterial3D::get_material_for_2d(false, BaseMaterial3D::TRANSPARENCY_ALPHA, true, billboard, false, msdf, no_depth, fixed_size, BaseMaterial3D::TEXTURE_FILTER_LINEAR_WITH_MIPMAPS, BaseMaterial3D::ALPHA_ANTIALIASING_OFF, false, &original_shader, write_depth);
						const String original_code = material_code(original);
						RID foreground_shader;
						Ref<BaseMaterial3D> foreground = BaseMaterial3D::get_material_for_2d(false, BaseMaterial3D::TRANSPARENCY_ALPHA, true, billboard, false, msdf, no_depth, fixed_size, BaseMaterial3D::TEXTURE_FILTER_LINEAR_WITH_MIPMAPS, BaseMaterial3D::ALPHA_ANTIALIASING_OFF, false, &foreground_shader, write_depth, true);
						const String code = material_code(foreground);
						CHECK(original != foreground);
						CHECK(original_shader != foreground_shader);
						CHECK(foreground->get_depth_test() == BaseMaterial3D::DEPTH_TEST_ALWAYS);
						CHECK(code.contains("depth_test_always") == !no_depth);
						CHECK(code.contains("depth_test_disabled") == no_depth);
						CHECK(code.contains("depth_draw_always") == write_depth);
						CHECK(code.contains("if (ALPHA == 0.0)") == write_depth);
						CHECK(code.contains("glyph_depth_offset_view") == write_depth);
						CHECK(code.contains("ALPHA_SCISSOR_THRESHOLD") == false);
						CHECK(code.replace(", depth_test_always", "") == original_code);
						CHECK(material_code(original) == original_code);
						RID reused_shader;
						CHECK(BaseMaterial3D::get_material_for_2d(false, BaseMaterial3D::TRANSPARENCY_ALPHA, true, billboard, false, msdf, no_depth, fixed_size, BaseMaterial3D::TEXTURE_FILTER_LINEAR_WITH_MIPMAPS, BaseMaterial3D::ALPHA_ANTIALIASING_OFF, false, &reused_shader, write_depth, true) == foreground);
						CHECK(reused_shader == foreground_shader);
					}
				}
			}
		}
	}
}

TEST_CASE("[SceneTree][Label3D] Foreground comparison toggles rebuild only that label's generated surfaces") {
	Label3D *label = memnew(Label3D);
	Label3D *untouched = memnew(Label3D);
	label->set_text("Foreground");
	untouched->set_text("Unchanged");
	label->set_depth_draw_always(true);
	MessageQueue::get_singleton()->flush();
	REQUIRE(RS::get_singleton()->mesh_get_surface_count(label->get_base()) > 0);
	REQUIRE(RS::get_singleton()->mesh_get_surface_count(untouched->get_base()) > 0);
	const RID untouched_material = RS::get_singleton()->mesh_surface_get_material(untouched->get_base(), 0);
	RID previous_material = RS::get_singleton()->mesh_surface_get_material(label->get_base(), 0);
	for (bool enabled : { true, false, true }) {
		label->set("depth_test_always", enabled);
		MessageQueue::get_singleton()->flush();
		CHECK(label->is_depth_test_always_enabled() == enabled);
		const RID updated_material = RS::get_singleton()->mesh_surface_get_material(label->get_base(), 0);
		CHECK(updated_material != previous_material);
		CHECK(RS::get_singleton()->mesh_surface_get_material(untouched->get_base(), 0) == untouched_material);
		previous_material = updated_material;
	}
	memdelete(label);
	memdelete(untouched);
}

TEST_CASE("[SceneTree][Label3D] Foreground material alpha discard is explicit and preserves legacy shader variants") {
	CHECK(int(BaseMaterial3D::DEPTH_TEST_DEFAULT) == 0);
	CHECK(int(BaseMaterial3D::DEPTH_TEST_INVERTED) == 1);
	CHECK(int(BaseMaterial3D::DEPTH_TEST_ALWAYS) == 2);
	for (auto transparency : { BaseMaterial3D::TRANSPARENCY_DISABLED, BaseMaterial3D::TRANSPARENCY_ALPHA, BaseMaterial3D::TRANSPARENCY_ALPHA_SCISSOR, BaseMaterial3D::TRANSPARENCY_ALPHA_HASH, BaseMaterial3D::TRANSPARENCY_ALPHA_DEPTH_PRE_PASS }) {
		for (auto draw : { BaseMaterial3D::DEPTH_DRAW_OPAQUE_ONLY, BaseMaterial3D::DEPTH_DRAW_ALWAYS, BaseMaterial3D::DEPTH_DRAW_DISABLED }) {
			Ref<StandardMaterial3D> material;
			material.instantiate();
			material->set_transparency(transparency);
			material->set_depth_draw_mode(draw);
			const String original = material_code(material);
			for (auto comparison : { BaseMaterial3D::DEPTH_TEST_ALWAYS, BaseMaterial3D::DEPTH_TEST_INVERTED, BaseMaterial3D::DEPTH_TEST_DEFAULT }) {
				material->set("depth_test", comparison);
				CHECK(int(material->get("depth_test")) == int(comparison));
				const bool discard = comparison == BaseMaterial3D::DEPTH_TEST_ALWAYS && draw == BaseMaterial3D::DEPTH_DRAW_ALWAYS && transparency != BaseMaterial3D::TRANSPARENCY_DISABLED;
				const String code = material_code(material);
				CHECK(code.contains("depth_test_always") == (comparison == BaseMaterial3D::DEPTH_TEST_ALWAYS));
				CHECK(code.contains("if (ALPHA == 0.0)") == discard);
				CHECK_FALSE(code.contains("glyph_depth_offset"));
				String unchanged = code.replace(", depth_test_always", "").replace(", depth_test_inverted", "").replace("\tif (ALPHA == 0.0) {\n\t\tdiscard;\n\t}\n", "");
				CHECK(unchanged == original);
				material->set_flag(BaseMaterial3D::FLAG_DISABLE_DEPTH_TEST, true);
				const String disabled = material_code(material);
				CHECK(disabled.contains("depth_test_disabled"));
				CHECK_FALSE(disabled.contains("depth_test_always"));
				CHECK_FALSE(disabled.contains("if (ALPHA == 0.0)"));
				material->set_flag(BaseMaterial3D::FLAG_DISABLE_DEPTH_TEST, false);
				CHECK(material_code(material) == code);
			}
			ERR_PRINT_OFF;
			material->set("depth_test", -1);
			material->set("depth_test", BaseMaterial3D::DEPTH_TEST_MAX);
			ERR_PRINT_ON;
			CHECK(material->get_depth_test() == BaseMaterial3D::DEPTH_TEST_DEFAULT);
		}
	}
}

TEST_CASE("[SceneTree][Label3D] Depth comparison enum values survive text and binary material serialization") {
	for (auto comparison : { BaseMaterial3D::DEPTH_TEST_DEFAULT, BaseMaterial3D::DEPTH_TEST_INVERTED, BaseMaterial3D::DEPTH_TEST_ALWAYS }) {
		for (bool no_depth : { false, true }) {
			Ref<StandardMaterial3D> material;
			material.instantiate();
			material->set_depth_test(comparison);
			material->set_depth_draw_mode(BaseMaterial3D::DEPTH_DRAW_ALWAYS);
			material->set_transparency(BaseMaterial3D::TRANSPARENCY_ALPHA);
			material->set_flag(BaseMaterial3D::FLAG_DISABLE_DEPTH_TEST, no_depth);
			for (const char *extension : { "tres", "res" }) {
				const String path = TestUtils::get_temp_path(vformat("foreground_depth_%d_%d.%s", comparison, int(no_depth), extension));
				const Error save_error = ResourceSaver::save(material, path);
				CHECK(save_error == OK);
				if (save_error != OK) {
					return;
				}
				Ref<BaseMaterial3D> restored = ResourceLoader::load(path, "", ResourceFormatLoader::CACHE_MODE_IGNORE);
				CHECK(restored.is_valid());
				if (restored.is_null()) {
					return;
				}
				CHECK(restored != material);
				CHECK(int(restored->get("depth_test")) == int(comparison));
				CHECK(restored->get_flag(BaseMaterial3D::FLAG_DISABLE_DEPTH_TEST) == no_depth);
				CHECK(restored->get_depth_draw_mode() == BaseMaterial3D::DEPTH_DRAW_ALWAYS);
				CHECK(restored->get_transparency() == BaseMaterial3D::TRANSPARENCY_ALPHA);
				CHECK(material_code(restored) == material_code(material));
				restored->set_flag(BaseMaterial3D::FLAG_DISABLE_DEPTH_TEST, false);
				CHECK(material_code(restored).contains("depth_test_always") == (comparison == BaseMaterial3D::DEPTH_TEST_ALWAYS));
				CHECK(DirAccess::remove_absolute(path) == OK);
			}
		}
	}
}

} // namespace TestLabel3D

#endif // _3D_DISABLED
