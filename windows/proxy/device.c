/*
 * The virtual wheel: IDirectInputDevice8 fed by the helper.
 *
 * Reading the wheel on the Mac side and presenting it here, instead of relying
 * on Wine's copy, means input keeps working when CrossOver, SDL or macOS change
 * how the real device reaches the bottle. That is what broke on macOS 27.
 */
#include "wb_proxy.h"

#include <stdio.h>

const GUID wb_instance_guid = {0x57424c47, 0x2900, 0x4001, {0x80, 0x01, 0x57, 0x42, 0x52, 0x47, 0x00, 0x01}};

typedef struct {
    const GUID *guid;
    DWORD instance;
    DWORD default_offset;
    const char *name;
} axis_info;

/* Instances follow HID usage order, which game presets store: X, Y, Rz, Slider. */
static const axis_info axes[WB_AXES] = {
    {&GUID_XAxis, 0, 0, "Wheel"},
    {&GUID_YAxis, 1, 4, "Accelerator"},
    {&GUID_RzAxis, 5, 20, "Brake"},
    {&GUID_Slider, 6, 24, "Clutch"},
};

#define DEFAULT_POV_OFFSET 32u
#define DEFAULT_BUTTON_OFFSET 48u

#define DEVICE(this) ((wb_device *)(this))

static int is_axis(int object) { return object < WB_AXES; }
static int is_button(int object) { return object >= WB_AXES && object < WB_POV_INDEX; }

static DWORD object_type(int object) {
    if (is_axis(object)) {
        DWORD type = DIDFT_ABSAXIS | DIDFT_MAKEINSTANCE(axes[object].instance);
        return object == 0 ? type | DIDFT_FFACTUATOR : type;
    }
    if (is_button(object)) {
        return DIDFT_PSHBUTTON | DIDFT_MAKEINSTANCE(object - WB_AXES);
    }
    return DIDFT_POV | DIDFT_MAKEINSTANCE(0);
}

static const GUID *object_guid(int object) {
    if (is_axis(object)) {
        return axes[object].guid;
    }
    return is_button(object) ? &GUID_Button : &GUID_POV;
}

static DWORD default_offset(int object) {
    if (is_axis(object)) {
        return axes[object].default_offset;
    }
    return is_button(object) ? DEFAULT_BUTTON_OFFSET + (DWORD)(object - WB_AXES) : DEFAULT_POV_OFFSET;
}

static void object_name(int object, char *out, size_t size) {
    if (is_axis(object)) {
        snprintf(out, size, "%s", axes[object].name);
    } else if (is_button(object)) {
        snprintf(out, size, "Button %d", object - WB_AXES + 1);
    } else {
        snprintf(out, size, "Hat");
    }
}

static DWORD current_offset(const wb_device *d, int object) {
    return d->has_format && d->offsets[object] >= 0 ? (DWORD)d->offsets[object] : default_offset(object);
}

DWORD wb_device_type(void) {
    return DIDEVTYPE_HID | (DI8DEVTYPEDRIVING_THREEPEDALS << 8) | DI8DEVTYPE_DRIVING;
}

/* Windows builds a product GUID from the USB IDs, and games match on it. */
void wb_product_guid(const wb_input *input, GUID *out) {
    static const GUID base = {0, 0, 0, {0, 0, 'P', 'I', 'D', 'V', 'I', 'D'}};
    *out = base;
    out->Data1 = input->vendor_product;
}

void wb_fill_instance(const wb_input *input, void *out, int wide) {
    char name[WB_NAME_BYTES + 1];
    memcpy(name, input->name, WB_NAME_BYTES);
    name[WB_NAME_BYTES] = 0;
    if (wide) {
        DIDEVICEINSTANCEW *info = out;
        DWORD size = info->dwSize;
        memset(info, 0, size);
        info->dwSize = size;
        info->guidInstance = wb_instance_guid;
        wb_product_guid(input, &info->guidProduct);
        info->dwDevType = wb_device_type();
        MultiByteToWideChar(CP_UTF8, 0, name, -1, info->tszInstanceName, MAX_PATH);
        MultiByteToWideChar(CP_UTF8, 0, name, -1, info->tszProductName, MAX_PATH);
        if (size >= sizeof(DIDEVICEINSTANCEW)) {
            info->guidFFDriver = wb_instance_guid;
            info->wUsagePage = 1;
            info->wUsage = 4;
        }
    } else {
        DIDEVICEINSTANCEA *info = out;
        DWORD size = info->dwSize;
        memset(info, 0, size);
        info->dwSize = size;
        info->guidInstance = wb_instance_guid;
        wb_product_guid(input, &info->guidProduct);
        info->dwDevType = wb_device_type();
        snprintf(info->tszInstanceName, MAX_PATH, "%s", name);
        snprintf(info->tszProductName, MAX_PATH, "%s", name);
        if (size >= sizeof(DIDEVICEINSTANCEA)) {
            info->guidFFDriver = wb_instance_guid;
            info->wUsagePage = 1;
            info->wUsage = 4;
        }
    }
}

