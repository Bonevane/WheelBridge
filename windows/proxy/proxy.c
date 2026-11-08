/*
 * The dinput8.dll entry points and the IDirectInput8 wrapper.
 *
 * Everything except the wheel goes straight to Wine's real dinput8. If the
 * helper or the wheel is missing, the wheel goes through too, so installing
 * this can never leave a bottle worse off.
 */
#include "wb_proxy.h"

#include <stdio.h>

typedef HRESULT(WINAPI *create_fn)(HINSTANCE, DWORD, REFIID, void **, IUnknown *);
typedef HRESULT(WINAPI *class_object_fn)(REFCLSID, REFIID, void **);
typedef HRESULT(WINAPI *simple_fn)(void);

static HMODULE real_module;

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, void *reserved) {
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(instance);
        wb_set_module(instance);
    }
    return TRUE;
}

/* Bottle installs keep Wine's builtin beside us under a new name. A per-game
 * install has the builtin in system32 under its own name. */
HMODULE wb_real_dinput8(void) {
    if (real_module) {
        return real_module;
    }
    char path[MAX_PATH + 40];
    snprintf(path, sizeof(path), "%swheelbridge_dinput8_real.dll", wb_module_dir());
    real_module = LoadLibraryA(path);
    if (!real_module) {
        char system_dir[MAX_PATH];
        GetSystemDirectoryA(system_dir, sizeof(system_dir));
        snprintf(path, sizeof(path), "%s\\dinput8.dll", system_dir);
        HMODULE candidate = LoadLibraryA(path);
        HMODULE self = NULL;
        GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           (const char *)wb_real_dinput8, &self);
        real_module = candidate == self ? NULL : candidate;
    }
    if (!real_module) {
        wb_log("could not load the real dinput8");
    }
    return real_module;
}

typedef struct {
    const void *vtbl;
    LONG refs;
    int wide;
    IDirectInput8W *real; /* the A and W tables share a layout */
} wb_factory;

#define SELF(this) ((wb_factory *)(this))
#define REAL_VTBL(f) ((f)->real->lpVtbl)

static const IDirectInput8WVtbl factory_w;
static const IDirectInput8AVtbl factory_a;

