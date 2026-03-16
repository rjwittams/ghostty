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

/** @name ANSI Mode Tags
 * Mode tags for standard ANSI modes.
 * @{
 */
#define GHOSTTY_MODE_KAM              (ghostty_mode_tag_new(2, true))    /**< Keyboard action (disable keyboard) */
#define GHOSTTY_MODE_INSERT           (ghostty_mode_tag_new(4, true))    /**< Insert mode */
#define GHOSTTY_MODE_SRM              (ghostty_mode_tag_new(12, true))   /**< Send/receive mode */
#define GHOSTTY_MODE_LINEFEED         (ghostty_mode_tag_new(20, true))   /**< Linefeed/new line mode */
/** @} */

/** @name DEC Private Mode Tags
 * Mode tags for DEC private modes (?-prefixed).
 * @{
 */
#define GHOSTTY_MODE_DECCKM           (ghostty_mode_tag_new(1, false))   /**< Cursor keys */
#define GHOSTTY_MODE_132_COLUMN       (ghostty_mode_tag_new(3, false))   /**< 132/80 column mode */
#define GHOSTTY_MODE_SLOW_SCROLL      (ghostty_mode_tag_new(4, false))   /**< Slow scroll */
#define GHOSTTY_MODE_REVERSE_COLORS   (ghostty_mode_tag_new(5, false))   /**< Reverse video */
#define GHOSTTY_MODE_ORIGIN           (ghostty_mode_tag_new(6, false))   /**< Origin mode */
#define GHOSTTY_MODE_WRAPAROUND       (ghostty_mode_tag_new(7, false))   /**< Auto-wrap mode */
#define GHOSTTY_MODE_AUTOREPEAT       (ghostty_mode_tag_new(8, false))   /**< Auto-repeat keys */
#define GHOSTTY_MODE_X10_MOUSE        (ghostty_mode_tag_new(9, false))   /**< X10 mouse reporting */
#define GHOSTTY_MODE_CURSOR_BLINKING  (ghostty_mode_tag_new(12, false))  /**< Cursor blink */
#define GHOSTTY_MODE_CURSOR_VISIBLE   (ghostty_mode_tag_new(25, false))  /**< Cursor visible (DECTCEM) */
#define GHOSTTY_MODE_ENABLE_MODE_3    (ghostty_mode_tag_new(40, false))  /**< Allow 132 column mode */
#define GHOSTTY_MODE_REVERSE_WRAP     (ghostty_mode_tag_new(45, false))  /**< Reverse wrap */
#define GHOSTTY_MODE_ALT_SCREEN_LEGACY (ghostty_mode_tag_new(47, false)) /**< Alternate screen (legacy) */
#define GHOSTTY_MODE_KEYPAD_KEYS      (ghostty_mode_tag_new(66, false))  /**< Application keypad */
#define GHOSTTY_MODE_LEFT_RIGHT_MARGIN (ghostty_mode_tag_new(69, false)) /**< Left/right margin mode */
#define GHOSTTY_MODE_NORMAL_MOUSE     (ghostty_mode_tag_new(1000, false)) /**< Normal mouse tracking */
#define GHOSTTY_MODE_BUTTON_MOUSE     (ghostty_mode_tag_new(1002, false)) /**< Button-event mouse tracking */
#define GHOSTTY_MODE_ANY_MOUSE        (ghostty_mode_tag_new(1003, false)) /**< Any-event mouse tracking */
#define GHOSTTY_MODE_FOCUS_EVENT      (ghostty_mode_tag_new(1004, false)) /**< Focus in/out events */
#define GHOSTTY_MODE_UTF8_MOUSE       (ghostty_mode_tag_new(1005, false)) /**< UTF-8 mouse format */
#define GHOSTTY_MODE_SGR_MOUSE        (ghostty_mode_tag_new(1006, false)) /**< SGR mouse format */
#define GHOSTTY_MODE_ALT_SCROLL       (ghostty_mode_tag_new(1007, false)) /**< Alternate scroll mode */
#define GHOSTTY_MODE_URXVT_MOUSE      (ghostty_mode_tag_new(1015, false)) /**< URxvt mouse format */
#define GHOSTTY_MODE_SGR_PIXELS_MOUSE (ghostty_mode_tag_new(1016, false)) /**< SGR-Pixels mouse format */
#define GHOSTTY_MODE_NUMLOCK_KEYPAD   (ghostty_mode_tag_new(1035, false)) /**< Ignore keypad with NumLock */
#define GHOSTTY_MODE_ALT_ESC_PREFIX   (ghostty_mode_tag_new(1036, false)) /**< Alt key sends ESC prefix */
#define GHOSTTY_MODE_ALT_SENDS_ESC    (ghostty_mode_tag_new(1039, false)) /**< Alt sends escape */
#define GHOSTTY_MODE_REVERSE_WRAP_EXT (ghostty_mode_tag_new(1045, false)) /**< Extended reverse wrap */
#define GHOSTTY_MODE_ALT_SCREEN       (ghostty_mode_tag_new(1047, false)) /**< Alternate screen */
#define GHOSTTY_MODE_SAVE_CURSOR      (ghostty_mode_tag_new(1048, false)) /**< Save cursor (DECSC) */
#define GHOSTTY_MODE_ALT_SCREEN_SAVE  (ghostty_mode_tag_new(1049, false)) /**< Alt screen + save cursor + clear */
#define GHOSTTY_MODE_BRACKETED_PASTE  (ghostty_mode_tag_new(2004, false)) /**< Bracketed paste mode */
#define GHOSTTY_MODE_SYNC_OUTPUT      (ghostty_mode_tag_new(2026, false)) /**< Synchronized output */
#define GHOSTTY_MODE_GRAPHEME_CLUSTER (ghostty_mode_tag_new(2027, false)) /**< Grapheme cluster mode */
#define GHOSTTY_MODE_COLOR_SCHEME_REPORT (ghostty_mode_tag_new(2031, false)) /**< Report color scheme */
#define GHOSTTY_MODE_IN_BAND_RESIZE   (ghostty_mode_tag_new(2048, false)) /**< In-band size reports */
/** @} */

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
