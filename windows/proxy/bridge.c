/* Finds and maps the shared memory file, and tells whether the helper is alive. */
#include "wb_proxy.h"

#include <stdarg.h>
#include <stdio.h>

static HMODULE module;
static char module_dir[MAX_PATH];
static wchar_t bridge_path[MAX_PATH];
static wchar_t log_path[MAX_PATH];

static wb_bridge *bridge;
static DWORD last_attempt;

static uint32_t seen_tick;
static DWORD seen_tick_at;

void wb_set_module(HMODULE handle) {
    module = handle;
    GetModuleFileNameA(module, module_dir, sizeof(module_dir));
    char *slash = strrchr(module_dir, '\\');
    if (slash) {
        slash[1] = 0;
    }
}

const char *wb_module_dir(void) { return module_dir; }

/* The installer writes the bridge file's Windows path next to this DLL. */
static void load_config(void) {
    if (bridge_path[0]) {
        return;
    }
    char config[MAX_PATH + 32];
    snprintf(config, sizeof(config), "%swheelbridge.ini", module_dir);
    FILE *file = fopen(config, "rb");
    if (!file) {
        return;
    }
    char line[MAX_PATH * 3] = {0};
    size_t length = fread(line, 1, sizeof(line) - 1, file);
    fclose(file);
    while (length && (line[length - 1] == '\n' || line[length - 1] == '\r')) {
        line[--length] = 0;
    }
    if (!MultiByteToWideChar(CP_UTF8, 0, line, -1, bridge_path, MAX_PATH)) {
        bridge_path[0] = 0;
        return;
    }
    wcscpy(log_path, bridge_path);
    wchar_t *slash = wcsrchr(log_path, L'\\');
    if (slash) {
        wcscpy(slash + 1, L"proxy.log");
    }
}

/* Startup and errors only. Writing per event would cost frames and fill disks. */
void wb_log(const char *format, ...) {
    load_config();
    if (!log_path[0]) {
        return;
    }
    HANDLE file = CreateFileW(log_path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                              OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) {
        return;
    }
    char line[512];
    int prefix = snprintf(line, sizeof(line), "[%lu] ", (unsigned long)GetCurrentProcessId());
    va_list arguments;
    va_start(arguments, format);
    int body = vsnprintf(line + prefix, sizeof(line) - prefix - 1, format, arguments);
    va_end(arguments);
    if (body > 0) {
        int total = prefix + (body < (int)sizeof(line) - prefix - 1 ? body : (int)sizeof(line) - prefix - 2);
        line[total++] = '\n';
        DWORD written;
        WriteFile(file, line, total, &written, NULL);
    }
    CloseHandle(file);
}

/* Returns the mapping, retrying at most once a second until the helper has made it. */
wb_bridge *wb_bridge_get(void) {
    if (bridge) {
        return bridge;
    }
    DWORD now = GetTickCount();
    if (last_attempt && now - last_attempt < 1000) {
        return NULL;
    }
    last_attempt = now;
    load_config();
    if (!bridge_path[0]) {
        return NULL;
    }
    HANDLE file = CreateFileW(bridge_path, GENERIC_READ | GENERIC_WRITE,
                              FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
                              FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) {
        return NULL;
    }
    HANDLE mapping = CreateFileMappingW(file, NULL, PAGE_READWRITE, 0, WB_FILE_SIZE, NULL);
    CloseHandle(file);
    if (!mapping) {
        return NULL;
    }
    wb_bridge *view = MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, WB_FILE_SIZE);
    CloseHandle(mapping);
    if (!view) {
        return NULL;
    }
    if (view->magic != WB_MAGIC || view->version != WB_VERSION) {
        wb_log("bridge file has version %u, this proxy needs %u", view->version, WB_VERSION);
        UnmapViewOfFile(view);
        return NULL;
    }
    bridge = view;
    return bridge;
}

/* Reads the input block. Returns 0 if the helper has stopped updating it. */
int wb_bridge_input(wb_input *out) {
    wb_bridge *shared = wb_bridge_get();
    if (!shared || !wb_read(&shared->input, out, sizeof(*out))) {
        return 0;
    }
    DWORD now = GetTickCount();
    if (out->tick != seen_tick || !seen_tick_at) {
        seen_tick = out->tick;
        seen_tick_at = now;
    }
    return now - seen_tick_at < WB_STALE_MS;
}

/* True if a helper is running and has a wheel. Waits briefly to see its tick
 * move, because a file left by a helper that has since died looks the same. */
int wb_wheel_available(wb_input *out) {
    wb_bridge *shared = wb_bridge_get();
    if (!shared || !wb_read(&shared->input, out, sizeof(*out))) {
        return 0;
    }
    uint32_t first = out->tick;
    for (int attempt = 0; attempt < 10; attempt++) {
        Sleep(5);
        if (wb_read(&shared->input, out, sizeof(*out)) && out->tick != first) {
            return out->connected != 0;
        }
    }
    return 0;
}