static wb_input current_identity(const wb_device *d) {
    wb_input input;
    memset(&input, 0, sizeof(input));
    input.vendor_product = d->product.Data1;
    memcpy(input.name, d->name, WB_NAME_BYTES);
    return input;
}

/* Publishes this device's state, unless another game has since taken the wheel. */
void wb_device_publish(wb_device *d) {
    wb_bridge *bridge = wb_bridge_get();
    if (!bridge || !d->acquired) {
        return;
    }
    uint32_t me = GetCurrentProcessId();
    if (__atomic_load_n(&bridge->game.owner_pid, __ATOMIC_RELAXED) != me) {
        return;
    }
    d->game.tick++;
    d->game.owner_pid = me;
    d->game.gain = d->gain;
    d->game.flags = d->ff_flags;
    wb_write(&bridge->game, &d->game, sizeof(d->game));
}

static void release_wheel(wb_device *d) {
    wb_bridge *bridge = wb_bridge_get();
    if (!bridge) {
        return;
    }
    uint32_t me = GetCurrentProcessId();
    if (__atomic_load_n(&bridge->game.owner_pid, __ATOMIC_RELAXED) == me) {
        wb_effect_stop_all(d);
        d->game.tick++;
        d->game.owner_pid = 0;
        wb_write(&bridge->game, &d->game, sizeof(d->game));
    }
}

/* Axes run in the game's own range. Pedals rest high, as on a real G29. */
static LONG axis_value(const wb_device *d, int axis, uint32_t raw) {
    LONGLONG span = (LONGLONG)d->range_max[axis] - d->range_min[axis];
    return (LONG)(d->range_min[axis] + span * raw / 65535);
}

static void read_values(wb_device *d, LONG values[WB_OBJECTS]) {
    wb_input input;
    int live = wb_bridge_input(&input) && input.connected;
    if (!live) {
        /* Centred and released, so a lost helper never leaves a pedal pressed. */
        memset(&input, 0, sizeof(input));
        input.steering = 32768;
        input.throttle = input.brake = input.clutch = 65535;
        input.hat = WB_HAT_CENTRED;
    }
    values[0] = axis_value(d, 0, input.steering);
    values[1] = axis_value(d, 1, input.throttle);
    values[2] = axis_value(d, 2, input.brake);
    values[3] = axis_value(d, 3, input.clutch);
    for (int i = 0; i < WB_BUTTONS; i++) {
        values[WB_AXES + i] = (input.buttons >> i) & 1 ? 0x80 : 0;
    }
    values[WB_POV_INDEX] = input.hat < 8 ? (LONG)(input.hat * 4500) : -1;
}

static void queue_event(wb_device *d, int object, LONG value) {
    if (!d->event_capacity || d->offsets[object] < 0) {
        return;
    }
    DWORD index = (d->event_head + d->event_count) % d->event_capacity;
    if (d->event_count == d->event_capacity) {
        d->event_head = (d->event_head + 1) % d->event_capacity; /* drop the oldest */
    } else {
        d->event_count++;
    }
    DIDEVICEOBJECTDATA *event = &d->events[index];
    memset(event, 0, sizeof(*event));
    event->dwOfs = (DWORD)d->offsets[object];
    event->dwData = (DWORD)value;
    event->dwTimeStamp = GetTickCount();
    event->dwSequence = ++d->event_sequence;
}

/* One read of the wheel. It doubles as the game's heartbeat to the helper. */
static void sample(wb_device *d, LONG values[WB_OBJECTS]) {
    read_values(d, values);
    if (d->has_last_values) {
        for (int i = 0; i < WB_OBJECTS; i++) {
            if (values[i] != d->last_values[i]) {
                queue_event(d, i, values[i]);
            }
        }
    }
    memcpy(d->last_values, values, sizeof(d->last_values));
    d->has_last_values = 1;
    wb_device_publish(d);
}

