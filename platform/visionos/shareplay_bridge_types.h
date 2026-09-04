/**************************************************************************/
/*  shareplay_bridge_types.h                                              */
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

// Callback function pointer types shared between the Swift SharePlay bridge and
// the Godot SharePlayMultiplayerPeer.
//
// This header deliberately contains *only* type definitions. It is imported by
// `bridging_header_visionos.h` so Swift can name these types, and the Swift side
// defines the bridge entry points with `@_cdecl`. Declaring those same functions
// here would make Swift see both an imported C declaration and its own
// definition, which is an invalid redeclaration. The C declarations therefore
// live in `shareplay_bridge.h`, which is only included from Objective-C++.

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*godot_shareplay_message_callback_t)(const uint8_t *data, int length, const char *sender_id, void *userdata);
typedef void (*godot_shareplay_participant_callback_t)(const char *participant_id, void *userdata);
typedef void (*godot_shareplay_session_callback_t)(void *userdata);

#ifdef __cplusplus
}
#endif
