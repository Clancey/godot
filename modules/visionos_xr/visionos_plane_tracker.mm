/**************************************************************************/
/*  visionos_plane_tracker.mm                                             */
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

#ifdef VISIONOS_ENABLED

#include "visionos_plane_tracker.h"

#include "core/object/class_db.h"
#include "scene/resources/3d/box_shape_3d.h"
#include "scene/resources/3d/concave_polygon_shape_3d.h"
#include "scene/resources/3d/primitive_meshes.h"
#include "servers/xr/xr_server.h"

void VisionOSPlaneTracker::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_bounds_size", "bounds_size"), &VisionOSPlaneTracker::set_bounds_size);
	ClassDB::bind_method(D_METHOD("get_bounds_size"), &VisionOSPlaneTracker::get_bounds_size);
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR2, "bounds_size"), "set_bounds_size", "get_bounds_size");

	ClassDB::bind_method(D_METHOD("set_plane_alignment", "plane_alignment"), &VisionOSPlaneTracker::set_plane_alignment);
	ClassDB::bind_method(D_METHOD("get_plane_alignment"), &VisionOSPlaneTracker::get_plane_alignment);
	ADD_PROPERTY(PropertyInfo(Variant::INT, "plane_alignment", PROPERTY_HINT_ENUM, "Horizontal Upward,Horizontal Downward,Vertical,Arbitrary"), "set_plane_alignment", "get_plane_alignment");

	ClassDB::bind_method(D_METHOD("set_plane_label", "plane_label"), &VisionOSPlaneTracker::set_plane_label);
	ClassDB::bind_method(D_METHOD("get_plane_label"), &VisionOSPlaneTracker::get_plane_label);
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "plane_label"), "set_plane_label", "get_plane_label");

	ClassDB::bind_method(D_METHOD("set_mesh_data", "origin", "vertices", "indices"), &VisionOSPlaneTracker::set_mesh_data, DEFVAL(PackedInt32Array()));
	ClassDB::bind_method(D_METHOD("clear_mesh_data"), &VisionOSPlaneTracker::clear_mesh_data);

	ClassDB::bind_method(D_METHOD("get_mesh_offset"), &VisionOSPlaneTracker::get_mesh_offset);
	ClassDB::bind_method(D_METHOD("get_mesh"), &VisionOSPlaneTracker::get_mesh);
	ClassDB::bind_method(D_METHOD("get_shape", "thickness"), &VisionOSPlaneTracker::get_shape, DEFVAL(0.01));

	ADD_SIGNAL(MethodInfo("mesh_changed"));

	BIND_ENUM_CONSTANT(PLANE_ALIGNMENT_HORIZONTAL_UPWARD);
	BIND_ENUM_CONSTANT(PLANE_ALIGNMENT_HORIZONTAL_DOWNWARD);
	BIND_ENUM_CONSTANT(PLANE_ALIGNMENT_VERTICAL);
	BIND_ENUM_CONSTANT(PLANE_ALIGNMENT_ARBITRARY);
}

VisionOSPlaneTracker::VisionOSPlaneTracker() {
	set_tracker_type(XRServer::TRACKER_ANCHOR);
}

void VisionOSPlaneTracker::set_bounds_size(const Vector2 &p_bounds_size) {
	if (Math::abs(bounds_size.x - p_bounds_size.x) > 0.001 || Math::abs(bounds_size.y - p_bounds_size.y) > 0.001) {
		bounds_size = p_bounds_size;

		if (!mesh.has_mesh_data) {
			clear_mesh_data();
			emit_signal(SNAME("mesh_changed"));
		}
	}
}

Vector2 VisionOSPlaneTracker::get_bounds_size() const {
	return bounds_size;
}

void VisionOSPlaneTracker::set_plane_alignment(PlaneAlignment p_plane_alignment) {
	plane_alignment = p_plane_alignment;
}

VisionOSPlaneTracker::PlaneAlignment VisionOSPlaneTracker::get_plane_alignment() const {
	return plane_alignment;
}

void VisionOSPlaneTracker::set_plane_label(const String &p_plane_label) {
	if (plane_label != p_plane_label) {
		plane_label = p_plane_label;
		set_tracker_desc(plane_label);
	}
}

String VisionOSPlaneTracker::get_plane_label() const {
	return plane_label;
}

void VisionOSPlaneTracker::set_mesh_data(const Transform3D &p_origin, const PackedVector2Array &p_vertices, const PackedInt32Array &p_indices) {
	if (p_vertices.size() < 3) {
		if (mesh.has_mesh_data) {
			clear_mesh_data();
			emit_signal(SNAME("mesh_changed"));
		}
		return;
	}

	bool has_changed = !mesh.has_mesh_data;
	mesh.has_mesh_data = true;
	mesh.origin = p_origin;

	if (mesh.vertices.size() != p_vertices.size()) {
		has_changed = true;
	} else {
		for (int i = 0; i < p_vertices.size() && !has_changed; i++) {
			const Vector2 &a = p_vertices[i];
			const Vector2 &b = mesh.vertices[i];
			has_changed = (Math::abs(a.x - b.x) > 0.001) || (Math::abs(a.y - b.y) > 0.001);
		}
	}
	if (has_changed) {
		mesh.vertices = p_vertices;
	}

	if (p_indices.is_empty()) {
		int count = (p_vertices.size() - 2) * 3;
		if (has_changed || mesh.indices.size() != count) {
			has_changed = true;
			int offset = 1;
			mesh.indices.resize(count);
			int32_t *idx = mesh.indices.ptrw();
			for (int i = 0; i < count; i += 3) {
				idx[i + 0] = 0;
				idx[i + 2] = offset++;
				idx[i + 1] = offset;
			}
		}
	} else {
		if (mesh.indices.size() != p_indices.size()) {
			has_changed = true;
		} else {
			for (int i = 0; i < p_indices.size() && !has_changed; i++) {
				has_changed = mesh.indices[i] != p_indices[i];
			}
		}
		if (has_changed) {
			mesh.indices = p_indices;
		}
	}

	if (has_changed) {
		mesh.mesh.unref();
		mesh.shape3d.unref();
		emit_signal(SNAME("mesh_changed"));
	}
}

