#pragma once

#include <cstdint>

namespace VisionOSRenderProbe {

inline bool sample(uint64_t p_frame) {
	return p_frame == 1 || p_frame == 2 || p_frame == 30 || p_frame == 60 || p_frame == 120 || p_frame == 180 || p_frame == 300 || p_frame == 600;
}

inline bool clear_output(double p_elapsed_seconds, uint32_t p_clear_count) {
	return p_elapsed_seconds >= 0.0 && p_elapsed_seconds < 2.0 && p_clear_count < 180;
}

} // namespace VisionOSRenderProbe
