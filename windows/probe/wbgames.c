/*
 * Stand-ins for real sims, used to test the proxy under Wine without the games.
 * Each profile follows the DirectInput calls that game family is known to make,
 * and prints one line per step, ending in "done" when everything worked.
 *
 *   kunos   Assetto Corsa, ACC and AC EVO: Unicode interfaces, a lookup by
 *           USB id, autocentre off, actuators on, a constant force updated at
 *           the physics rate, a light damper, and pause and continue.
 *   beamng  BeamNG.drive: every class of device, filtered by capabilities, the
 *           older DIJOYSTATE format, buffered input, and a polar constant force
 *           restarted with each update.
 *   sdl     Games built on SDL: a data format built from the device's own
 *           objects, effects aimed at the actuator objects by offset, and a
 *           periodic effect.
 *
 * Usage: wbgames PROFILE [seconds]
 */
#define CINTERFACE
#define COBJMACROS
#define DIRECTINPUT_VERSION 0x0800
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dinput.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define G29_PRODUCT 0xc24f046dUL

#define CHECK(step, call)                                                                      \
    do {                                                                                       \
        HRESULT result_ = (call);                                                              \
        printf("%s %s 0x%08lx\n", FAILED(result_) ? "FAIL" : "ok", step, (unsigned long)result_); \
        if (FAILED(result_)) {                                                                 \
            return 1;                                                                          \
        }                                                                                      \
    } while (0)

#define EXPECT(step, condition)                                     \
    do {                                                            \
        int ok_ = (condition);                                      \
        printf("%s %s\n", ok_ ? "ok" : "FAIL", step);               \
        if (!ok_) {                                                 \
            return 1;                                               \
        }                                                           \
    } while (0)

static GUID chosen;
static int candidates;

static BOOL CALLBACK pick_by_product(const DIDEVICEINSTANCEW *device, void *context) {
    (void)context;
    printf("device product=%08lx type=%08lx\n", device->guidProduct.Data1, device->dwDevType);
    if (device->guidProduct.Data1 == G29_PRODUCT) {
        chosen = device->guidInstance;
        candidates++;
    }
    return DIENUM_CONTINUE;
}

static IDirectInput8W *open_input(void) {
    IDirectInput8W *input = NULL;
    HRESULT result = DirectInput8Create(GetModuleHandleW(NULL), DIRECTINPUT_VERSION, &IID_IDirectInput8W, (void **)&input, NULL);
    printf("%s create 0x%08lx\n", FAILED(result) ? "FAIL" : "ok", (unsigned long)result);
    return FAILED(result) ? NULL : input;
}

static HWND make_window(void) {
    WNDCLASSW type = {.lpfnWndProc = DefWindowProcW, .hInstance = GetModuleHandleW(NULL), .lpszClassName = L"wbgames"};
    RegisterClassW(&type);
    HWND window = CreateWindowW(L"wbgames", L"wbgames", WS_OVERLAPPEDWINDOW, 0, 0, 200, 100, NULL, NULL, type.hInstance, NULL);
    ShowWindow(window, SW_SHOW);
    SetForegroundWindow(window);
    return window;
}

static void pump(void) {
    MSG message;
    while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE)) {
        DispatchMessageW(&message);
    }
}

