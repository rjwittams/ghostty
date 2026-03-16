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
 * For a complete working example, see example/c-vt-mouse-encode in the
 * repository.
 *
 * ## Example
 *
 * @code{.c}
 * #include <assert.h>
 * #include <stdio.h>
 * #include <ghostty/vt.h>
 *
 * int main() {
 *   // Create encoder
 *   GhosttyMouseEncoder encoder;
 *   GhosttyResult result = ghostty_mouse_encoder_new(NULL, &encoder);
 *   assert(result == GHOSTTY_SUCCESS);
 *
 *   // Configure SGR format with normal tracking
 *   ghostty_mouse_encoder_setopt(encoder, GHOSTTY_MOUSE_ENCODER_OPT_EVENT,
 *       &(GhosttyMouseTrackingMode){GHOSTTY_MOUSE_TRACKING_NORMAL});
 *   ghostty_mouse_encoder_setopt(encoder, GHOSTTY_MOUSE_ENCODER_OPT_FORMAT,
 *       &(GhosttyMouseFormat){GHOSTTY_MOUSE_FORMAT_SGR});
 *
 *   // Set terminal geometry for coordinate mapping
 *   ghostty_mouse_encoder_setopt(encoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE,
 *       &(GhosttyMouseEncoderSize){
 *           .size = sizeof(GhosttyMouseEncoderSize),
 *           .screen_width = 800, .screen_height = 600,
 *           .cell_width = 10, .cell_height = 20,
 *       });
 *
 *   // Create and configure a left button press event
 *   GhosttyMouseEvent event;
 *   result = ghostty_mouse_event_new(NULL, &event);
 *   assert(result == GHOSTTY_SUCCESS);
 *   ghostty_mouse_event_set_action(event, GHOSTTY_MOUSE_ACTION_PRESS);
 *   ghostty_mouse_event_set_button(event, GHOSTTY_MOUSE_BUTTON_LEFT);
 *   ghostty_mouse_event_set_position(event,
 *       (GhosttyMousePosition){.x = 50.0f, .y = 40.0f});
 *
 *   // Encode the mouse event
 *   char buf[128];
 *   size_t written = 0;
 *   result = ghostty_mouse_encoder_encode(encoder, event,
 *       buf, sizeof(buf), &written);
 *   assert(result == GHOSTTY_SUCCESS);
 *
 *   // Use the encoded sequence (e.g., write to terminal)
 *   fwrite(buf, 1, written, stdout);
 *
 *   // Cleanup
 *   ghostty_mouse_event_free(event);
 *   ghostty_mouse_encoder_free(encoder);
 *   return 0;
 * }
 * @endcode
 *
 * ## Example: Encoding with Terminal State
 *
 * When you have a GhosttyTerminal, you can sync its tracking mode and
 * output format into the encoder automatically:
 *
 * @code{.c}
 * // Create a terminal and feed it some VT data that enables mouse tracking
 * GhosttyTerminal terminal;
 * ghostty_terminal_new(NULL, &terminal,
 *     (GhosttyTerminalOptions){.cols = 80, .rows = 24, .max_scrollback = 0});
 *
 * // Application might write data that enables mouse reporting, etc.
 * ghostty_terminal_vt_write(terminal, vt_data, vt_len);
 *
 * // Create an encoder and sync its options from the terminal
 * GhosttyMouseEncoder encoder;
 * ghostty_mouse_encoder_new(NULL, &encoder);
 * ghostty_mouse_encoder_setopt_from_terminal(encoder, terminal);
 *
 * // Encode a mouse event using the terminal-derived options
 * char buf[128];
 * size_t written = 0;
 * ghostty_mouse_encoder_encode(encoder, event, buf, sizeof(buf), &written);
 *
 * ghostty_mouse_encoder_free(encoder);
 * ghostty_terminal_free(terminal);
 * @endcode
 *
 * @{
 */

#include <ghostty/vt/mouse/event.h>
#include <ghostty/vt/mouse/encoder.h>

/** @} */

#endif /* GHOSTTY_VT_MOUSE_H */