static HRESULT STDMETHODCALLTYPE device_query(IDirectInputDevice8W *this, REFIID iid, void **out) {
    wb_device *d = DEVICE(this);
    if (!out) {
        return E_POINTER;
    }
    if (IsEqualGUID(iid, &IID_IUnknown) || IsEqualGUID(iid, d->wide ? &IID_IDirectInputDevice8W : &IID_IDirectInputDevice8A)) {
        InterlockedIncrement(&d->refs);
        *out = this;
        return S_OK;
    }
    *out = NULL;
    return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE device_add_ref(IDirectInputDevice8W *this) {
    return InterlockedIncrement(&DEVICE(this)->refs);
}

static ULONG STDMETHODCALLTYPE device_release(IDirectInputDevice8W *this) {
    wb_device *d = DEVICE(this);
    ULONG refs = InterlockedDecrement(&d->refs);
    if (refs) {
        return refs;
    }
    EnterCriticalSection(&d->lock);
    release_wheel(d);
    wb_effect_detach_all(d);
    LeaveCriticalSection(&d->lock);
    DeleteCriticalSection(&d->lock);
    if (d->events) {
        HeapFree(GetProcessHeap(), 0, d->events);
    }
    HeapFree(GetProcessHeap(), 0, d);
    return 0;
}

static HRESULT STDMETHODCALLTYPE device_caps(IDirectInputDevice8W *this, LPDIDEVCAPS caps) {
    (void)this;
    if (!caps) {
        return E_POINTER;
    }
    if (caps->dwSize != sizeof(DIDEVCAPS) && caps->dwSize != sizeof(DIDEVCAPS_DX3)) {
        return DIERR_INVALIDPARAM;
    }
    DWORD size = caps->dwSize;
    memset(caps, 0, size);
    caps->dwSize = size;
    /* Polled, so that games keep calling us: those calls are the heartbeat. */
    caps->dwFlags = DIDC_ATTACHED | DIDC_POLLEDDEVICE | DIDC_POLLEDDATAFORMAT | DIDC_FORCEFEEDBACK |
                    DIDC_FFATTACK | DIDC_FFFADE | DIDC_SATURATION | DIDC_POSNEGCOEFFICIENTS |
                    DIDC_POSNEGSATURATION | DIDC_DEADBAND | DIDC_STARTDELAY;
    caps->dwDevType = wb_device_type();
    caps->dwAxes = WB_AXES;
    caps->dwButtons = WB_BUTTONS;
    caps->dwPOVs = 1;
    if (size == sizeof(DIDEVCAPS)) {
        caps->dwFFSamplePeriod = 2000;
        caps->dwFFMinTimeResolution = 2000;
    }
    return DI_OK;
}

static int enum_wanted(int object, DWORD flags) {
    if (flags == DIDFT_ALL) {
        return 1;
    }
    DWORD type = object_type(object);
    if ((flags & DIDFT_FFACTUATOR) && !(type & DIDFT_FFACTUATOR)) {
        return 0;
    }
    DWORD kinds = DIDFT_GETTYPE(flags);
    return !kinds || (DIDFT_GETTYPE(type) & kinds);
}

static void fill_object_common(const wb_device *d, int object, DIDEVICEOBJECTINSTANCEW *out) {
    /* The A struct shares this layout up to tszName, and the rest is set per width. */
    out->guidType = *object_guid(object);
    out->dwOfs = current_offset(d, object);
    out->dwType = object_type(object);
    out->dwFlags = object == 0 ? DIDOI_FFACTUATOR | DIDOI_ASPECTPOSITION : is_axis(object) ? DIDOI_ASPECTPOSITION : 0;
}

static void fill_object_w(const wb_device *d, int object, DIDEVICEOBJECTINSTANCEW *out) {
    DWORD size = out->dwSize;
    char name[MAX_PATH];
    memset(out, 0, size);
    out->dwSize = size;
    fill_object_common(d, object, out);
    object_name(object, name, sizeof(name));
    MultiByteToWideChar(CP_ACP, 0, name, -1, out->tszName, MAX_PATH);
    if (size >= sizeof(*out)) {
        out->dwFFMaxForce = object == 0 ? DI_FFNOMINALMAX : 0;
        out->dwFFForceResolution = object == 0 ? 1 : 0;
        out->wUsagePage = is_button(object) ? 9 : 1;
    }
}

static void fill_object_a(const wb_device *d, int object, DIDEVICEOBJECTINSTANCEA *out) {
    DWORD size = out->dwSize;
    memset(out, 0, size);
    out->dwSize = size;
    fill_object_common(d, object, (DIDEVICEOBJECTINSTANCEW *)out);
    object_name(object, out->tszName, MAX_PATH);
    if (size >= sizeof(*out)) {
        out->dwFFMaxForce = object == 0 ? DI_FFNOMINALMAX : 0;
        out->dwFFForceResolution = object == 0 ? 1 : 0;
        out->wUsagePage = is_button(object) ? 9 : 1;
    }
}

static HRESULT STDMETHODCALLTYPE device_enum_objects(IDirectInputDevice8W *this, LPDIENUMDEVICEOBJECTSCALLBACKW callback,
                                                     void *context, DWORD flags) {
    wb_device *d = DEVICE(this);
    if (!callback) {
        return DIERR_INVALIDPARAM;
    }
    for (int i = 0; i < WB_OBJECTS; i++) {
        if (!enum_wanted(i, flags)) {
            continue;
        }
        BOOL keep_going;
        if (d->wide) {
            DIDEVICEOBJECTINSTANCEW info = {.dwSize = sizeof(info)};
            fill_object_w(d, i, &info);
            keep_going = callback(&info, context);
        } else {
            DIDEVICEOBJECTINSTANCEA info = {.dwSize = sizeof(info)};
            fill_object_a(d, i, &info);
            keep_going = ((LPDIENUMDEVICEOBJECTSCALLBACKA)(void *)callback)(&info, context);
        }
        if (keep_going == DIENUM_STOP) {
            break;
        }
    }
    return DI_OK;
}

/* Finds the object a property or info call names, or -1. */
static int find_object(const wb_device *d, DWORD id, DWORD how) {
    for (int i = 0; i < WB_OBJECTS; i++) {
        if (how == DIPH_BYOFFSET && current_offset(d, i) == id) {
            return i;
        }
        if (how == DIPH_BYID && (object_type(i) & 0x00ffffffu & ~(DWORD)DIDFT_FFACTUATOR) ==
                                    (id & 0x00ffffffu & ~(DWORD)DIDFT_FFACTUATOR)) {
            return i;
        }
    }
    return -1;
}

static void copy_wide(WCHAR *out, const char *in) { MultiByteToWideChar(CP_UTF8, 0, in, -1, out, MAX_PATH); }

static HRESULT get_property(wb_device *d, REFGUID property, LPDIPROPHEADER header) {
    DIPROPDWORD *dword = (DIPROPDWORD *)header;
    int object = header->dwHow == DIPH_DEVICE ? -1 : find_object(d, header->dwObj, header->dwHow);
    uintptr_t id = (uintptr_t)property;

    if (id == (uintptr_t)DIPROP_RANGE || id == (uintptr_t)DIPROP_LOGICALRANGE || id == (uintptr_t)DIPROP_PHYSICALRANGE) {
        if (object < 0 || !is_axis(object)) {
            return DIERR_NOTFOUND;
        }
        DIPROPRANGE *range = (DIPROPRANGE *)header;
        range->lMin = id == (uintptr_t)DIPROP_RANGE ? d->range_min[object] : 0;
        range->lMax = id == (uintptr_t)DIPROP_RANGE ? d->range_max[object] : 65535;
        return DI_OK;
    }
    if (id == (uintptr_t)DIPROP_BUFFERSIZE) {
        dword->dwData = d->event_capacity;
    } else if (id == (uintptr_t)DIPROP_AXISMODE) {
        dword->dwData = DIPROPAXISMODE_ABS;
    } else if (id == (uintptr_t)DIPROP_GRANULARITY) {
        dword->dwData = 1;
    } else if (id == (uintptr_t)DIPROP_AUTOCENTER) {
        dword->dwData = d->ff_flags & WB_GAME_AUTOCENTER ? DIPROPAUTOCENTER_ON : DIPROPAUTOCENTER_OFF;
    } else if (id == (uintptr_t)DIPROP_FFGAIN) {
        dword->dwData = d->gain;
    } else if (id == (uintptr_t)DIPROP_FFLOAD) {
        dword->dwData = 0;
    } else if (id == (uintptr_t)DIPROP_DEADZONE) {
        dword->dwData = object >= 0 && is_axis(object) ? d->dead_zone[object] : 0;
    } else if (id == (uintptr_t)DIPROP_SATURATION) {
        dword->dwData = object >= 0 && is_axis(object) ? d->saturation[object] : 10000;
    } else if (id == (uintptr_t)DIPROP_CALIBRATIONMODE) {
        dword->dwData = DIPROPCALIBRATIONMODE_COOKED;
    } else if (id == (uintptr_t)DIPROP_JOYSTICKID) {
        dword->dwData = 0;
    } else if (id == (uintptr_t)DIPROP_VIDPID) {
        dword->dwData = d->product.Data1;
    } else if (id == (uintptr_t)DIPROP_PRODUCTNAME || id == (uintptr_t)DIPROP_INSTANCENAME) {
        copy_wide(((DIPROPSTRING *)header)->wsz, d->name);
    } else if (id == (uintptr_t)DIPROP_TYPENAME) {
        char type_name[32];
        snprintf(type_name, sizeof(type_name), "VID_%04lX&PID_%04lX", d->product.Data1 & 0xffff, d->product.Data1 >> 16);
        copy_wide(((DIPROPSTRING *)header)->wsz, type_name);
    } else if (id == (uintptr_t)DIPROP_GUIDANDPATH) {
        DIPROPGUIDANDPATH *path = (DIPROPGUIDANDPATH *)header;
        path->guidClass = wb_instance_guid;
        copy_wide(path->wszPath, "\\\\?\\wheelbridge#virtual#wheel");
    } else {
        return DIERR_UNSUPPORTED;
    }
    return DI_OK;
}

static HRESULT STDMETHODCALLTYPE device_get_property(IDirectInputDevice8W *this, REFGUID property, LPDIPROPHEADER header) {
    wb_device *d = DEVICE(this);
    if (!header) {
        return E_POINTER;
    }
    EnterCriticalSection(&d->lock);
    HRESULT result = get_property(d, property, header);
    LeaveCriticalSection(&d->lock);
    return result;
}

static HRESULT set_property(wb_device *d, REFGUID property, LPCDIPROPHEADER header) {
    const DIPROPDWORD *dword = (const DIPROPDWORD *)header;
    int all = header->dwHow == DIPH_DEVICE;
    int object = all ? -1 : find_object(d, header->dwObj, header->dwHow);
    uintptr_t id = (uintptr_t)property;

    if (id == (uintptr_t)DIPROP_RANGE) {
        const DIPROPRANGE *range = (const DIPROPRANGE *)header;
        for (int i = 0; i < WB_AXES; i++) {
            if (all || i == object) {
                d->range_min[i] = range->lMin;
                d->range_max[i] = range->lMax;
            }
        }
    } else if (id == (uintptr_t)DIPROP_DEADZONE || id == (uintptr_t)DIPROP_SATURATION) {
        DWORD *values = id == (uintptr_t)DIPROP_DEADZONE ? d->dead_zone : d->saturation;
        for (int i = 0; i < WB_AXES; i++) {
            if (all || i == object) {
                values[i] = dword->dwData;
            }
        }
    } else if (id == (uintptr_t)DIPROP_BUFFERSIZE) {
        DIDEVICEOBJECTDATA *events = NULL;
        if (dword->dwData) {
            events = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*events) * dword->dwData);
            if (!events) {
                return E_OUTOFMEMORY;
            }
        }
        if (d->events) {
            HeapFree(GetProcessHeap(), 0, d->events);
        }
        d->events = events;
        d->event_capacity = dword->dwData;
        d->event_head = d->event_count = 0;
    } else if (id == (uintptr_t)DIPROP_AUTOCENTER) {
        if (dword->dwData == DIPROPAUTOCENTER_ON) {
            d->ff_flags |= WB_GAME_AUTOCENTER;
        } else {
            d->ff_flags &= ~WB_GAME_AUTOCENTER;
        }
        wb_device_publish(d);
    } else if (id == (uintptr_t)DIPROP_FFGAIN) {
        d->gain = dword->dwData > 10000 ? 10000 : dword->dwData;
        wb_device_publish(d);
    } else if (id != (uintptr_t)DIPROP_AXISMODE && id != (uintptr_t)DIPROP_CALIBRATIONMODE) {
        return DIERR_UNSUPPORTED;
    }
    return DI_OK;
}

