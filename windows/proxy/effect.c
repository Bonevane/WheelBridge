/* IDirectInputEffect. Each effect mirrors what the game set into a shared slot,
 * and the helper's engine does all the interpreting. */
#include "wb_proxy.h"

#include <stddef.h>
#include <stdio.h>

#define INFINITE_DURATION 0xffffffffu

struct wb_effect_object {
    const IDirectInputEffectVtbl *vtbl;
    LONG refs;
    wb_device *device; /* NULL once the device has gone */
    int slot;
    GUID guid;
    DWORD axes[2];
    DWORD axis_count;
    DWORD type_flags; /* DIEFF_OBJECT* the game used for its axes */
};

#define EFFECT(this) ((wb_effect_object *)(this))

typedef struct {
    const GUID *guid;
    wb_effect_kind kind;
    DWORD type;
    const char *name;
} effect_type;

#define ENVELOPE (DIEFT_FFATTACK | DIEFT_FFFADE)
#define CONDITION (DIEFT_CONDITION | DIEFT_SATURATION | DIEFT_POSNEGCOEFFICIENTS | DIEFT_POSNEGSATURATION | DIEFT_DEADBAND)

static const effect_type types[] = {
    {&GUID_ConstantForce, WB_EFFECT_CONSTANT, DIEFT_CONSTANTFORCE | ENVELOPE | DIEFT_STARTDELAY, "Constant Force"},
    {&GUID_RampForce, WB_EFFECT_RAMP, DIEFT_RAMPFORCE | ENVELOPE | DIEFT_STARTDELAY, "Ramp Force"},
    {&GUID_Square, WB_EFFECT_SQUARE, DIEFT_PERIODIC | ENVELOPE | DIEFT_STARTDELAY, "Square"},
    {&GUID_Sine, WB_EFFECT_SINE, DIEFT_PERIODIC | ENVELOPE | DIEFT_STARTDELAY, "Sine"},
    {&GUID_Triangle, WB_EFFECT_TRIANGLE, DIEFT_PERIODIC | ENVELOPE | DIEFT_STARTDELAY, "Triangle"},
    {&GUID_SawtoothUp, WB_EFFECT_SAW_UP, DIEFT_PERIODIC | ENVELOPE | DIEFT_STARTDELAY, "Sawtooth Up"},
    {&GUID_SawtoothDown, WB_EFFECT_SAW_DOWN, DIEFT_PERIODIC | ENVELOPE | DIEFT_STARTDELAY, "Sawtooth Down"},
    {&GUID_Spring, WB_EFFECT_SPRING, CONDITION | DIEFT_STARTDELAY, "Spring"},
    {&GUID_Damper, WB_EFFECT_DAMPER, CONDITION | DIEFT_STARTDELAY, "Damper"},
    {&GUID_Inertia, WB_EFFECT_INERTIA, CONDITION | DIEFT_STARTDELAY, "Inertia"},
    {&GUID_Friction, WB_EFFECT_FRICTION, CONDITION | DIEFT_STARTDELAY, "Friction"},
};

#define TYPE_COUNT (sizeof(types) / sizeof(types[0]))

static const effect_type *type_for(REFGUID guid) {
    for (size_t i = 0; i < TYPE_COUNT; i++) {
        if (IsEqualGUID(guid, types[i].guid)) {
            return &types[i];
        }
    }
    return NULL;
}

static int is_condition(uint32_t kind) { return kind >= WB_EFFECT_SPRING && kind <= WB_EFFECT_FRICTION; }

static int is_periodic(uint32_t kind) { return kind >= WB_EFFECT_SQUARE && kind <= WB_EFFECT_SAW_DOWN; }

static wb_effect *record(wb_effect_object *e) { return &e->device->game.effects[e->slot]; }

/* Whether an axis the game named is the wheel. It may name it by data format
 * offset or by object ID, and DIJOFS_X is 0, as is the wheel's instance. */
static int is_wheel_axis(const wb_effect_object *e, DWORD axis, DWORD flags) {
    if (flags & DIEFF_OBJECTIDS) {
        return DIDFT_GETINSTANCE(axis) == 0 && (DIDFT_GETTYPE(axis) & DIDFT_AXIS);
    }
    return axis == (e->device->offsets[0] >= 0 ? (DWORD)e->device->offsets[0] : DIJOFS_X);
}