/* Kunos titles. */
static int kunos(int seconds) {
    IDirectInput8W *input = open_input();
    if (!input) return 1;
    CHECK("enum-devices", IDirectInput8_EnumDevices(input, DI8DEVCLASS_GAMECTRL, pick_by_product, NULL, DIEDFL_ATTACHEDONLY));
    EXPECT("finds the G29 by USB id", candidates == 1);

    IDirectInputDevice8W *wheel = NULL;
    CHECK("create-device", IDirectInput8_CreateDevice(input, &chosen, &wheel, NULL));

    DIPROPDWORD vidpid = {{sizeof(vidpid), sizeof(DIPROPHEADER), 0, DIPH_DEVICE}, 0};
    CHECK("get-vidpid", IDirectInputDevice8_GetProperty(wheel, DIPROP_VIDPID, &vidpid.diph));
    printf("vidpid %08lx\n", vidpid.dwData);
    EXPECT("vidpid is the G29", LOWORD(vidpid.dwData) == 0x046d && HIWORD(vidpid.dwData) == 0xc24f);

    DIPROPGUIDANDPATH path = {{sizeof(path), sizeof(DIPROPHEADER), 0, DIPH_DEVICE}};
    CHECK("get-path", IDirectInputDevice8_GetProperty(wheel, DIPROP_GUIDANDPATH, &path.diph));
    printf("path %ls\n", path.wszPath);

    DIPROPSTRING name = {{sizeof(name), sizeof(DIPROPHEADER), 0, DIPH_DEVICE}};
    CHECK("get-name", IDirectInputDevice8_GetProperty(wheel, DIPROP_PRODUCTNAME, &name.diph));
    printf("name %ls\n", name.wsz);

    HWND window = make_window();
    CHECK("set-format", IDirectInputDevice8_SetDataFormat(wheel, &c_dfDIJoystick2));
    CHECK("cooperative", IDirectInputDevice8_SetCooperativeLevel(wheel, window, DISCL_EXCLUSIVE | DISCL_FOREGROUND));

    DIPROPDWORD autocenter = {{sizeof(autocenter), sizeof(DIPROPHEADER), 0, DIPH_DEVICE}, DIPROPAUTOCENTER_OFF};
    CHECK("autocenter-off", IDirectInputDevice8_SetProperty(wheel, DIPROP_AUTOCENTER, &autocenter.diph));

    pump();
    CHECK("acquire", IDirectInputDevice8_Acquire(wheel));
    CHECK("reset", IDirectInputDevice8_SendForceFeedbackCommand(wheel, DISFFC_RESET));
    CHECK("actuators-on", IDirectInputDevice8_SendForceFeedbackCommand(wheel, DISFFC_SETACTUATORSON));

    DWORD axes[1] = {DIJOFS_X};
    LONG direction[1] = {0};
    DICONSTANTFORCE constant = {0};
    DIEFFECT effect = {
        .dwSize = sizeof(effect),
        .dwFlags = DIEFF_CARTESIAN | DIEFF_OBJECTOFFSETS,
        .dwDuration = INFINITE,
        .dwGain = DI_FFNOMINALMAX,
        .dwTriggerButton = DIEB_NOTRIGGER,
        .cAxes = 1,
        .rgdwAxes = axes,
        .rglDirection = direction,
        .cbTypeSpecificParams = sizeof(constant),
        .lpvTypeSpecificParams = &constant,
    };
    IDirectInputEffect *force = NULL;
    CHECK("create-constant", IDirectInputDevice8_CreateEffect(wheel, &GUID_ConstantForce, &effect, &force, NULL));
    CHECK("download", IDirectInputEffect_Download(force));
    CHECK("start-constant", IDirectInputEffect_Start(force, 1, 0));

    DICONDITION damping = {0, 800, 800, 10000, 10000, 0};
    DIEFFECT damper = effect;
    damper.cbTypeSpecificParams = sizeof(damping);
    damper.lpvTypeSpecificParams = &damping;
    IDirectInputEffect *damp = NULL;
    CHECK("create-damper", IDirectInputDevice8_CreateEffect(wheel, &GUID_Damper, &damper, &damp, NULL));
    CHECK("start-damper", IDirectInputEffect_Start(damp, 1, 0));

    /* About 333 updates a second, the rate Kunos physics runs at. */
    DWORD end = GetTickCount() + (DWORD)seconds * 1000, failures = 0, updates = 0;
    DIJOYSTATE2 state;
    while (GetTickCount() < end) {
        pump();
        constant.lMagnitude = (LONG)(6000 * sin(updates / 60.0));
        if (FAILED(IDirectInputEffect_SetParameters(force, &effect, DIEP_TYPESPECIFICPARAMS))) failures++;
        if (FAILED(IDirectInputDevice8_Poll(wheel)) ||
            FAILED(IDirectInputDevice8_GetDeviceState(wheel, sizeof(state), &state))) failures++;
        updates++;
        Sleep(3);
    }
    printf("updates %lu failures %lu\n", updates, failures);
    EXPECT("updates never fail", failures == 0);

    DWORD ff_state = 0;
    CHECK("ff-state", IDirectInputDevice8_GetForceFeedbackState(wheel, &ff_state));
    printf("ff-state %08lx\n", ff_state);

    printf("pausing\n");
    CHECK("pause", IDirectInputDevice8_SendForceFeedbackCommand(wheel, DISFFC_PAUSE));
    Sleep(300);
    CHECK("continue", IDirectInputDevice8_SendForceFeedbackCommand(wheel, DISFFC_CONTINUE));
    Sleep(100);

    CHECK("stop-all", IDirectInputDevice8_SendForceFeedbackCommand(wheel, DISFFC_STOPALL));
    IDirectInputEffect_Release(damp);
    IDirectInputEffect_Release(force);
    CHECK("unacquire", IDirectInputDevice8_Unacquire(wheel));
    IDirectInputDevice8_Release(wheel);
    IDirectInput8_Release(input);
    DestroyWindow(window);
    return 0;
}

