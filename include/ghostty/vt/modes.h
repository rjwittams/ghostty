/**
 * @file modes.h
 *
 * Terminal mode tag utilities - pack and unpack ANSI/DEC mode identifiers.
 */

#ifndef GHOSTTY_VT_MODES_H
#define GHOSTTY_VT_MODES_H

/** @defgroup modes Mode Utilities
 *
 * Utilities for working with terminal mode tags. A mode tag is a compact
 * 16-bit representation of a terminal mode identifier that encodes both
 * the numeric mode value (up to 15 bits) and whether the mode is an ANSI
 * mode or a DEC private mode (?-prefixed).
 *
 * The packed layout (least-significant bit first) is:
 * - Bits 0–14: mode value (u15)
 * - Bit 15: ANSI flag (0 = DEC private mode, 1 = ANSI mode)
 *
 * ## Example
 *
 * @code{.c}
 * #include <stdio.h>
 * #include <ghostty/vt.h>
 *
 * int main() {
 *   // Create a tag for DEC mode 25 (cursor visible)
 *   GhosttyModeTag tag = ghostty_mode_tag_new(25, false);
 *   printf("value=%u ansi=%d packed=0x%04x\n",
 *       ghostty_mode_tag_value(tag),
 *       ghostty_mode_tag_ansi(tag),
 *       tag);
 *
 *   // Create a tag for ANSI mode 4 (insert mode)
 *   GhosttyModeTag ansi_tag = ghostty_mode_tag_new(4, true);
 *   printf("value=%u ansi=%d packed=0x%04x\n",
 *       ghostty_mode_tag_value(ansi_tag),
 *       ghostty_mode_tag_ansi(ansi_tag),
 *       ansi_tag);
 *
 *   return 0;
 * }
 * @endcode
 *
 * @{
 */

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * A packed 16-bit terminal mode tag.
 *
 * Encodes a mode value (bits 0–14) and an ANSI flag (bit 15) into a
 * single 16-bit integer. Use the inline helper functions to construct
 * and inspect mode tags rather than manipulating bits directly.
 */
typedef uint16_t GhosttyModeTag;

/**
 * Create a mode tag from a mode value and ANSI flag.
 *
 * @param value The numeric mode value (0–32767)
 * @param ansi true for an ANSI mode, false for a DEC private mode
 * @return The packed mode tag
 *
 * @ingroup modes
 */
static inline GhosttyModeTag ghostty_mode_tag_new(uint16_t value, bool ansi) {
    return (GhosttyModeTag)((value & 0x7FFF) | ((uint16_t)ansi << 15));
}

/**
 * Extract the numeric mode value from a mode tag.
 *
 * @param tag The mode tag
 * @return The mode value (0–32767)
 *
 * @ingroup modes
 */
static inline uint16_t ghostty_mode_tag_value(GhosttyModeTag tag) {
    return tag & 0x7FFF;
}

/**
 * Check whether a mode tag represents an ANSI mode.
 *
 * @param tag The mode tag
 * @return true if this is an ANSI mode, false if it is a DEC private mode
 *
 * @ingroup modes
 */
static inline bool ghostty_mode_tag_ansi(GhosttyModeTag tag) {
    return (tag >> 15) != 0;
}

#ifdef __cplusplus
}
#endif

/** @} */

#endif /* GHOSTTY_VT_MODES_H */
