/*
 * A stand-in for a racing game, used to test the proxy under Wine with no wheel.
 * It uses DirectInput the way sims do, and prints one line per step, so a test
 * script can check every part of the path.
 *
 * Usage: wbprobe [hold-seconds]
 */
#define CINTERFACE
#define COBJMACROS
#define DIRECTINPUT_VERSION 0x0800
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dinput.h>
#include <stdio.h>
#include <stdlib.h>

static GUID found;
static int wheels;
static int effects_listed;
static int objects_listed;

static BOOL CALLBACK on_device(const DIDEVICEINSTANCEA *device, void *context) {
    (void)context;
    printf("device name=\"%s\" product=%08lx type=%08lx\n", device->tszProductName, device->guidProduct.Data1,
           device->dwDevType);
    if ((device->dwDevType & 0xff) == DI8DEVTYPE_DRIVING) {
        found = device->guidInstance;
        wheels++;
    }
    return DIENUM_CONTINUE;
}

static BOOL CALLBACK on_effect(const DIEFFECTINFOA *effect, void *context) {
    (void)context, (void)effect;
    effects_listed++;
    return DIENUM_CONTINUE;
}

static BOOL CALLBACK on_object(const DIDEVICEOBJECTINSTANCEA *object, void *context) {
    (void)context, (void)object;
    objects_listed++;
    return DIENUM_CONTINUE;
}

#define CHECK(step, call)                                                  \
    do {                                                                   \
        HRESULT result = (call);                                           \
        printf("%s %s 0x%08lx\n", FAILED(result) ? "FAIL" : "ok", step, (unsigned long)result); \
        fflush(stdout);                                                    \
        if (FAILED(result)) {                                              \
            return 1;                                                      \
        }                                                                  \
    } while (0)

int main(int argc, char **argv) {
    int hold_seconds = argc > 1 ? atoi(argv[1]) : 3;
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("pointer-bits %d\n", (int)sizeof(void *) * 8);

    IDirectInput8A *input = NULL;
    CHECK("create", DirectInput8Create(GetModuleHandleA(NULL), DIRECTINPUT_VERSION, &IID_IDirectInput8A, (void **)&input, NULL));
    CHECK("enum-devices", IDirectInput8_EnumDevices(input, DI8DEVCLASS_GAMECTRL, on_device, NULL, DIEDFL_ATTACHEDONLY | DIEDFL_FORCEFEEDBACK));
    printf("wheels %d\n", wheels);
    if (wheels != 1) {
        printf("FAIL expected exactly one wheel\n");
        return 1;
    }

    IDirectInputDevice8A *wheel = NULL;
    CHECK("create-device", IDirectInput8_CreateDevice(input, &found, &wheel, NULL));
    CHECK("set-format", IDirectInputDevice8_SetDataFormat(wheel, &c_dfDIJoystick2));
    CHECK("cooperative", IDirectInputDevice8_SetCooperativeLevel(wheel, GetDesktopWindow(), DISCL_EXCLUSIVE | DISCL_BACKGROUND));

    DIDEVCAPS caps = {.dwSize = sizeof(caps)};
    CHECK("capabilities", IDirectInputDevice8_GetCapabilities(wheel, &caps));
    printf("caps axes=%lu buttons=%lu povs=%lu force-feedback=%d\n", caps.dwAxes, caps.dwButtons, caps.dwPOVs,
           (caps.dwFlags & DIDC_FORCEFEEDBACK) != 0);

    CHECK("enum-objects", IDirectInputDevice8_EnumObjects(wheel, on_object, NULL, DIDFT_ALL));
    CHECK("enum-effects", IDirectInputDevice8_EnumEffects(wheel, on_effect, NULL, DIEFT_ALL));
    printf("objects %d effects %d\n", objects_listed, effects_listed);

    DIPROPRANGE range = {{sizeof(range), sizeof(DIPROPHEADER), DIJOFS_X, DIPH_BYOFFSET}, -32768, 32767};
    CHECK("set-range", IDirectInputDevice8_SetProperty(wheel, DIPROP_RANGE, &range.diph));
    DIPROPDWORD gain = {{sizeof(gain), sizeof(DIPROPHEADER), 0, DIPH_DEVICE}, 10000};
    CHECK("set-gain", IDirectInputDevice8_SetProperty(wheel, DIPROP_FFGAIN, &gain.diph));
    DIPROPDWORD buffer = {{sizeof(buffer), sizeof(DIPROPHEADER), 0, DIPH_DEVICE}, 64};
    CHECK("set-buffer", IDirectInputDevice8_SetProperty(wheel, DIPROP_BUFFERSIZE, &buffer.diph));

    CHECK("acquire", IDirectInputDevice8_Acquire(wheel));

    /* A constant force from the right, as sims send for self-aligning torque. */
    DWORD axes[1] = {DIJOFS_X};
    LONG direction[1] = {1};
    DICONSTANTFORCE constant = {5000};
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
    CHECK("create-effect", IDirectInputDevice8_CreateEffect(wheel, &GUID_ConstantForce, &effect, &force, NULL));
    CHECK("start-effect", IDirectInputEffect_Start(force, 1, 0));

    DIJOYSTATE2 state;
    DWORD end = GetTickCount() + (DWORD)hold_seconds * 1000;
    int polls = 0;
    while (GetTickCount() < end) {
        IDirectInputDevice8_Poll(wheel);
        HRESULT result = IDirectInputDevice8_GetDeviceState(wheel, sizeof(state), &state);
        if (FAILED(result)) {
            printf("FAIL get-state 0x%08lx\n", (unsigned long)result);
            return 1;
        }
        polls++;
        Sleep(4);
    }
    printf("state polls=%d x=%ld y=%ld rz=%ld slider=%ld pov=%ld pov1=%ld\n", polls, state.lX, state.lY, state.lRz,
           state.rglSlider[0], (long)state.rgdwPOV[0], (long)state.rgdwPOV[1]);

    /* Stop polling with the force still on: the helper must release the motor. */
    printf("stalling\n");
    Sleep(1000);
    printf("resuming\n");
    IDirectInputDevice8_Poll(wheel);

    CHECK("stop-effect", IDirectInputEffect_Stop(force));
    IDirectInputEffect_Release(force);
    CHECK("unacquire", IDirectInputDevice8_Unacquire(wheel));
    IDirectInputDevice8_Release(wheel);
    IDirectInput8_Release(input);
    printf("done\n");
    return 0;
}
