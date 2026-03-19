/**************************************************************************/
/*  visionos_mesh_tracker.mm                                              */
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

#include "visionos_mesh_tracker.h"

#include "scene/resources/3d/concave_polygon_shape_3d.h"
#include "servers/xr/xr_server.h"

void VisionOSMeshTracker::_bind_methods() {
	ClassDB::bind_method(D_METHOD("get_mesh"), &VisionOSMeshTracker::get_mesh);
	ClassDB::bind_method(D_METHOD("get_shape"), &VisionOSMeshTracker::get_shape);
	ClassDB::bind_method(D_METHOD("clear_mesh_data"), &VisionOSMeshTracker::clear_mesh_data);

	ADD_SIGNAL(MethodInfo("mesh_changed"));
}

VisionOSMeshTracker::VisionOSMeshTracker() {
	set_tracker_type(XRServer::TRACKER_ANCHOR);
}

void VisionOSMeshTracker::set_mesh_data_3d(const PackedVector3Array &p_vertices, const PackedVector3Array &p_normals, const PackedInt32Array &p_indices) {
	if (p_vertices.size() < 3 || p_indices.size() < 3) {
		if (mesh.has_mesh_data) {
			clear_mesh_data();
			emit_signal(SNAME("mesh_changed"));
		}
		return;
	}

	bool has_changed = !mesh.has_mesh_data;
	mesh.has_mesh_data = true;

	if (mesh.vertices.size() != p_vertices.size()) {
		has_changed = true;
	} else {
		const Vector3 *old_ptr = mesh.vertices.ptr();
		const Vector3 *new_ptr = p_vertices.ptr();
		for (int i = 0; i < p_vertices.size() && !has_changed; i++) {
			has_changed = (Math::abs(old_ptr[i].x - new_ptr[i].x) > 0.001) ||
					(Math::abs(old_ptr[i].y - new_ptr[i].y) > 0.001) ||
					(Math::abs(old_ptr[i].z - new_ptr[i].z) > 0.001);
		}
	}

	if (has_changed) {
		mesh.vertices = p_vertices;
		mesh.normals = p_normals;
		mesh.indices = p_indices;
		mesh.mesh.unref();
		mesh.shape3d.unref();
		emit_signal(SNAME("mesh_changed"));
	}
}

void VisionOSMeshTracker::clear_mesh_data() {
	mesh.mesh.unref();
	mesh.shape3d.unref();

	if (mesh.has_mesh_data) {
		mesh.has_mesh_data = false;
		mesh.vertices.clear();
		mesh.normals.clear();
		mesh.indices.clear();
		emit_signal(SNAME("mesh_changed"));
	}
}

Ref<Mesh> VisionOSMeshTracker::get_mesh() {
	if (mesh.mesh.is_valid()) {
		return mesh.mesh;
	}

	if (!mesh.has_mesh_data) {
		return Ref<Mesh>();
	}

	Ref<ArrayMesh> array_mesh;
	Array arr;

	arr.resize(RS::ARRAY_MAX);
	arr[RS::ARRAY_VERTEX] = mesh.vertices;
	if (mesh.normals.size() == mesh.vertices.size()) {
		arr[RS::ARRAY_NORMAL] = mesh.normals;
	}
	arr[RS::ARRAY_INDEX] = mesh.indices;

	array_mesh.instantiate();
	array_mesh->add_surface_from_arrays(Mesh::PrimitiveType::PRIMITIVE_TRIANGLES, arr);

	mesh.mesh = array_mesh;
	return mesh.mesh;
}

Ref<Shape3D> VisionOSMeshTracker::get_shape() {
	if (mesh.shape3d.is_valid()) {
		return mesh.shape3d;
	}

	if (!mesh.has_mesh_data) {
		return Ref<Shape3D>();
	}

	Ref<ConcavePolygonShape3D> shape;
	Vector<Vector3> faces;

	int isize = mesh.indices.size();
	const Vector3 *vr = mesh.vertices.ptr();
	const int32_t *ir = mesh.indices.ptr();

	faces.resize(isize);
	Vector3 *write = faces.ptrw();

	for (int i = 0; i < isize; i += 3) {
		write[i + 0] = vr[ir[i + 0]];
		write[i + 1] = vr[ir[i + 1]];
		write[i + 2] = vr[ir[i + 2]];
	}

	shape.instantiate();
	shape->set_faces(faces);
	mesh.shape3d = shape;

	return mesh.shape3d;
}

#endif // VISIONOS_ENABLED