static HRESULT STDMETHODCALLTYPE device_set_property(IDirectInputDevice8W *this, REFGUID property, LPCDIPROPHEADER header) {
    wb_device *d = DEVICE(this);
    if (!header) {
        return E_POINTER;
    }
    EnterCriticalSection(&d->lock);
    HRESULT result = set_property(d, property, header);
    LeaveCriticalSection(&d->lock);
    return result;
}

static HRESULT STDMETHODCALLTYPE device_acquire(IDirectInputDevice8W *this) {
    wb_device *d = DEVICE(this);
    EnterCriticalSection(&d->lock);
    HRESULT result = DI_OK;
    if (!d->has_format) {
        result = DIERR_INVALIDPARAM;
    } else if (d->acquired) {
        result = DI_NOEFFECT;
    } else {
        d->acquired = 1;
        d->has_last_values = 0;
        wb_bridge *bridge = wb_bridge_get();
        if (bridge) {
            /* The latest game to acquire wins, so a crashed one cannot hold the wheel. */
            __atomic_store_n(&bridge->game.owner_pid, GetCurrentProcessId(), __ATOMIC_RELAXED);
            wb_device_publish(d);
        }
    }
    LeaveCriticalSection(&d->lock);
    return result;
}

static HRESULT STDMETHODCALLTYPE device_unacquire(IDirectInputDevice8W *this) {
    wb_device *d = DEVICE(this);
    EnterCriticalSection(&d->lock);
    HRESULT result = DI_NOEFFECT;
    if (d->acquired) {
        release_wheel(d);
        d->acquired = 0;
        result = DI_OK;
    }
    LeaveCriticalSection(&d->lock);
    return result;
}

