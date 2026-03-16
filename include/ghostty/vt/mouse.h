/**
 * @file mouse.h
 *
 * Mouse encoding module - encode mouse events into terminal escape sequences.
 */

#ifndef GHOSTTY_VT_MOUSE_H
#define GHOSTTY_VT_MOUSE_H

/** @defgroup mouse Mouse Encoding
 *
 * Utilities for encoding mouse events into terminal escape sequences,
 * supporting X10, UTF-8, SGR, URxvt, and SGR-Pixels mouse protocols.
 *
 * ## Basic Usage
 *
 * 1. Create an encoder instance with ghostty_mouse_encoder_new().
 * 2. Configure encoder options with ghostty_mouse_encoder_setopt() or
 *    ghostty_mouse_encoder_setopt_from_terminal().
 * 3. For each mouse event:
 *    - Create a mouse event with ghostty_mouse_event_new().
 *    - Set event properties (action, button, modifiers, position).
 *    - Encode with ghostty_mouse_encoder_encode().
 *    - Free the event with ghostty_mouse_event_free() or reuse it.
 * 4. Free the encoder with ghostty_mouse_encoder_free() when done.
 *
 * @{
 */

#include <ghostty/vt/mouse/event.h>
#include <ghostty/vt/mouse/encoder.h>

/** @} */

#endif /* GHOSTTY_VT_MOUSE_H */