static void store_params(wb_effect *r, const DIEFFECT *p) {
    uint32_t kind = r->kind;
    const void *data = p->lpvTypeSpecificParams;
    DWORD size = p->cbTypeSpecificParams;
    if (!data) {
        return;
    }
    if (kind == WB_EFFECT_CONSTANT && size >= sizeof(DICONSTANTFORCE)) {
        r->params[0] = ((const DICONSTANTFORCE *)data)->lMagnitude;
    } else if (kind == WB_EFFECT_RAMP && size >= sizeof(DIRAMPFORCE)) {
        r->params[0] = ((const DIRAMPFORCE *)data)->lStart;
        r->params[1] = ((const DIRAMPFORCE *)data)->lEnd;
    } else if (is_periodic(kind) && size >= sizeof(DIPERIODIC)) {
        const DIPERIODIC *periodic = data;
        r->params[0] = (int32_t)periodic->dwMagnitude;
        r->params[1] = periodic->lOffset;
        r->params[2] = (int32_t)periodic->dwPhase;
        r->params[3] = (int32_t)periodic->dwPeriod;
    } else if (is_condition(kind) && size >= sizeof(DICONDITION)) {
        /* One condition per axis, or one shared by all of them. */
        const DICONDITION *conditions = data;
        DWORD count = size / sizeof(DICONDITION);
        const DICONDITION *c = &conditions[r->x_axis_index < count ? r->x_axis_index : 0];
        r->params[0] = c->lOffset;
        r->params[1] = c->lPositiveCoefficient;
        r->params[2] = c->lNegativeCoefficient;
        r->params[3] = (int32_t)c->dwPositiveSaturation;
        r->params[4] = (int32_t)c->dwNegativeSaturation;
        r->params[5] = c->lDeadBand;
    }
}

static void start(wb_effect_object *e, DWORD iterations, DWORD flags) {
    wb_device *d = e->device;
    if (flags & DIES_SOLO) {
        for (DWORD i = 0; i < WB_MAX_EFFECTS; i++) {
            d->game.effects[i].playing = 0;
        }
    }
    wb_effect *r = record(e);
    r->iterations = iterations;
    r->playing = 1;
    r->start_count++;
}

static HRESULT apply(wb_effect_object *e, LPCDIEFFECT p, DWORD flags) {
    wb_effect *r = record(e);
    if (!p || p->dwSize < offsetof(DIEFFECT, dwStartDelay)) {
        return DIERR_INVALIDPARAM;
    }
    if (flags & DIEP_DURATION) {
        r->duration_us = p->dwDuration;
    }
    if (flags & DIEP_GAIN) {
        r->gain = p->dwGain;
    }
    if ((flags & DIEP_AXES) && p->rgdwAxes && p->cAxes) {
        e->axis_count = p->cAxes < 2 ? p->cAxes : 2;
        e->type_flags = p->dwFlags & (DIEFF_OBJECTIDS | DIEFF_OBJECTOFFSETS);
        r->axis_count = p->cAxes;
        r->x_axis_index = 0;
        for (DWORD i = 0; i < e->axis_count; i++) {
            e->axes[i] = p->rgdwAxes[i];
            if (is_wheel_axis(e, p->rgdwAxes[i], p->dwFlags)) {
                r->x_axis_index = i;
            }
        }
    }
    if ((flags & DIEP_DIRECTION) && p->rglDirection) {
        DWORD coords = p->dwFlags & (DIEFF_CARTESIAN | DIEFF_POLAR | DIEFF_SPHERICAL);
        DWORD count = r->axis_count ? r->axis_count : 1;
        r->coords = coords;
        r->direction[0] = p->rglDirection[0];
        r->direction[1] = count > 1 ? p->rglDirection[1] : 0;
    }
    if (flags & DIEP_ENVELOPE) {
        r->has_envelope = p->lpEnvelope != NULL;
        if (p->lpEnvelope) {
            r->attack_level = p->lpEnvelope->dwAttackLevel;
            r->attack_time_us = p->lpEnvelope->dwAttackTime;
            r->fade_level = p->lpEnvelope->dwFadeLevel;
            r->fade_time_us = p->lpEnvelope->dwFadeTime;
        }
    }
    if (flags & DIEP_TYPESPECIFICPARAMS) {
        store_params(r, p);
    }
    if ((flags & DIEP_STARTDELAY) && p->dwSize >= sizeof(DIEFFECT)) {
        r->start_delay_us = p->dwStartDelay;
    }
    if (flags & DIEP_START) {
        start(e, 1, 0);
    }
    return DI_OK;
}