static void write_state(const wb_device *d, const LONG values[WB_OBJECTS], BYTE *out) {
    for (int i = 0; i < WB_OBJECTS; i++) {
        if (d->offsets[i] < 0) {
            continue;
        }
        if (is_button(i)) {
            out[d->offsets[i]] = (BYTE)values[i];
        } else {
            *(LONG *)(out + d->offsets[i]) = values[i];
        }
    }
    for (int i = 0; i < d->extra_pov_count; i++) {
        *(LONG *)(out + d->extra_povs[i]) = -1;
    }
}

static HRESULT STDMETHODCALLTYPE device_get_state(IDirectInputDevice8W *this, DWORD size, void *out) {
    wb_device *d = DEVICE(this);
    if (!out) {
        return E_POINTER;
    }
    EnterCriticalSection(&d->lock);
    HRESULT result = DI_OK;
    if (!d->acquired) {
        result = DIERR_NOTACQUIRED;
    } else if (size != d->format_size) {
        result = DIERR_INVALIDPARAM;
    } else {
        LONG values[WB_OBJECTS];
        sample(d, values);
        memset(out, 0, size);
        write_state(d, values, out);
    }
    LeaveCriticalSection(&d->lock);
    return result;
}

static HRESULT STDMETHODCALLTYPE device_get_data(IDirectInputDevice8W *this, DWORD item_size, LPDIDEVICEOBJECTDATA out,
                                                 LPDWORD count, DWORD flags) {
    wb_device *d = DEVICE(this);
    if (!count) {
        return E_POINTER;
    }
    EnterCriticalSection(&d->lock);
    HRESULT result = DI_OK;
    if (!d->acquired) {
        result = DIERR_NOTACQUIRED;
    } else if (!d->event_capacity) {
        result = DIERR_NOTBUFFERED;
    } else {
        LONG values[WB_OBJECTS];
        sample(d, values);
        DWORD wanted = *count, delivered = 0;
        DWORD head = d->event_head, remaining = d->event_count;
        while (delivered < wanted && remaining) {
            if (out) {
                /* A DX3-sized item is a prefix of the full one. */
                memcpy((BYTE *)out + (size_t)delivered * item_size, &d->events[head],
                       item_size < sizeof(*d->events) ? item_size : sizeof(*d->events));
            }
            head = (head + 1) % d->event_capacity;
            remaining--;
            delivered++;
        }
        if (!(flags & DIGDD_PEEK)) {
            d->event_head = head;
            d->event_count = remaining;
        }
        *count = delivered;
    }
    LeaveCriticalSection(&d->lock);
    return result;
}

