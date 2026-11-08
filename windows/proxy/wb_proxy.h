/* Internal declarations for the dinput8.dll proxy. */
#ifndef WB_PROXY_H
#define WB_PROXY_H

#define CINTERFACE
#define COBJMACROS
#define DIRECTINPUT_VERSION 0x0800
#define WIN32_LEAN_AND_MEAN

#include <windows.h>
#include <dinput.h>

#include "wheelbridge_bridge.h"

/* Axes, then buttons, then the hat. The order matches a real G29 under Windows,
 * so games' built-in presets find what they expect. */
#define WB_AXES 4
#define WB_BUTTONS 25
#define WB_OBJECTS (WB_AXES + WB_BUTTONS + 1)
#define WB_POV_INDEX (WB_AXES + WB_BUTTONS)

typedef struct wb_effect_object wb_effect_object;

typedef struct wb_device {
    const void *vtbl;
    LONG refs;
    int wide;
    CRITICAL_SECTION lock;

    /* Identity, fixed when the device is created. */
    GUID product;
    char name[WB_NAME_BYTES];

    /* Where each object lands in the game's data format, or -1. */
    int has_format;
    DWORD format_size;
    LONG offsets[WB_OBJECTS];
    DWORD extra_povs[8];
    int extra_pov_count;

    LONG range_min[WB_AXES];
    LONG range_max[WB_AXES];
    DWORD dead_zone[WB_AXES];
    DWORD saturation[WB_AXES];

    /* Buffered input. Empty until the game asks for a buffer. */
    DIDEVICEOBJECTDATA *events;
    DWORD event_capacity;
    DWORD event_head;
    DWORD event_count;
    DWORD event_sequence;
    LONG last_values[WB_OBJECTS];
    int has_last_values;

    int acquired;
    DWORD gain;
    DWORD ff_flags; /* WB_GAME_* */

    wb_game game; /* our copy of what the helper sees */
    wb_effect_object *slots[WB_MAX_EFFECTS];
} wb_device;

/* bridge.c */
void wb_log(const char *format, ...);
wb_bridge *wb_bridge_get(void);
int wb_bridge_input(wb_input *out);
int wb_wheel_available(wb_input *out);
const char *wb_module_dir(void);
void wb_set_module(HMODULE module);

/* proxy.c */
HMODULE wb_real_dinput8(void);

/* device.c */
extern const GUID wb_instance_guid;
void wb_product_guid(const wb_input *input, GUID *out);
void wb_fill_instance(const wb_input *input, void *out, int wide);
HRESULT wb_device_create(int wide, const wb_input *input, void **out);
void wb_device_publish(wb_device *device);
DWORD wb_device_type(void);

/* effect.c */
HRESULT wb_effect_create(wb_device *device, REFGUID guid, LPCDIEFFECT params, LPDIRECTINPUTEFFECT *out);
HRESULT wb_effect_enum(wb_device *device, void *callback, void *context, DWORD type);
HRESULT wb_effect_info(wb_device *device, void *out, REFGUID guid);
void wb_effect_stop_all(wb_device *device);
void wb_effect_detach_all(wb_device *device);
HRESULT wb_effect_enum_created(wb_device *device, LPDIENUMCREATEDEFFECTOBJECTSCALLBACK callback, void *context);

#endif
