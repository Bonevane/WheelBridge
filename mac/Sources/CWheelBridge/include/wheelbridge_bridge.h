/*
 * The shared memory contract between the Windows proxy and the macOS helper.
 *
 * This one header is compiled by both sides, as 32-bit and 64-bit Windows code
 * and as arm64 macOS code, so every field has a fixed width and explicit
 * padding. The static asserts below fail the build if a layout ever differs.
 *
 * Each block has a single writer and is guarded by a seqlock. The counter is
 * odd while the writer is updating, and readers retry until they see the same
 * even value before and after copying. Neither side ever waits on the other,
 * so a stalled helper cannot freeze a game's frame.
 *
 * Liveness uses counters, not clocks. Each side bumps its tick, and the other
 * watches for it to change, so nothing depends on two clocks agreeing.
 */
#ifndef WHEELBRIDGE_BRIDGE_H
#define WHEELBRIDGE_BRIDGE_H

#include <stdint.h>
#include <string.h>

#define WB_MAGIC 0x31425757u /* "WWB1" */
#define WB_VERSION 1u
#define WB_FILE_SIZE 8192u
#define WB_MAX_EFFECTS 32u
#define WB_NAME_BYTES 64u

/* The game has stopped updating if its tick is unchanged for this long. */
#define WB_STALE_MS 500u

typedef enum {
    WB_EFFECT_NONE = 0,
    WB_EFFECT_CONSTANT = 1,
    WB_EFFECT_RAMP = 2,
    WB_EFFECT_SQUARE = 3,
    WB_EFFECT_SINE = 4,
    WB_EFFECT_TRIANGLE = 5,
    WB_EFFECT_SAW_UP = 6,
    WB_EFFECT_SAW_DOWN = 7,
    WB_EFFECT_SPRING = 8,
    WB_EFFECT_DAMPER = 9,
    WB_EFFECT_INERTIA = 10,
    WB_EFFECT_FRICTION = 11
} wb_effect_kind;

/* Same values as DIEFF_CARTESIAN, DIEFF_POLAR and DIEFF_SPHERICAL. */
#define WB_COORD_CARTESIAN 0x10u
#define WB_COORD_POLAR 0x20u
#define WB_COORD_SPHERICAL 0x40u

#define WB_GAME_PAUSED 1u
#define WB_GAME_ACTUATORS_OFF 2u
#define WB_GAME_AUTOCENTER 4u

#define WB_HAT_CENTRED 8u

/* Written by the helper. Axes run 0...65535, in the wheel's own polarity. */
typedef struct {
    uint32_t seq;
    uint32_t tick;
    uint32_t connected;
    uint32_t vendor_product; /* (product << 16) | vendor, as in a DirectInput product GUID */
    uint32_t steering;
    uint32_t throttle;
    uint32_t brake;
    uint32_t clutch;
    uint32_t buttons;
    uint32_t hat; /* 0...7 clockwise from north, or WB_HAT_CENTRED */
    char name[WB_NAME_BYTES];
} wb_input;

/*
 * One DirectInput effect, mirrored as the game set it. All interpretation lives
 * in the helper's effect engine, where it can be tested without Windows.
 *
 * params by kind:
 *   constant   [0] magnitude
 *   ramp       [0] start, [1] end
 *   periodic   [0] magnitude, [1] offset, [2] phase, [3] period in microseconds
 *   condition  [0] offset, [1] positive coefficient, [2] negative coefficient,
 *              [3] positive saturation, [4] negative saturation, [5] dead band
 */
typedef struct {
    uint32_t kind;
    uint32_t playing;
    uint32_t start_count; /* changes on every Start, so a restart is never missed */
    uint32_t iterations;
    uint32_t duration_us; /* 0xffffffff means infinite */
    uint32_t start_delay_us;
    uint32_t gain;
    uint32_t coords;
    uint32_t axis_count;
    uint32_t x_axis_index; /* which entry of the game's axis list is the wheel */
    int32_t direction[2];
    uint32_t has_envelope;
    uint32_t attack_level;
    uint32_t attack_time_us;
    uint32_t fade_level;
    uint32_t fade_time_us;
    int32_t params[6];
    uint32_t reserved;
} wb_effect;