static int format_object_matches(const DIOBJECTDATAFORMAT *item, int object) {
    DWORD wanted = DIDFT_GETTYPE(item->dwType);
    DWORD own = DIDFT_GETTYPE(object_type(object));
    if (wanted && !(wanted & own)) {
        return 0;
    }
    if (item->pguid && !IsEqualGUID(item->pguid, object_guid(object))) {
        return 0;
    }
    DWORD instance = DIDFT_GETINSTANCE(item->dwType);
    return instance == 0xffffu || instance == DIDFT_GETINSTANCE(object_type(object));
}

static HRESULT STDMETHODCALLTYPE device_set_format(IDirectInputDevice8W *this, LPCDIDATAFORMAT format) {
    wb_device *d = DEVICE(this);
    if (!format || format->dwObjSize != sizeof(DIOBJECTDATAFORMAT) || !format->rgodf) {
        return DIERR_INVALIDPARAM;
    }
    EnterCriticalSection(&d->lock);
    HRESULT result = DI_OK;
    if (d->acquired) {
        result = DIERR_ACQUIRED;
    } else {
        for (int i = 0; i < WB_OBJECTS; i++) {
            d->offsets[i] = -1;
        }
        d->extra_pov_count = 0;
        for (DWORD f = 0; f < format->dwNumObjs; f++) {
            const DIOBJECTDATAFORMAT *item = &format->rgodf[f];
            int matched = 0;
            for (int i = 0; i < WB_OBJECTS && !matched; i++) {
                if (d->offsets[i] < 0 && format_object_matches(item, i)) {
                    d->offsets[i] = (LONG)item->dwOfs;
                    matched = 1;
                }
            }
            /* An unused hat must read as centred, which is -1, not zero. */
            if (!matched && (DIDFT_GETTYPE(item->dwType) & DIDFT_POV) && d->extra_pov_count < 8) {
                d->extra_povs[d->extra_pov_count++] = item->dwOfs;
            }
        }
        d->format_size = format->dwDataSize;
        d->has_format = 1;
    }
    LeaveCriticalSection(&d->lock);
    return result;
}

static HRESULT STDMETHODCALLTYPE device_set_event(IDirectInputDevice8W *this, HANDLE event) {
    (void)this, (void)event;
    return DI_POLLEDDEVICE;
}

static HRESULT STDMETHODCALLTYPE device_set_cooperative(IDirectInputDevice8W *this, HWND window, DWORD flags) {
    (void)this, (void)window, (void)flags;
    return DI_OK;
}

static HRESULT STDMETHODCALLTYPE device_object_info(IDirectInputDevice8W *this, LPDIDEVICEOBJECTINSTANCEW out, DWORD id, DWORD how) {
    wb_device *d = DEVICE(this);
    if (!out) {
        return E_POINTER;
    }
    int object = find_object(d, id, how);
    if (object < 0) {
        return DIERR_OBJECTNOTFOUND;
    }
    if (d->wide) {
        fill_object_w(d, object, out);
    } else {
        fill_object_a(d, object, (DIDEVICEOBJECTINSTANCEA *)out);
    }
    return DI_OK;
}

