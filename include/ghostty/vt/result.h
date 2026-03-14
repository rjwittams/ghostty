/**
 * @file result.h
 *
 * Result codes for libghostty-vt operations.
 */

#ifndef GHOSTTY_VT_RESULT_H
#define GHOSTTY_VT_RESULT_H

/**
 * Result codes for libghostty-vt operations.
 */
typedef enum {
    /** Operation completed successfully */
    GHOSTTY_SUCCESS = 0,
    /** Operation failed due to failed allocation */
    GHOSTTY_OUT_OF_MEMORY = -1,
    /** Operation failed due to invalid value */
    GHOSTTY_INVALID_VALUE = -2,
    /** Operation failed because the provided buffer was too small */
    GHOSTTY_OUT_OF_SPACE = -3,
} GhosttyResult;

#endif /* GHOSTTY_VT_RESULT_H */