/* BeamNG.drive. */
static IDirectInput8W *beam_input;
static GUID beam_wheel;
static int beam_found;

static BOOL CALLBACK pick_by_caps(const DIDEVICEINSTANCEW *device, void *context) {
    (void)context;
    IDirectInputDevice8W *candidate = NULL;
    if (FAILED(IDirectInput8_CreateDevice(beam_input, &device->guidInstance, &candidate, NULL))) return DIENUM_CONTINUE;
    DIDEVCAPS caps = {.dwSize = sizeof(caps)};
    if (SUCCEEDED(IDirectInputDevice8_GetCapabilities(candidate, &caps)) && (caps.dwFlags & DIDC_FORCEFEEDBACK)) {
        printf("force feedback device type=%08lx axes=%lu\n", device->dwDevType, caps.dwAxes);
        beam_wheel = device->guidInstance;
        beam_found++;
    }
    IDirectInputDevice8_Release(candidate);
    return DIENUM_CONTINUE;
}

static int beamng(int seconds) {
    beam_input = open_input();
    if (!beam_input) return 1;
    CHECK("enum-all", IDirectInput8_EnumDevices(beam_input, DI8DEVCLASS_ALL, pick_by_caps, NULL, DIEDFL_ATTACHEDONLY));
    EXPECT("one force feedback device", beam_found == 1);

    IDirectInputDevice8W *wheel = NULL;
    CHECK("create-device", IDirectInput8_CreateDevice(beam_input, &beam_wheel, &wheel, NULL));
    CHECK("set-format", IDirectInputDevice8_SetDataFormat(wheel, &c_dfDIJoystick));
    CHECK("cooperative", IDirectInputDevice8_SetCooperativeLevel(wheel, GetDesktopWindow(), DISCL_EXCLUSIVE | DISCL_BACKGROUND));
    DIPROPDWORD buffer = {{sizeof(buffer), sizeof(DIPROPHEADER), 0, DIPH_DEVICE}, 128};
    CHECK("set-buffer", IDirectInputDevice8_SetProperty(wheel, DIPROP_BUFFERSIZE, &buffer.diph));
    DIPROPDWORD autocenter = {{sizeof(autocenter), sizeof(DIPROPHEADER), 0, DIPH_DEVICE}, DIPROPAUTOCENTER_OFF};
    CHECK("autocenter-off", IDirectInputDevice8_SetProperty(wheel, DIPROP_AUTOCENTER, &autocenter.diph));
    CHECK("acquire", IDirectInputDevice8_Acquire(wheel));

    DWORD axes[2] = {DIJOFS_X, DIJOFS_Y};
    LONG direction[2] = {9000, 0}; /* polar: from the east, so along X */
    DICONSTANTFORCE constant = {0};
    DIEFFECT effect = {
        .dwSize = sizeof(effect),
        .dwFlags = DIEFF_POLAR | DIEFF_OBJECTOFFSETS,
        .dwDuration = INFINITE,
        .dwGain = DI_FFNOMINALMAX,
        .dwTriggerButton = DIEB_NOTRIGGER,
        .cAxes = 2,
        .rgdwAxes = axes,
        .rglDirection = direction,
        .cbTypeSpecificParams = sizeof(constant),
        .lpvTypeSpecificParams = &constant,
    };
    IDirectInputEffect *force = NULL;
    CHECK("create-polar-constant", IDirectInputDevice8_CreateEffect(wheel, &GUID_ConstantForce, &effect, &force, NULL));

    DWORD end = GetTickCount() + (DWORD)seconds * 1000, failures = 0, updates = 0, events = 0;
    while (GetTickCount() < end) {
        constant.lMagnitude = (LONG)(7000 * sin(updates / 80.0));
        if (FAILED(IDirectInputEffect_SetParameters(force, &effect, DIEP_TYPESPECIFICPARAMS | DIEP_START))) failures++;
        DIDEVICEOBJECTDATA data[32];
        DWORD count = 32;
        HRESULT result = IDirectInputDevice8_GetDeviceData(wheel, sizeof(DIDEVICEOBJECTDATA), data, &count, 0);
        if (FAILED(result)) failures++; else events += count;
        updates++;
        Sleep(2);
    }
    printf("updates %lu failures %lu events %lu\n", updates, failures, events);
    EXPECT("updates never fail", failures == 0);

    CHECK("stop", IDirectInputEffect_Stop(force));
    IDirectInputEffect_Release(force);
    IDirectInputDevice8_Unacquire(wheel);
    IDirectInputDevice8_Release(wheel);
    IDirectInput8_Release(beam_input);
    return 0;
}