static HRESULT STDMETHODCALLTYPE device_info(IDirectInputDevice8W *this, LPDIDEVICEINSTANCEW out) {
    wb_device *d = DEVICE(this);
    if (!out) {
        return E_POINTER;
    }
    wb_input identity = current_identity(d);
    wb_fill_instance(&identity, out, d->wide);
    return DI_OK;
}

static HRESULT STDMETHODCALLTYPE device_control_panel(IDirectInputDevice8W *this, HWND owner, DWORD flags) {
    (void)this, (void)owner, (void)flags;
    return DI_OK;
}

static HRESULT STDMETHODCALLTYPE device_initialize(IDirectInputDevice8W *this, HINSTANCE instance, DWORD version, REFGUID guid) {
    (void)this, (void)instance, (void)version, (void)guid;
    return DI_OK;
}

static HRESULT STDMETHODCALLTYPE device_create_effect(IDirectInputDevice8W *this, REFGUID guid, LPCDIEFFECT params,
                                                      LPDIRECTINPUTEFFECT *out, IUnknown *outer) {
    wb_device *d = DEVICE(this);
    if (outer) {
        return CLASS_E_NOAGGREGATION;
    }
    EnterCriticalSection(&d->lock);
    HRESULT result = wb_effect_create(d, guid, params, out);
    LeaveCriticalSection(&d->lock);
    return result;
}

static HRESULT STDMETHODCALLTYPE device_enum_effects(IDirectInputDevice8W *this, LPDIENUMEFFECTSCALLBACKW callback, void *context, DWORD type) {
    return wb_effect_enum(DEVICE(this), (void *)callback, context, type);
}

static HRESULT STDMETHODCALLTYPE device_effect_info(IDirectInputDevice8W *this, LPDIEFFECTINFOW out, REFGUID guid) {
    return wb_effect_info(DEVICE(this), out, guid);
}

static HRESULT STDMETHODCALLTYPE device_ff_state(IDirectInputDevice8W *this, LPDWORD out) {
    wb_device *d = DEVICE(this);
    if (!out) {
        return E_POINTER;
    }
    EnterCriticalSection(&d->lock);
    DWORD state = DIGFFS_POWERON;
    state |= d->ff_flags & WB_GAME_ACTUATORS_OFF ? DIGFFS_ACTUATORSOFF : DIGFFS_ACTUATORSON;
    if (d->ff_flags & WB_GAME_PAUSED) {
        state |= DIGFFS_PAUSED;
    }
    int any = 0, playing = 0;
    for (DWORD i = 0; i < WB_MAX_EFFECTS; i++) {
        any |= d->slots[i] != NULL;
        playing |= d->game.effects[i].playing != 0;
    }
    state |= any ? 0 : DIGFFS_EMPTY;
    state |= playing ? 0 : DIGFFS_STOPPED;
    *out = state;
    LeaveCriticalSection(&d->lock);
    return DI_OK;
}

static HRESULT STDMETHODCALLTYPE device_ff_command(IDirectInputDevice8W *this, DWORD command) {
    wb_device *d = DEVICE(this);
    EnterCriticalSection(&d->lock);
    HRESULT result = DI_OK;
    switch (command) {
    case DISFFC_RESET:
    case DISFFC_STOPALL:
        wb_effect_stop_all(d);
        d->ff_flags &= ~(DWORD)WB_GAME_PAUSED;
        break;
    case DISFFC_PAUSE:
        d->ff_flags |= WB_GAME_PAUSED;
        break;
    case DISFFC_CONTINUE:
        d->ff_flags &= ~(DWORD)WB_GAME_PAUSED;
        break;
    case DISFFC_SETACTUATORSON:
        d->ff_flags &= ~(DWORD)WB_GAME_ACTUATORS_OFF;
        break;
    case DISFFC_SETACTUATORSOFF:
        d->ff_flags |= WB_GAME_ACTUATORS_OFF;
        break;
    default:
        result = DIERR_INVALIDPARAM;
    }
    wb_device_publish(d);
    LeaveCriticalSection(&d->lock);
    return result;
}

static HRESULT STDMETHODCALLTYPE device_enum_created(IDirectInputDevice8W *this, LPDIENUMCREATEDEFFECTOBJECTSCALLBACK callback,
                                                     void *context, DWORD flags) {
    (void)flags;
    return wb_effect_enum_created(DEVICE(this), callback, context);
}

static HRESULT STDMETHODCALLTYPE device_escape(IDirectInputDevice8W *this, LPDIEFFESCAPE escape) {
    (void)this, (void)escape;
    return DIERR_UNSUPPORTED;
}

static HRESULT STDMETHODCALLTYPE device_poll(IDirectInputDevice8W *this) {
    wb_device *d = DEVICE(this);
    EnterCriticalSection(&d->lock);
    HRESULT result = DI_OK;
    if (d->acquired) {
        LONG values[WB_OBJECTS];
        sample(d, values);
    } else {
        result = DIERR_NOTACQUIRED;
    }
    LeaveCriticalSection(&d->lock);
    return result;
}