static HRESULT STDMETHODCALLTYPE factory_query(IDirectInput8W *this, REFIID iid, void **out) {
    wb_factory *f = SELF(this);
    if (!out) {
        return E_POINTER;
    }
    if (IsEqualGUID(iid, &IID_IUnknown) || IsEqualGUID(iid, f->wide ? &IID_IDirectInput8W : &IID_IDirectInput8A)) {
        InterlockedIncrement(&f->refs);
        *out = this;
        return S_OK;
    }
    *out = NULL;
    return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE factory_add_ref(IDirectInput8W *this) {
    return InterlockedIncrement(&SELF(this)->refs);
}

static ULONG STDMETHODCALLTYPE factory_release(IDirectInput8W *this) {
    wb_factory *f = SELF(this);
    ULONG refs = InterlockedDecrement(&f->refs);
    if (!refs) {
        REAL_VTBL(f)->Release(f->real);
        HeapFree(GetProcessHeap(), 0, f);
    }
    return refs;
}

static int matches_virtual(const wb_input *input, REFGUID guid) {
    GUID product;
    wb_product_guid(input, &product);
    return IsEqualGUID(guid, &wb_instance_guid) || IsEqualGUID(guid, &product);
}

static HRESULT STDMETHODCALLTYPE factory_create_device(IDirectInput8W *this, REFGUID guid,
                                                       LPDIRECTINPUTDEVICE8W *out, IUnknown *outer) {
    wb_factory *f = SELF(this);
    wb_input input;
    if (guid && out && wb_wheel_available(&input) && matches_virtual(&input, guid)) {
        return wb_device_create(f->wide, &input, (void **)out);
    }
    return REAL_VTBL(f)->CreateDevice(f->real, guid, out, outer);
}

typedef struct {
    void *callback;
    void *context;
    int wide;
    DWORD hidden_product;
} enum_filter;

/* Drops Wine's copy of the wheel, so a game does not see it twice. */
static BOOL CALLBACK filter_w(const DIDEVICEINSTANCEW *device, void *context) {
    enum_filter *filter = context;
    if (filter->hidden_product && device->guidProduct.Data1 == filter->hidden_product) {
        return DIENUM_CONTINUE;
    }
    return ((LPDIENUMDEVICESCALLBACKW)filter->callback)(device, filter->context);
}

static BOOL CALLBACK filter_a(const DIDEVICEINSTANCEA *device, void *context) {
    enum_filter *filter = context;
    if (filter->hidden_product && device->guidProduct.Data1 == filter->hidden_product) {
        return DIENUM_CONTINUE;
    }
    return ((LPDIENUMDEVICESCALLBACKA)filter->callback)(device, filter->context);
}

static int wants_wheel(DWORD device_type, DWORD flags) {
    (void)flags; /* it is attached and has force feedback, so every filter passes */
    return device_type == DI8DEVCLASS_ALL || device_type == DI8DEVCLASS_GAMECTRL ||
           device_type == DI8DEVTYPE_DRIVING;
}

static HRESULT STDMETHODCALLTYPE factory_enum_devices(IDirectInput8W *this, DWORD device_type,
                                                      LPDIENUMDEVICESCALLBACKW callback, void *context, DWORD flags) {
    wb_factory *f = SELF(this);
    if (!callback) {
        return DIERR_INVALIDPARAM;
    }
    enum_filter filter = {(void *)callback, context, f->wide, 0};
    wb_input input;
    if (wb_wheel_available(&input)) {
        filter.hidden_product = input.vendor_product;
        if (wants_wheel(device_type, flags)) {
            BOOL keep_going;
            if (f->wide) {
                DIDEVICEINSTANCEW info;
                info.dwSize = sizeof(info);
                wb_fill_instance(&input, &info, 1);
                keep_going = callback(&info, context);
            } else {
                DIDEVICEINSTANCEA info;
                info.dwSize = sizeof(info);
                wb_fill_instance(&input, &info, 0);
                keep_going = ((LPDIENUMDEVICESCALLBACKA)(void *)callback)(&info, context);
            }
            if (keep_going == DIENUM_STOP) {
                return DI_OK;
            }
        }
    }
    return REAL_VTBL(f)->EnumDevices(f->real, device_type,
                                     f->wide ? filter_w : (LPDIENUMDEVICESCALLBACKW)(void *)filter_a, &filter, flags);
}

static HRESULT STDMETHODCALLTYPE factory_get_status(IDirectInput8W *this, REFGUID guid) {
    wb_factory *f = SELF(this);
    wb_input input;
    if (guid && wb_wheel_available(&input) && matches_virtual(&input, guid)) {
        return DI_OK;
    }
    return REAL_VTBL(f)->GetDeviceStatus(f->real, guid);
}

static HRESULT STDMETHODCALLTYPE factory_control_panel(IDirectInput8W *this, HWND owner, DWORD flags) {
    wb_factory *f = SELF(this);
    return REAL_VTBL(f)->RunControlPanel(f->real, owner, flags);
}

static HRESULT STDMETHODCALLTYPE factory_initialize(IDirectInput8W *this, HINSTANCE instance, DWORD version) {
    wb_factory *f = SELF(this);
    return REAL_VTBL(f)->Initialize(f->real, instance, version);
}

static HRESULT STDMETHODCALLTYPE factory_find_device(IDirectInput8W *this, REFGUID type, LPCWSTR name, LPGUID out) {
    wb_factory *f = SELF(this);
    return REAL_VTBL(f)->FindDevice(f->real, type, name, out);
}

static HRESULT STDMETHODCALLTYPE factory_enum_semantics(IDirectInput8W *this, LPCWSTR user, LPDIACTIONFORMATW format,
                                                        LPDIENUMDEVICESBYSEMANTICSCBW callback, void *context,
                                                        DWORD flags) {
    wb_factory *f = SELF(this);
    return REAL_VTBL(f)->EnumDevicesBySemantics(f->real, user, format, callback, context, flags);
}

static HRESULT STDMETHODCALLTYPE factory_configure(IDirectInput8W *this, LPDICONFIGUREDEVICESCALLBACK callback,
                                                   LPDICONFIGUREDEVICESPARAMSW params, DWORD flags, void *data) {
    wb_factory *f = SELF(this);
    return REAL_VTBL(f)->ConfigureDevices(f->real, callback, params, flags, data);
}

static const IDirectInput8WVtbl factory_w = {
    factory_query,        factory_add_ref,       factory_release,   factory_create_device,
    factory_enum_devices, factory_get_status,    factory_control_panel, factory_initialize,
    factory_find_device,  factory_enum_semantics, factory_configure,
};

/* The A table has the same layout. Only pointer types differ. */
static const IDirectInput8AVtbl factory_a = {
    (void *)factory_query,        (void *)factory_add_ref,        (void *)factory_release,
    (void *)factory_create_device, (void *)factory_enum_devices,  (void *)factory_get_status,
    (void *)factory_control_panel, (void *)factory_initialize,    (void *)factory_find_device,
    (void *)factory_enum_semantics, (void *)factory_configure,
};

static HRESULT wrap_factory(int wide, void *real, void **out) {
    wb_factory *f = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*f));
    if (!f) {
        ((IUnknown *)real)->lpVtbl->Release((IUnknown *)real);
        return E_OUTOFMEMORY;
    }
    f->vtbl = wide ? (const void *)&factory_w : (const void *)&factory_a;
    f->refs = 1;
    f->wide = wide;
    f->real = real;
    *out = f;
    return S_OK;
}