/* SDL. */
#define MAX_OBJECTS 64
static DIOBJECTDATAFORMAT sdl_objects[MAX_OBJECTS];
static DWORD sdl_object_count, sdl_offset, sdl_actuators[4], sdl_actuator_count;

static BOOL CALLBACK collect_object(const DIDEVICEOBJECTINSTANCEW *object, void *context) {
    (void)context;
    if (sdl_object_count == MAX_OBJECTS) return DIENUM_STOP;
    DWORD type = DIDFT_GETTYPE(object->dwType);
    if (!(type & (DIDFT_AXIS | DIDFT_BUTTON | DIDFT_POV))) return DIENUM_CONTINUE;
    DIOBJECTDATAFORMAT *slot = &sdl_objects[sdl_object_count++];
    slot->pguid = NULL;
    slot->dwOfs = sdl_offset;
    slot->dwType = DIDFT_MAKEINSTANCE(DIDFT_GETINSTANCE(object->dwType)) | (object->dwType & (DIDFT_AXIS | DIDFT_BUTTON | DIDFT_POV)) | DIDFT_OPTIONAL;
    slot->dwFlags = 0;
    if ((object->dwFlags & DIDOI_FFACTUATOR) && sdl_actuator_count < 4) {
        sdl_actuators[sdl_actuator_count++] = sdl_offset;
    }
    sdl_offset += (type & DIDFT_BUTTON) ? 1 : 4;
    return DIENUM_CONTINUE;
}