/* Written by whichever game process owns the wheel. */
typedef struct {
    uint32_t seq;
    uint32_t tick;
    uint32_t owner_pid; /* 0 when no game owns the wheel */
    uint32_t gain;      /* device gain, 0...10000 */
    uint32_t flags;
    uint32_t effect_count;
    uint32_t reserved[2];
    char game_name[WB_NAME_BYTES];
    wb_effect effects[WB_MAX_EFFECTS];
} wb_game;

/* Written by the app, and read by the helper. */
typedef struct {
    uint32_t seq;
    uint32_t revision;
    uint32_t range_degrees;
    uint32_t strength; /* 0...100 */
    uint32_t centering; /* 0...100, a spring for games that have no forces of their own */
    uint32_t reverse;
    uint32_t motor_stopped; /* the user pressed Stop Motor */
    uint32_t reserved;
} wb_settings;

/* Written by the helper, and read by the app. */
typedef struct {
    uint32_t seq;
    uint32_t tick;
    uint32_t wheel_state; /* wb_wheel_state */
    uint32_t game_connected;
    uint32_t active_effects;
    uint32_t loop_hz;
    int32_t torque_permille; /* -1000...1000, after every limit */
    uint32_t clip_permille;  /* share of recent samples that hit full torque */
    uint32_t hid_failures;
    uint32_t reserved;
    char game_name[WB_NAME_BYTES];
} wb_status;

typedef enum {
    WB_WHEEL_MISSING = 0,
    WB_WHEEL_SWITCHING = 1, /* found in compatibility mode, switching to native */
    WB_WHEEL_READY = 2,
    WB_WHEEL_OPEN_FAILED = 3,
    WB_WHEEL_CLAIMED = 4 /* another driver is blocking it */
} wb_wheel_state;

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t size;
    uint32_t helper_pid;
    uint32_t pad0[12];
    wb_input input;
    wb_settings settings;
    wb_status status;
    wb_game game;
} wb_bridge;

#if defined(__cplusplus)
#define WB_STATIC_ASSERT static_assert
#else
#define WB_STATIC_ASSERT _Static_assert
#endif

WB_STATIC_ASSERT(sizeof(wb_input) == 104, "wb_input layout");
WB_STATIC_ASSERT(sizeof(wb_effect) == 96, "wb_effect layout");
WB_STATIC_ASSERT(sizeof(wb_settings) == 32, "wb_settings layout");
WB_STATIC_ASSERT(sizeof(wb_status) == 104, "wb_status layout");
WB_STATIC_ASSERT(sizeof(wb_game) == 96 + 96 * WB_MAX_EFFECTS, "wb_game layout");
WB_STATIC_ASSERT(sizeof(wb_bridge) <= WB_FILE_SIZE, "wb_bridge fits the file");

/* The seqlock. `block` is any struct above, whose first field is `seq`. */
static inline void wb_write_begin(uint32_t *seq) {
    uint32_t next = __atomic_load_n(seq, __ATOMIC_RELAXED) + 1u;
    __atomic_store_n(seq, next | 1u, __ATOMIC_RELAXED);
    __atomic_thread_fence(__ATOMIC_RELEASE);
}

static inline void wb_write_end(uint32_t *seq) {
    uint32_t odd = __atomic_load_n(seq, __ATOMIC_RELAXED);
    __atomic_store_n(seq, (odd | 1u) + 1u, __ATOMIC_RELEASE);
}

/* Copies `size` bytes into `out`. Returns 0 if the writer kept it busy, which
 * callers must treat as "no news", not as the writer having gone. The attempts
 * are bounded because neither side may ever wait on the other. */
static inline int wb_read(const void *block, void *out, size_t size) {
    const uint32_t *seq = (const uint32_t *)block;
    for (int attempt = 0; attempt < 1024; attempt++) {
        uint32_t before = __atomic_load_n(seq, __ATOMIC_ACQUIRE);
        if (before & 1u) {
            continue;
        }
        memcpy(out, block, size);
        __atomic_thread_fence(__ATOMIC_ACQUIRE);
        if (__atomic_load_n(seq, __ATOMIC_RELAXED) == before) {
            return 1;
        }
    }
    return 0;
}

/* Publishes `value` over `block`, leaving the block's own seq in charge. */
static inline void wb_write(void *block, const void *value, size_t size) {
    uint32_t *seq = (uint32_t *)block;
    wb_write_begin(seq);
    memcpy((char *)block + sizeof(uint32_t), (const char *)value + sizeof(uint32_t),
           size - sizeof(uint32_t));
    wb_write_end(seq);
}

#endif
