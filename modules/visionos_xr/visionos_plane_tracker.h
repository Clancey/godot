/**************************************************************************/
/*  visionos_plane_tracker.h                                              */
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

#pragma once

#ifdef VISIONOS_ENABLED

#include "scene/resources/3d/shape_3d.h"
#include "scene/resources/mesh.h"
#include "servers/xr/xr_positional_tracker.h"

class VisionOSPlaneTracker : public XRPositionalTracker {
	GDCLASS(VisionOSPlaneTracker, XRPositionalTracker);

public:
	enum PlaneAlignment {
		PLANE_ALIGNMENT_HORIZONTAL_UPWARD = 0,
		PLANE_ALIGNMENT_HORIZONTAL_DOWNWARD = 1,
		PLANE_ALIGNMENT_VERTICAL = 2,
		PLANE_ALIGNMENT_ARBITRARY = 3,
	};

	VisionOSPlaneTracker();

	void set_bounds_size(const Vector2 &p_bounds_size);
	Vector2 get_bounds_size() const;

	void set_plane_alignment(PlaneAlignment p_plane_alignment);
	PlaneAlignment get_plane_alignment() const;

	void set_plane_label(const String &p_plane_label);
	String get_plane_label() const;

	void set_mesh_data(const Transform3D &p_origin, const PackedVector2Array &p_vertices, const PackedInt32Array &p_indices = PackedInt32Array());
	void clear_mesh_data();

	Transform3D get_mesh_offset() const;
	Ref<Mesh> get_mesh();
	Ref<Shape3D> get_shape(real_t p_thickness = 0.01);

protected:
	static void _bind_methods();

private:
	Vector2 bounds_size;
	PlaneAlignment plane_alignment = PLANE_ALIGNMENT_HORIZONTAL_UPWARD;
	String plane_label;

	struct MeshData {
		bool has_mesh_data = false;
		Transform3D origin;
		PackedVector2Array vertices;
		PackedInt32Array indices;

		Ref<Mesh> mesh;
		Ref<Shape3D> shape3d;
	} mesh;

	struct Edge {
		int32_t a;
		int32_t b;
		static _FORCE_INLINE_ uint32_t hash(const Edge &p_edge) {
			uint32_t h = hash_murmur3_one_32(p_edge.a);
			return hash_murmur3_one_32(p_edge.b, h);
		}
		bool operator==(const Edge &p_edge) const {
			return (a == p_edge.a && b == p_edge.b);
		}

		Edge(int32_t p_a = 0, int32_t p_b = 0) {
			a = p_a;
			b = p_b;
			if (a < b) {
				SWAP(a, b);
			}
		}
	};
};

VARIANT_ENUM_CAST(VisionOSPlaneTracker::PlaneAlignment);

#endif // VISIONOS_ENABLED