static HRESULT STDMETHODCALLTYPE device_send_data(IDirectInputDevice8W *this, DWORD size, LPCDIDEVICEOBJECTDATA data, LPDWORD count, DWORD flags) {
    (void)this, (void)size, (void)data, (void)count, (void)flags;
    return DIERR_UNSUPPORTED;
}

static HRESULT STDMETHODCALLTYPE device_effects_in_file(IDirectInputDevice8W *this, LPCWSTR file, LPDIENUMEFFECTSINFILECALLBACK callback, void *context, DWORD flags) {
    (void)this, (void)file, (void)callback, (void)context, (void)flags;
    return DIERR_UNSUPPORTED;
}

static HRESULT STDMETHODCALLTYPE device_write_file(IDirectInputDevice8W *this, LPCWSTR file, DWORD count, LPDIFILEEFFECT effects, DWORD flags) {
    (void)this, (void)file, (void)count, (void)effects, (void)flags;
    return DIERR_UNSUPPORTED;
}

static HRESULT STDMETHODCALLTYPE device_build_map(IDirectInputDevice8W *this, LPDIACTIONFORMATW format, LPCWSTR user, DWORD flags) {
    (void)this, (void)format, (void)user, (void)flags;
    return DIERR_UNSUPPORTED;
}

static HRESULT STDMETHODCALLTYPE device_set_map(IDirectInputDevice8W *this, LPDIACTIONFORMATW format, LPCWSTR user, DWORD flags) {
    (void)this, (void)format, (void)user, (void)flags;
    return DIERR_UNSUPPORTED;
}

static HRESULT STDMETHODCALLTYPE device_image_info(IDirectInputDevice8W *this, LPDIDEVICEIMAGEINFOHEADERW info) {
    (void)this, (void)info;
    return DIERR_UNSUPPORTED;
}

static const IDirectInputDevice8WVtbl device_w = {
    device_query,        device_add_ref,      device_release,      device_caps,
    device_enum_objects, device_get_property, device_set_property, device_acquire,
    device_unacquire,    device_get_state,    device_get_data,     device_set_format,
    device_set_event,    device_set_cooperative, device_object_info, device_info,
    device_control_panel, device_initialize,  device_create_effect, device_enum_effects,
    device_effect_info,  device_ff_state,     device_ff_command,   device_enum_created,
    device_escape,       device_poll,         device_send_data,    device_effects_in_file,
    device_write_file,   device_build_map,    device_set_map,      device_image_info,
};

/* The A table has the same layout. Where text differs, the methods check d->wide. */
static const IDirectInputDevice8AVtbl device_a = {
    (void *)device_query,        (void *)device_add_ref,      (void *)device_release,      (void *)device_caps,
    (void *)device_enum_objects, (void *)device_get_property, (void *)device_set_property, (void *)device_acquire,
    (void *)device_unacquire,    (void *)device_get_state,    (void *)device_get_data,     (void *)device_set_format,
    (void *)device_set_event,    (void *)device_set_cooperative, (void *)device_object_info, (void *)device_info,
    (void *)device_control_panel, (void *)device_initialize,  (void *)device_create_effect, (void *)device_enum_effects,
    (void *)device_effect_info,  (void *)device_ff_state,     (void *)device_ff_command,   (void *)device_enum_created,
    (void *)device_escape,       (void *)device_poll,         (void *)device_send_data,    (void *)device_effects_in_file,
    (void *)device_write_file,   (void *)device_build_map,    (void *)device_set_map,      (void *)device_image_info,
};

HRESULT wb_device_create(int wide, const wb_input *input, void **out) {
    wb_device *d = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*d));
    if (!d) {
        return E_OUTOFMEMORY;
    }
    d->vtbl = wide ? (const void *)&device_w : (const void *)&device_a;
    d->refs = 1;
    d->wide = wide;
    InitializeCriticalSection(&d->lock);
    wb_product_guid(input, &d->product);
    memcpy(d->name, input->name, WB_NAME_BYTES);
    d->name[WB_NAME_BYTES - 1] = 0;
    for (int i = 0; i < WB_OBJECTS; i++) {
        d->offsets[i] = -1;
    }
    for (int i = 0; i < WB_AXES; i++) {
        d->range_max[i] = 65535;
        d->saturation[i] = 10000;
    }
    d->gain = DI_FFNOMINALMAX;

    /* Shown in the app, so people can see which game has the wheel. */
    char path[MAX_PATH];
    GetModuleFileNameA(NULL, path, sizeof(path));
    const char *slash = strrchr(path, '\\');
    snprintf(d->game.game_name, WB_NAME_BYTES, "%s", slash ? slash + 1 : path);

    wb_log("virtual wheel created for %s", d->game.game_name);
    *out = d;
    return DI_OK;
}