static HRESULT STDMETHODCALLTYPE effect_query(IDirectInputEffect *this, REFIID iid, void **out) {
    if (!out) {
        return E_POINTER;
    }
    if (IsEqualGUID(iid, &IID_IUnknown) || IsEqualGUID(iid, &IID_IDirectInputEffect)) {
        InterlockedIncrement(&EFFECT(this)->refs);
        *out = this;
        return S_OK;
    }
    *out = NULL;
    return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE effect_add_ref(IDirectInputEffect *this) {
    return InterlockedIncrement(&EFFECT(this)->refs);
}

static ULONG STDMETHODCALLTYPE effect_release(IDirectInputEffect *this) {
    wb_effect_object *e = EFFECT(this);
    ULONG refs = InterlockedDecrement(&e->refs);
    if (refs) {
        return refs;
    }
    wb_device *d = e->device;
    if (d) {
        EnterCriticalSection(&d->lock);
        memset(record(e), 0, sizeof(wb_effect));
        d->slots[e->slot] = NULL;
        wb_device_publish(d);
        LeaveCriticalSection(&d->lock);
    }
    HeapFree(GetProcessHeap(), 0, e);
    return 0;
}

static HRESULT STDMETHODCALLTYPE effect_initialize(IDirectInputEffect *this, HINSTANCE instance, DWORD version,
                                                   REFGUID guid) {
    (void)this, (void)instance, (void)version, (void)guid;
    return DI_OK;
}

static HRESULT STDMETHODCALLTYPE effect_guid(IDirectInputEffect *this, LPGUID out) {
    if (!out) {
        return E_POINTER;
    }
    *out = EFFECT(this)->guid;
    return DI_OK;
}

static HRESULT STDMETHODCALLTYPE effect_get(IDirectInputEffect *this, LPDIEFFECT p, DWORD flags) {
    wb_effect_object *e = EFFECT(this);
    wb_device *d = e->device;
    if (!p || p->dwSize < offsetof(DIEFFECT, dwStartDelay)) {
        return DIERR_INVALIDPARAM;
    }
    if (!d) {
        return DIERR_NOTINITIALIZED;
    }
    EnterCriticalSection(&d->lock);
    const wb_effect *r = record(e);
    HRESULT result = DI_OK;
    if (flags & DIEP_DURATION) {
        p->dwDuration = r->duration_us;
    }
    if (flags & DIEP_GAIN) {
        p->dwGain = r->gain;
    }
    if (flags & DIEP_AXES) {
        DWORD room = p->cAxes;
        p->cAxes = e->axis_count;
        if (room < e->axis_count || !p->rgdwAxes) {
            result = DIERR_MOREDATA;
        } else {
            for (DWORD i = 0; i < e->axis_count; i++) {
                p->rgdwAxes[i] = e->axes[i];
            }
        }
    }
    if ((flags & DIEP_DIRECTION) && p->rglDirection) {
        p->dwFlags = (p->dwFlags & ~(DWORD)(DIEFF_CARTESIAN | DIEFF_POLAR | DIEFF_SPHERICAL)) | r->coords;
        p->rglDirection[0] = r->direction[0];
        if (p->cAxes > 1) {
            p->rglDirection[1] = r->direction[1];
        }
    }
    if ((flags & DIEP_ENVELOPE) && p->lpEnvelope && r->has_envelope) {
        p->lpEnvelope->dwAttackLevel = r->attack_level;
        p->lpEnvelope->dwAttackTime = r->attack_time_us;
        p->lpEnvelope->dwFadeLevel = r->fade_level;
        p->lpEnvelope->dwFadeTime = r->fade_time_us;
    }
    if ((flags & DIEP_TYPESPECIFICPARAMS) && p->lpvTypeSpecificParams) {
        if (r->kind == WB_EFFECT_CONSTANT && p->cbTypeSpecificParams >= sizeof(DICONSTANTFORCE)) {
            ((DICONSTANTFORCE *)p->lpvTypeSpecificParams)->lMagnitude = r->params[0];
        } else if (r->kind == WB_EFFECT_RAMP && p->cbTypeSpecificParams >= sizeof(DIRAMPFORCE)) {
            ((DIRAMPFORCE *)p->lpvTypeSpecificParams)->lStart = r->params[0];
            ((DIRAMPFORCE *)p->lpvTypeSpecificParams)->lEnd = r->params[1];
        } else if (is_periodic(r->kind) && p->cbTypeSpecificParams >= sizeof(DIPERIODIC)) {
            DIPERIODIC *periodic = p->lpvTypeSpecificParams;
            periodic->dwMagnitude = (DWORD)r->params[0];
            periodic->lOffset = r->params[1];
            periodic->dwPhase = (DWORD)r->params[2];
            periodic->dwPeriod = (DWORD)r->params[3];
        } else if (is_condition(r->kind) && p->cbTypeSpecificParams >= sizeof(DICONDITION)) {
            DICONDITION *c = p->lpvTypeSpecificParams;
            c->lOffset = r->params[0];
            c->lPositiveCoefficient = r->params[1];
            c->lNegativeCoefficient = r->params[2];
            c->dwPositiveSaturation = (DWORD)r->params[3];
            c->dwNegativeSaturation = (DWORD)r->params[4];
            c->lDeadBand = r->params[5];
        }
    }
    if ((flags & DIEP_STARTDELAY) && p->dwSize >= sizeof(DIEFFECT)) {
        p->dwStartDelay = r->start_delay_us;
    }
    LeaveCriticalSection(&d->lock);
    return result;
}

static HRESULT STDMETHODCALLTYPE effect_set(IDirectInputEffect *this, LPCDIEFFECT p, DWORD flags) {
    wb_effect_object *e = EFFECT(this);
    wb_device *d = e->device;
    if (!d) {
        return DIERR_NOTINITIALIZED;
    }
    EnterCriticalSection(&d->lock);
    HRESULT result = apply(e, p, flags);
    wb_device_publish(d);
    LeaveCriticalSection(&d->lock);
    return result;
}

static HRESULT STDMETHODCALLTYPE effect_start(IDirectInputEffect *this, DWORD iterations, DWORD flags) {
    wb_effect_object *e = EFFECT(this);
    wb_device *d = e->device;
    if (!d) {
        return DIERR_NOTINITIALIZED;
    }
    EnterCriticalSection(&d->lock);
    start(e, iterations, flags);
    wb_device_publish(d);
    LeaveCriticalSection(&d->lock);
    return DI_OK;
}

static HRESULT STDMETHODCALLTYPE effect_stop(IDirectInputEffect *this) {
    wb_effect_object *e = EFFECT(this);
    wb_device *d = e->device;
    if (!d) {
        return DIERR_NOTINITIALIZED;
    }
    EnterCriticalSection(&d->lock);
    record(e)->playing = 0;
    wb_device_publish(d);
    LeaveCriticalSection(&d->lock);
    return DI_OK;
}

static HRESULT STDMETHODCALLTYPE effect_status(IDirectInputEffect *this, LPDWORD out) {
    wb_effect_object *e = EFFECT(this);
    wb_device *d = e->device;
    if (!out) {
        return E_POINTER;
    }
    if (!d) {
        return DIERR_NOTINITIALIZED;
    }
    EnterCriticalSection(&d->lock);
    *out = record(e)->playing ? DIEGES_PLAYING : 0;
    LeaveCriticalSection(&d->lock);
    return DI_OK;
}

static HRESULT STDMETHODCALLTYPE effect_download(IDirectInputEffect *this) {
    return EFFECT(this)->device ? DI_OK : DIERR_NOTINITIALIZED;
}

static HRESULT STDMETHODCALLTYPE effect_unload(IDirectInputEffect *this) { return effect_stop(this); }

static HRESULT STDMETHODCALLTYPE effect_escape(IDirectInputEffect *this, LPDIEFFESCAPE escape) {
    (void)this, (void)escape;
    return DIERR_UNSUPPORTED;
}

static const IDirectInputEffectVtbl effect_vtbl = {
    effect_query,  effect_add_ref, effect_release, effect_initialize, effect_guid,
    effect_get,    effect_set,     effect_start,   effect_stop,       effect_status,
    effect_download, effect_unload, effect_escape,
};

HRESULT wb_effect_create(wb_device *d, REFGUID guid, LPCDIEFFECT params, LPDIRECTINPUTEFFECT *out) {
    const effect_type *type = type_for(guid);
    if (!out) {
        return E_POINTER;
    }
    *out = NULL;
    if (!type) {
        return DIERR_DEVICENOTREG;
    }
    int slot = -1;
    for (int i = 0; i < (int)WB_MAX_EFFECTS; i++) {
        if (!d->slots[i]) {
            slot = i;
            break;
        }
    }
    if (slot < 0) {
        return DIERR_DEVICEFULL;
    }
    wb_effect_object *e = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*e));
    if (!e) {
        return E_OUTOFMEMORY;
    }
    e->vtbl = &effect_vtbl;
    e->refs = 1;
    e->device = d;
    e->slot = slot;
    e->guid = *guid;
    d->slots[slot] = e;

    wb_effect *r = record(e);
    memset(r, 0, sizeof(*r));
    r->kind = type->kind;
    r->gain = DI_FFNOMINALMAX;
    r->duration_us = INFINITE_DURATION;
    r->iterations = 1;
    r->axis_count = 1;
    r->coords = WB_COORD_CARTESIAN;
    r->direction[0] = 1;
    if (params) {
        HRESULT result = apply(e, params, DIEP_ALLPARAMS);
        if (FAILED(result)) {
            d->slots[slot] = NULL;
            memset(r, 0, sizeof(*r));
            HeapFree(GetProcessHeap(), 0, e);
            return result;
        }
    }
    wb_device_publish(d);
    *out = (LPDIRECTINPUTEFFECT)e;
    return DI_OK;
}