void VisionOSPlaneTracker::clear_mesh_data() {
	mesh.mesh.unref();
	mesh.shape3d.unref();

	if (mesh.has_mesh_data) {
		mesh.has_mesh_data = false;
		mesh.origin = Transform3D();
		mesh.vertices.clear();
		mesh.indices.clear();
		emit_signal(SNAME("mesh_changed"));
	}
}

Transform3D VisionOSPlaneTracker::get_mesh_offset() const {
	Transform3D offset;

	if (mesh.has_mesh_data) {
		offset = mesh.origin;

		Ref<XRPose> pose = get_pose(SNAME("default"));
		if (pose.is_valid()) {
			offset = pose->get_transform().inverse() * offset;
		}

		XRServer *xr_server = XRServer::get_singleton();
		if (xr_server) {
			offset.origin *= xr_server->get_world_scale();
		}
	}

	return offset;
}

Ref<Mesh> VisionOSPlaneTracker::get_mesh() {
	if (mesh.mesh.is_valid()) {
		return mesh.mesh;
	}

	if (mesh.has_mesh_data) {
		Ref<ArrayMesh> array_mesh;
		Array arr;

		PackedVector3Array vertices;
		vertices.resize(mesh.vertices.size());
		const Vector2 *read = mesh.vertices.ptr();
		Vector3 *write = vertices.ptrw();
		for (int v = 0; v < mesh.vertices.size(); v++) {
			write[v] = Vector3(read[v].x, read[v].y, 0.0);
		}

		arr.resize(Mesh::ARRAY_MAX);
		arr[Mesh::ARRAY_VERTEX] = vertices;
		arr[Mesh::ARRAY_INDEX] = mesh.indices;

		array_mesh.instantiate();
		array_mesh->add_surface_from_arrays(Mesh::PrimitiveType::PRIMITIVE_TRIANGLES, arr);

		mesh.mesh = array_mesh;
	} else if (bounds_size.x > 0.0 && bounds_size.y > 0.0) {
		Ref<PlaneMesh> plane_mesh;
		plane_mesh.instantiate();
		plane_mesh->set_orientation(PlaneMesh::Orientation::FACE_Z);
		plane_mesh->set_size(bounds_size);
		mesh.mesh = plane_mesh;
	}

	return mesh.mesh;
}

Ref<Shape3D> VisionOSPlaneTracker::get_shape(real_t p_thickness) {
	if (mesh.shape3d.is_valid()) {
		return mesh.shape3d;
	}

	if (mesh.has_mesh_data) {
		Ref<ConcavePolygonShape3D> shape;
		Vector<Vector3> faces;

		int isize = mesh.indices.size();
		const Vector2 *vr = mesh.vertices.ptr();
		const int32_t *ir = mesh.indices.ptr();

		// Find edges.
		HashMap<Edge, int, Edge> edge_counts;
		for (int i = 0; i < isize; i += 3) {
			for (int j = 0; j < 3; j++) {
				Edge e(ir[i + j], ir[i + ((j + 1) % 3)]);
				edge_counts[e]++;
			}
		}

		// Find outer edges.
		thread_local LocalVector<Edge> outer_edges;
		outer_edges.clear();
		for (const KeyValue<Edge, int> &e : edge_counts) {
			if (e.value > 1) {
				outer_edges.push_back(e.key);
			}
		}

		faces.resize(2 * isize + 6 * outer_edges.size());
		Vector3 *write = faces.ptrw();

		// Top and bottom faces.
		for (int i = 0; i < isize; i += 3) {
			Vector3 a = Vector3(vr[ir[i]].x, vr[ir[i]].y, 0.0);
			Vector3 b = Vector3(vr[ir[i + 1]].x, vr[ir[i + 1]].y, 0.0);
			Vector3 c = Vector3(vr[ir[i + 2]].x, vr[ir[i + 2]].y, 0.0);

			*write++ = a;
			*write++ = b;
			*write++ = c;

			a.z = -p_thickness;
			b.z = -p_thickness;
			c.z = -p_thickness;

			*write++ = a;
			*write++ = c;
			*write++ = b;
		}

		// Side faces from outer edges.
		for (const Edge &edge : outer_edges) {
			Vector3 a = Vector3(vr[edge.a].x, vr[edge.a].y, 0.0);
			Vector3 b = Vector3(vr[edge.b].x, vr[edge.b].y, 0.0);
			Vector3 c = b + Vector3(0.0, 0.0, -p_thickness);
			Vector3 d = a + Vector3(0.0, 0.0, -p_thickness);

			*write++ = a;
			*write++ = b;
			*write++ = c;

			*write++ = a;
			*write++ = c;
			*write++ = d;
		}

		shape.instantiate();
		shape->set_faces(faces);
		mesh.shape3d = shape;
	} else if (bounds_size.x > 0.0 && bounds_size.y > 0.0) {
		Ref<BoxShape3D> box_shape;
		box_shape.instantiate();
		box_shape->set_size(Vector3(bounds_size.x, bounds_size.y, p_thickness));
		mesh.shape3d = box_shape;
	}

	return mesh.shape3d;
}

#endif // VISIONOS_ENABLED
