/**************************************************************************/
/*  test_pipeline_hash_map_rd.cpp                                         */
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

TEST_FORCE_LINK(test_pipeline_hash_map_rd)

#ifdef RD_ENABLED

#include "servers/rendering/renderer_rd/pipeline_hash_map_rd.h"
#include "tests/test_tools.h"

namespace TestPipelineHashMapRD {

struct FailedCompiler {
	void compile(uint32_t p_key) {}
};

TEST_CASE("[PipelineHashMapRD] Failed compilation tasks are drained once") {
	ErrorDetector errors;
	FailedCompiler compiler;
	{
		PipelineHashMapRD<uint32_t, FailedCompiler, decltype(&FailedCompiler::compile)> pipelines;
		pipelines.set_creation_object_and_function(&compiler, &FailedCompiler::compile);
		for (uint32_t i = 0; i < 4; i++) {
			pipelines.compile_pipeline(i, i, RSE::PIPELINE_SOURCE_SURFACE, true);
		}
		pipelines.clear_pipelines();
		CHECK_FALSE(errors.has_error);
		pipelines.clear_pipelines();
		CHECK_FALSE(errors.has_error);
	}
	CHECK_FALSE(errors.has_error);
}

} // namespace TestPipelineHashMapRD

#endif // RD_ENABLED
