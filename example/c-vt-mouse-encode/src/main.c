#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <ghostty/vt.h>

int main() {
  GhosttyMouseEncoder encoder;
  GhosttyResult result = ghostty_mouse_encoder_new(NULL, &encoder);
  assert(result == GHOSTTY_SUCCESS);

  // Set tracking mode to normal (button press/release)
  ghostty_mouse_encoder_setopt(encoder, GHOSTTY_MOUSE_ENCODER_OPT_EVENT,
                               &(GhosttyMouseTrackingMode){GHOSTTY_MOUSE_TRACKING_NORMAL});

  // Set output format to SGR
  ghostty_mouse_encoder_setopt(encoder, GHOSTTY_MOUSE_ENCODER_OPT_FORMAT,
                               &(GhosttyMouseFormat){GHOSTTY_MOUSE_FORMAT_SGR});

  // Set terminal geometry so the encoder can map pixel positions to cells
  ghostty_mouse_encoder_setopt(encoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE,
                               &(GhosttyMouseEncoderSize){
                                   .size = sizeof(GhosttyMouseEncoderSize),
                                   .screen_width = 800,
                                   .screen_height = 600,
                                   .cell_width = 10,
                                   .cell_height = 20,
                                   .padding_top = 0,
                                   .padding_bottom = 0,
                                   .padding_right = 0,
                                   .padding_left = 0,
                               });

  // Create mouse event: left button press at pixel position (50, 40)
  GhosttyMouseEvent event;
  result = ghostty_mouse_event_new(NULL, &event);
  assert(result == GHOSTTY_SUCCESS);
  ghostty_mouse_event_set_action(event, GHOSTTY_MOUSE_ACTION_PRESS);
  ghostty_mouse_event_set_button(event, GHOSTTY_MOUSE_BUTTON_LEFT);
  ghostty_mouse_event_set_position(event, (GhosttyMousePosition){.x = 50.0f, .y = 40.0f});
  printf("Encoding event: left button press at (50, 40) in SGR format\n");

  // Optionally, encode with null buffer to get required size. You can
  // skip this step and provide a sufficiently large buffer directly.
  // If there isn't enough space, the function will return an out of memory
  // error.
  size_t required = 0;
  result = ghostty_mouse_encoder_encode(encoder, event, NULL, 0, &required);
  assert(result == GHOSTTY_OUT_OF_MEMORY);
  printf("Required buffer size: %zu bytes\n", required);

  // Encode the mouse event. We don't use our required size above because
  // that was just an example; we know 128 bytes is enough.
  char buf[128];
  size_t written = 0;
  result = ghostty_mouse_encoder_encode(encoder, event, buf, sizeof(buf), &written);
  assert(result == GHOSTTY_SUCCESS);
  printf("Encoded %zu bytes\n", written);

  // Print the encoded sequence (hex and string)
  printf("Hex: ");
  for (size_t i = 0; i < written; i++) printf("%02x ", (unsigned char)buf[i]);
  printf("\n");

  printf("String: ");
  for (size_t i = 0; i < written; i++) {
    if (buf[i] == 0x1b) {
      printf("\\x1b");
    } else {
      printf("%c", buf[i]);
    }
  }
  printf("\n");

  ghostty_mouse_event_free(event);
  ghostty_mouse_encoder_free(encoder);
  return 0;
}