static int sdl(int seconds) {
    IDirectInput8W *input = open_input();
    if (!input) return 1;
    CHECK("enum-devices", IDirectInput8_EnumDevices(input, DI8DEVCLASS_GAMECTRL, pick_by_product, NULL, DIEDFL_ATTACHEDONLY));
    EXPECT("one wheel", candidates == 1);
    IDirectInputDevice8W *wheel = NULL;
    CHECK("create-device", IDirectInput8_CreateDevice(input, &chosen, &wheel, NULL));

    DIPROPGUIDANDPATH path = {{sizeof(path), sizeof(DIPROPHEADER), 0, DIPH_DEVICE}};
    CHECK("get-path", IDirectInputDevice8_GetProperty(wheel, DIPROP_GUIDANDPATH, &path.diph));
    EXPECT("not mistaken for an XInput pad", wcsstr(path.wszPath, L"IG_") == NULL);

    CHECK("enum-objects", IDirectInputDevice8_EnumObjects(wheel, collect_object, NULL, DIDFT_ALL));
    printf("objects %lu actuators %lu\n", sdl_object_count, sdl_actuator_count);
    EXPECT("the wheel axis is an actuator", sdl_actuator_count >= 1);

    sdl_offset = (sdl_offset + 3) & ~3UL;
    DIDATAFORMAT format = {sizeof(DIDATAFORMAT), sizeof(DIOBJECTDATAFORMAT), DIDF_ABSAXIS, sdl_offset, sdl_object_count, sdl_objects};
    CHECK("custom-format", IDirectInputDevice8_SetDataFormat(wheel, &format));
    CHECK("cooperative", IDirectInputDevice8_SetCooperativeLevel(wheel, GetDesktopWindow(), DISCL_EXCLUSIVE | DISCL_BACKGROUND));
    DIPROPDWORD gain = {{sizeof(gain), sizeof(DIPROPHEADER), 0, DIPH_DEVICE}, 7500};
    CHECK("set-gain", IDirectInputDevice8_SetProperty(wheel, DIPROP_FFGAIN, &gain.diph));
    CHECK("acquire", IDirectInputDevice8_Acquire(wheel));

    LONG direction[1] = {1};
    DICONSTANTFORCE constant = {6000};
    DIEFFECT effect = {
        .dwSize = sizeof(effect),
        .dwFlags = DIEFF_CARTESIAN | DIEFF_OBJECTOFFSETS,
        .dwDuration = INFINITE,
        .dwGain = DI_FFNOMINALMAX,
        .dwTriggerButton = DIEB_NOTRIGGER,
        .cAxes = 1,
        .rgdwAxes = &sdl_actuators[0],
        .rglDirection = direction,
        .cbTypeSpecificParams = sizeof(constant),
        .lpvTypeSpecificParams = &constant,
    };
    IDirectInputEffect *force = NULL;
    CHECK("create-constant-on-actuator", IDirectInputDevice8_CreateEffect(wheel, &GUID_ConstantForce, &effect, &force, NULL));
    CHECK("start-constant", IDirectInputEffect_Start(force, 1, 0));

    DIPERIODIC wave = {3000, 0, 0, 100000}; /* 10 Hz */
    DIEFFECT periodic = effect;
    periodic.cbTypeSpecificParams = sizeof(wave);
    periodic.lpvTypeSpecificParams = &wave;
    IDirectInputEffect *rumble = NULL;
    CHECK("create-sine", IDirectInputDevice8_CreateEffect(wheel, &GUID_Sine, &periodic, &rumble, NULL));
    CHECK("start-sine", IDirectInputEffect_Start(rumble, 1, 0));

    BYTE state[256];
    DWORD end = GetTickCount() + (DWORD)seconds * 1000, failures = 0, polls = 0;
    while (GetTickCount() < end) {
        if (FAILED(IDirectInputDevice8_Poll(wheel)) || FAILED(IDirectInputDevice8_GetDeviceState(wheel, format.dwDataSize, state))) failures++;
        polls++;
        Sleep(4);
    }
    printf("polls %lu failures %lu first-axis %ld\n", polls, failures, *(LONG *)state);
    EXPECT("polls never fail", failures == 0);

    CHECK("stop-sine", IDirectInputEffect_Stop(rumble));
    CHECK("stop-constant", IDirectInputEffect_Stop(force));
    IDirectInputEffect_Release(rumble);
    IDirectInputEffect_Release(force);
    IDirectInputDevice8_Unacquire(wheel);
    IDirectInputDevice8_Release(wheel);
    IDirectInput8_Release(input);
    return 0;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    const char *profile = argc > 1 ? argv[1] : "kunos";
    int seconds = argc > 2 ? atoi(argv[2]) : 2;
    printf("profile %s, %d-bit\n", profile, (int)sizeof(void *) * 8);
    int result = strcmp(profile, "kunos") == 0    ? kunos(seconds)
                 : strcmp(profile, "beamng") == 0 ? beamng(seconds)
                 : strcmp(profile, "sdl") == 0    ? sdl(seconds)
                                                  : (printf("FAIL unknown profile\n"), 1);
    if (result == 0) printf("done\n");
    return result;
}
