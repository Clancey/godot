/**************************************************************************/
/*  visionos_mesh_tracker.h                                               */
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

class VisionOSMeshTracker : public XRPositionalTracker {
	GDCLASS(VisionOSMeshTracker, XRPositionalTracker);

public:
	VisionOSMeshTracker();

	void set_mesh_data_3d(const PackedVector3Array &p_vertices, const PackedVector3Array &p_normals, const PackedInt32Array &p_indices);
	void clear_mesh_data();

	Ref<Mesh> get_mesh();
	Ref<Shape3D> get_shape();

protected:
	static void _bind_methods();

private:
	struct MeshData {
		bool has_mesh_data = false;
		PackedVector3Array vertices;
		PackedVector3Array normals;
		PackedInt32Array indices;

		Ref<Mesh> mesh;
		Ref<Shape3D> shape3d;
	} mesh;
};

#endif // VISIONOS_ENABLED