static void fill_info(const effect_type *type, void *out, int wide) {
    DIEFFECTINFOW *w = out;
    DIEFFECTINFOA *a = out;
    /* The two share every field up to the name. */
    a->guid = *type->guid;
    a->dwEffType = type->type;
    a->dwStaticParams = DIEP_ALLPARAMS;
    a->dwDynamicParams = DIEP_ALLPARAMS;
    if (wide) {
        MultiByteToWideChar(CP_ACP, 0, type->name, -1, w->tszName, MAX_PATH);
    } else {
        snprintf(a->tszName, MAX_PATH, "%s", type->name);
    }
}

HRESULT wb_effect_enum(wb_device *d, void *callback, void *context, DWORD wanted) {
    if (!callback) {
        return DIERR_INVALIDPARAM;
    }
    for (size_t i = 0; i < TYPE_COUNT; i++) {
        if (wanted != DIEFT_ALL && DIEFT_GETTYPE(types[i].type) != DIEFT_GETTYPE(wanted)) {
            continue;
        }
        BOOL keep_going;
        if (d->wide) {
            DIEFFECTINFOW info = {.dwSize = sizeof(info)};
            fill_info(&types[i], &info, 1);
            keep_going = ((LPDIENUMEFFECTSCALLBACKW)callback)(&info, context);
        } else {
            DIEFFECTINFOA info = {.dwSize = sizeof(info)};
            fill_info(&types[i], &info, 0);
            keep_going = ((LPDIENUMEFFECTSCALLBACKA)callback)(&info, context);
        }
        if (keep_going == DIENUM_STOP) {
            break;
        }
    }
    return DI_OK;
}

