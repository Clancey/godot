/**************************************************************************/
/*  shareplay_bridge.h                                                    */
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

// C-callable bridge to the Swift SharePlaySessionManager.
//
// The entry points below are implemented in Swift with `@_cdecl` (see
// `SharePlayBridge.swift`). Using a plain C interface avoids depending on the
// generated `-Swift.h` header from Objective-C++.
//
// Do NOT import this header from `bridging_header_visionos.h`; see
// `shareplay_bridge_types.h` for why.

#include "shareplay_bridge_types.h"

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Session lifecycle.
void godot_shareplay_set_activity_title(const char *title);
void godot_shareplay_start_activity(void);
void godot_shareplay_end_activity(void);

// State queries.
bool godot_shareplay_is_session_active(void);
const char *godot_shareplay_get_local_participant_id(void);
int godot_shareplay_get_participant_count(void);

// Messaging. A null `recipient_id` broadcasts to every participant.
void godot_shareplay_send_message(const uint8_t *data, int length, const char *recipient_id);

// Callback registration. Callbacks are invoked on the SharePlay dispatch queue.
void godot_shareplay_set_message_callback(godot_shareplay_message_callback_t callback, void *userdata);
void godot_shareplay_set_participant_joined_callback(godot_shareplay_participant_callback_t callback, void *userdata);
void godot_shareplay_set_participant_left_callback(godot_shareplay_participant_callback_t callback, void *userdata);
void godot_shareplay_set_session_started_callback(godot_shareplay_session_callback_t callback, void *userdata);
void godot_shareplay_set_session_ended_callback(godot_shareplay_session_callback_t callback, void *userdata);

#ifdef __cplusplus
}
#endif