HRESULT WINAPI DirectInput8Create(HINSTANCE instance, DWORD version, REFIID iid, void **out, IUnknown *outer) {
    HMODULE real = wb_real_dinput8();
    create_fn create = real ? (create_fn)(void *)GetProcAddress(real, "DirectInput8Create") : NULL;
    if (!create) {
        return E_FAIL;
    }
    void *inner = NULL;
    HRESULT result = create(instance, version, iid, &inner, outer);
    if (FAILED(result) || !inner || outer) {
        if (out) {
            *out = inner;
        }
        return result;
    }
    if (IsEqualGUID(iid, &IID_IDirectInput8W)) {
        return wrap_factory(1, inner, out);
    }
    if (IsEqualGUID(iid, &IID_IDirectInput8A)) {
        return wrap_factory(0, inner, out);
    }
    *out = inner;
    return result;
}

/* COM creation goes through a class factory, so that needs wrapping too. */
typedef struct {
    const IClassFactoryVtbl *vtbl;
    LONG refs;
    IClassFactory *real;
} wb_class_factory;

static HRESULT STDMETHODCALLTYPE class_query(IClassFactory *this, REFIID iid, void **out) {
    if (IsEqualGUID(iid, &IID_IUnknown) || IsEqualGUID(iid, &IID_IClassFactory)) {
        this->lpVtbl->AddRef(this);
        *out = this;
        return S_OK;
    }
    *out = NULL;
    return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE class_add_ref(IClassFactory *this) {
    return InterlockedIncrement(&((wb_class_factory *)this)->refs);
}

static ULONG STDMETHODCALLTYPE class_release(IClassFactory *this) {
    wb_class_factory *c = (wb_class_factory *)this;
    ULONG refs = InterlockedDecrement(&c->refs);
    if (!refs) {
        c->real->lpVtbl->Release(c->real);
        HeapFree(GetProcessHeap(), 0, c);
    }
    return refs;
}

static HRESULT STDMETHODCALLTYPE class_create(IClassFactory *this, IUnknown *outer, REFIID iid, void **out) {
    wb_class_factory *c = (wb_class_factory *)this;
    void *inner = NULL;
    HRESULT result = c->real->lpVtbl->CreateInstance(c->real, outer, iid, &inner);
    if (FAILED(result) || !inner || outer) {
        *out = inner;
        return result;
    }
    if (IsEqualGUID(iid, &IID_IDirectInput8W)) {
        return wrap_factory(1, inner, out);
    }
    if (IsEqualGUID(iid, &IID_IDirectInput8A)) {
        return wrap_factory(0, inner, out);
    }
    *out = inner;
    return result;
}

static HRESULT STDMETHODCALLTYPE class_lock(IClassFactory *this, BOOL lock) {
    wb_class_factory *c = (wb_class_factory *)this;
    return c->real->lpVtbl->LockServer(c->real, lock);
}

static const IClassFactoryVtbl class_vtbl = {class_query, class_add_ref, class_release, class_create, class_lock};

HRESULT WINAPI DllGetClassObject(REFCLSID clsid, REFIID iid, void **out) {
    HMODULE real = wb_real_dinput8();
    class_object_fn get = real ? (class_object_fn)(void *)GetProcAddress(real, "DllGetClassObject") : NULL;
    if (!get) {
        return CLASS_E_CLASSNOTAVAILABLE;
    }
    if (!IsEqualGUID(clsid, &CLSID_DirectInput8) || !IsEqualGUID(iid, &IID_IClassFactory)) {
        return get(clsid, iid, out);
    }
    IClassFactory *inner = NULL;
    HRESULT result = get(clsid, iid, (void **)&inner);
    if (FAILED(result)) {
        return result;
    }
    wb_class_factory *c = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*c));
    if (!c) {
        inner->lpVtbl->Release(inner);
        return E_OUTOFMEMORY;
    }
    c->vtbl = &class_vtbl;
    c->refs = 1;
    c->real = inner;
    *out = c;
    return S_OK;
}

static HRESULT forward(const char *name) {
    HMODULE real = wb_real_dinput8();
    simple_fn fn = real ? (simple_fn)(void *)GetProcAddress(real, name) : NULL;
    return fn ? fn() : S_OK;
}

/* Stays loaded: games may hold pointers into our tables after they release us. */
HRESULT WINAPI DllCanUnloadNow(void) { return S_FALSE; }
HRESULT WINAPI DllRegisterServer(void) { return forward("DllRegisterServer"); }
HRESULT WINAPI DllUnregisterServer(void) { return forward("DllUnregisterServer"); }