HRESULT wb_effect_info(wb_device *d, void *out, REFGUID guid) {
    const effect_type *type = type_for(guid);
    if (!out) {
        return E_POINTER;
    }
    if (!type) {
        return DIERR_DEVICENOTREG;
    }
    fill_info(type, out, d->wide);
    return DI_OK;
}

void wb_effect_stop_all(wb_device *d) {
    for (DWORD i = 0; i < WB_MAX_EFFECTS; i++) {
        d->game.effects[i].playing = 0;
    }
}

/* The device is going. Effects the game still holds must fail politely. */
void wb_effect_detach_all(wb_device *d) {
    for (DWORD i = 0; i < WB_MAX_EFFECTS; i++) {
        if (d->slots[i]) {
            d->slots[i]->device = NULL;
            d->slots[i] = NULL;
        }
    }
}

HRESULT wb_effect_enum_created(wb_device *d, LPDIENUMCREATEDEFFECTOBJECTSCALLBACK callback, void *context) {
    if (!callback) {
        return DIERR_INVALIDPARAM;
    }
    for (DWORD i = 0; i < WB_MAX_EFFECTS; i++) {
        if (d->slots[i] && callback((LPDIRECTINPUTEFFECT)d->slots[i], context) == DIENUM_STOP) {
            break;
        }
    }
    return DI_OK;
}
