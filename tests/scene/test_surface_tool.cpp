/**************************************************************************/
/*  test_surface_tool.cpp                                                 */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md).   */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                    */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining   */
/* a copy of this software and associated documentation files (the         */
/* "Software"), to deal in the Software without restriction, including     */
/* without limitation the rights to use, copy, modify, merge, publish,      */
/* distribute, sublicense, and/or sell copies of the Software, and to       */
/* permit persons to whom the Software is furnished to do so, subject to    */
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

#include "scene/resources/surface_tool.h"
#include "tests/test_macros.h"

#include "modules/modules_enabled.gen.h"

#ifdef MODULE_GLTF_ENABLED
#include "core/crypto/crypto_core.h"
#include "core/io/json.h"
#include "core/io/marshalls.h"

#include "modules/gltf/gltf_document.h"
#include "modules/gltf/gltf_state.h"
#include "modules/gltf/structures/gltf_mesh.h"
#endif

TEST_FORCE_LINK(test_surface_tool)

namespace TestSurfaceTool {

static Ref<SurfaceTool> make_triangle(bool p_clockwise = true, real_t p_u = 1.0, real_t p_v = 1.0) {
	Ref<SurfaceTool> surface;
	surface.instantiate();
	surface->begin(Mesh::PRIMITIVE_TRIANGLES);
	const Vector3 positions[3] = { Vector3(), Vector3(1, 0, 0), Vector3(0, 1, 0) };
	for (int i = 0; i < 3; i++) {
		int vertex = p_clockwise && i > 0 ? 3 - i : i;
		surface->set_normal(Vector3(0, 0, 1));
		surface->set_uv(Vector2(positions[vertex].x * p_u, positions[vertex].y * p_v));
		surface->add_vertex(positions[vertex]);
	}
	return surface;
}

static void check_frame(const Array &p_arrays, const Vector3 &p_u, const Vector3 &p_v) {
	Vector<Vector3> normals = p_arrays[Mesh::ARRAY_NORMAL];
	Vector<float> tangents = p_arrays[Mesh::ARRAY_TANGENT];
	REQUIRE(tangents.size() == normals.size() * 4);
	for (int i = 0; i < normals.size(); i++) {
		Vector3 tangent(tangents[i * 4], tangents[i * 4 + 1], tangents[i * 4 + 2]);
		Vector3 binormal = normals[i].cross(tangent).normalized() * tangents[i * 4 + 3];
		CHECK(tangent.dot(p_u) > 0.999);
		CHECK(binormal.dot(p_v) > 0.999);
		CHECK(Math::is_equal_approx(Math::abs(tangents[i * 4 + 3]), 1.0f));
		Vector3 sampled_normal = (binormal * 0.6 + normals[i] * 0.8).normalized();
		// Committing an ArrayMesh quantizes its normal/tangent attributes.
		CHECK(sampled_normal.distance_to((p_v * 0.6 + normals[i] * 0.8).normalized()) < 0.0001);
	}
}

TEST_CASE("[SceneTree][SurfaceTool] Generated tangent frames follow supplied normals and mirrored UV derivatives") {
	for (bool clockwise : { false, true }) {
		for (bool indexed : { false, true }) {
			for (real_t u : { real_t(-1), real_t(1) }) {
				for (real_t v : { real_t(-1), real_t(1) }) {
					Ref<SurfaceTool> surface = make_triangle(clockwise, u, v);
					if (indexed) {
						surface->index();
					}
					Array original = surface->commit_to_arrays();
					surface->generate_tangents(true);
					Array generated = surface->commit_to_arrays();
					CHECK(generated[Mesh::ARRAY_NORMAL] == original[Mesh::ARRAY_NORMAL]);
					CHECK(generated[Mesh::ARRAY_VERTEX] == original[Mesh::ARRAY_VERTEX]);
					CHECK(generated[Mesh::ARRAY_TEX_UV] == original[Mesh::ARRAY_TEX_UV]);
					check_frame(generated, Vector3(u, 0, 0), Vector3(0, v, 0));
				}
			}
		}
	}
}

TEST_CASE("[SceneTree][SurfaceTool] Generated tangents remain consistent after a reflected nonuniform transform") {
	Ref<SurfaceTool> original = make_triangle();
	original->generate_tangents();
	Ref<ArrayMesh> mesh = original->commit();
	Ref<SurfaceTool> reflected;
	reflected.instantiate();
	reflected->append_from(mesh, 0, Transform3D(Basis().scaled(Vector3(-2, 3, 0.5)), Vector3()));
	Array before = reflected->commit_to_arrays();
	check_frame(before, Vector3(-1, 0, 0), Vector3(0, 1, 0));
	reflected->generate_tangents();
	Array after = reflected->commit_to_arrays();
	CHECK(after[Mesh::ARRAY_NORMAL] == before[Mesh::ARRAY_NORMAL]);
	CHECK(after[Mesh::ARRAY_TEX_UV] == before[Mesh::ARRAY_TEX_UV]);
	check_frame(after, Vector3(-1, 0, 0), Vector3(0, 1, 0));
}

TEST_CASE("[SceneTree][SurfaceTool] Degenerate UVs retain finite generated tangent fallbacks") {
	for (bool indexed : { false, true }) {
		Ref<SurfaceTool> surface = make_triangle(true, 0, 0);
		if (indexed) {
			surface->index();
		}
		Array before = surface->commit_to_arrays();
		surface->generate_tangents();
		Array after = surface->commit_to_arrays();
		CHECK(after[Mesh::ARRAY_NORMAL] == before[Mesh::ARRAY_NORMAL]);
		CHECK(after[Mesh::ARRAY_TEX_UV] == before[Mesh::ARRAY_TEX_UV]);
		Vector<float> tangents = after[Mesh::ARRAY_TANGENT];
		REQUIRE(tangents.size() == 12);
		for (int i = 0; i < 3; i++) {
			CHECK(Vector3(tangents[i * 4], tangents[i * 4 + 1], tangents[i * 4 + 2]).is_finite());
			CHECK(Math::abs(tangents[i * 4 + 3]) == 1.0f);
		}
	}
}

TEST_CASE("[SceneTree][SurfaceTool] Shared zero-area faces cannot replace visible tangent frames without splitting") {
	for (bool degenerate_first : { false, true }) {
		for (bool clockwise : { false, true }) {
			Ref<SurfaceTool> surface = make_triangle(clockwise);
			for (int face = 0; face < 2; face++) {
				bool degenerate = (face == 0) == degenerate_first;
				for (int index : { 0, degenerate ? 2 : 1, 2 }) {
					surface->add_index(index);
				}
			}
			Array before = surface->commit_to_arrays();
			surface->generate_tangents(false);
			Array after = surface->commit_to_arrays();
			CHECK(after[Mesh::ARRAY_INDEX] == before[Mesh::ARRAY_INDEX]);
			CHECK(after[Mesh::ARRAY_NORMAL] == before[Mesh::ARRAY_NORMAL]);
			CHECK(after[Mesh::ARRAY_TEX_UV] == before[Mesh::ARRAY_TEX_UV]);
			CHECK(after[Mesh::ARRAY_VERTEX] == before[Mesh::ARRAY_VERTEX]);
			check_frame(after, Vector3(1, 0, 0), Vector3(0, 1, 0));
		}
	}
}

#ifdef MODULE_GLTF_ENABLED
TEST_CASE("[SceneTree][SurfaceTool][GLTF] Imported generated frames are corrected without replacing authored tangents or normals") {
	for (bool authored : { false, true }) {
		for (bool morph : { false, true }) {
			PackedByteArray buffer;
			Array views;
			Array accessors;
			auto accessor = [&](const Vector<float> &p_values, const String &p_type) {
				int offset = buffer.size();
				buffer.resize(offset + p_values.size() * sizeof(float));
				for (int i = 0; i < p_values.size(); i++) {
					encode_float(p_values[i], buffer.ptrw() + offset + i * sizeof(float));
				}
				views.push_back(Dictionary{ { "buffer", 0 }, { "byteOffset", offset }, { "byteLength", int(p_values.size() * sizeof(float)) } });
				accessors.push_back(Dictionary{ { "bufferView", views.size() - 1 }, { "componentType", 5126 }, { "count", 3 }, { "type", p_type } });
				return accessors.size() - 1;
			};
			Dictionary attributes;
			attributes["POSITION"] = accessor({ 0, 0, 0, 1, 0, 0, 0, 1, 0 }, "VEC3");
			attributes["NORMAL"] = accessor({ 0, 0, 1, 0, 0, 1, 0, 0, 1 }, "VEC3");
			attributes["TEXCOORD_0"] = accessor({ 0, 0, 1, 0, 0, 1 }, "VEC2");
			if (authored) {
				attributes["TANGENT"] = accessor({ 0, 1, 0, -1, 0, 1, 0, -1, 0, 1, 0, -1 }, "VEC4");
			}
			Dictionary primitive{ { "attributes", attributes }, { "mode", 4 } };
			if (morph) {
				primitive["targets"] = Array{ Dictionary{ { "POSITION", accessor({ 0, 0, 0.1f, 0, 0, 0.1f, 0, 0, 0.1f }, "VEC3") } } };
			}
			Dictionary document{
				{ "asset", Dictionary{ { "version", "2.0" } } },
				{ "buffers", Array{ Dictionary{ { "byteLength", buffer.size() }, { "uri", "data:application/octet-stream;base64," + CryptoCore::b64_encode_str(buffer.ptr(), buffer.size()) } } } },
				{ "bufferViews", views }, { "accessors", accessors },
				{ "meshes", Array{ Dictionary{ { "primitives", Array{ primitive } } } } },
				{ "nodes", Array{ Dictionary{ { "mesh", 0 } } } },
				{ "scenes", Array{ Dictionary{ { "nodes", Array{ 0 } } } } }, { "scene", 0 }
			};
			Ref<GLTFDocument> importer;
			importer.instantiate();
			Ref<GLTFState> state;
			state.instantiate();
			REQUIRE(importer->append_from_buffer(JSON::stringify(document).to_utf8_buffer(), "", state,
							GLTFDocument::IMPORT_FLAG_GENERATE_TANGENT_ARRAYS | GLTFDocument::IMPORT_FLAG_FORCE_DISABLE_MESH_COMPRESSION) == OK);
			REQUIRE(state->get_meshes().size() == 1);
			Ref<ImporterMesh> mesh = state->get_meshes()[0]->get_mesh();
			REQUIRE(mesh.is_valid());
			REQUIRE(mesh->get_surface_count() == 1);
			CHECK(mesh->get_blend_shape_count() == (morph ? 1 : 0));
			for (int shape = -1; shape < (morph ? 1 : 0); shape++) {
				Array arrays = shape < 0 ? mesh->get_surface_arrays(0) : mesh->get_surface_blend_shape_arrays(0, shape);
				Vector<Vector3> normals = arrays[Mesh::ARRAY_NORMAL];
				for (const Vector3 &normal : normals) {
					CHECK(normal == Vector3(0, 0, 1));
				}
				if (authored) {
					Vector<float> tangents = arrays[Mesh::ARRAY_TANGENT];
					REQUIRE(tangents.size() == normals.size() * 4);
					for (int i = 0; i < normals.size(); i++) {
						CHECK(Vector4(tangents[i * 4], tangents[i * 4 + 1], tangents[i * 4 + 2], tangents[i * 4 + 3]) == Vector4(0, 1, 0, -1));
					}
				} else {
					check_frame(arrays, Vector3(1, 0, 0), Vector3(0, 1, 0));
				}
			}
		}
	}
}
#endif

} // namespace TestSurfaceTool
