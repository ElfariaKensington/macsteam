// Cloud error presentation patch: runs cloud_errors.js on sp.js in JavaScriptCore.
#include "steamui.h"
#include "../util/log.h"

#include <JavaScriptCore/JavaScript.h>
#include <stdlib.h>
#include <string.h>

static const unsigned char patcher_js[] = {
#include "cloud_errors_js.inc"
, 0 };

static int g_cloud_warned_once = 0;

char *sx_steamui_cloud_transform(const char *source, size_t len, size_t *out_len) {
    if (out_len)
        *out_len = 0;
    if (!source || len == 0 || memchr(source, 0, len) != NULL)
        return NULL;

    JSGlobalContextRef context = JSGlobalContextCreate(NULL);
    if (!context)
        return NULL;

    JSStringRef script = JSStringCreateWithUTF8CString((const char *)patcher_js);
    JSValueRef exception = NULL;
    JSValueRef value = JSEvaluateScript(context, script, NULL, NULL, 1, &exception);
    JSStringRelease(script);

    char *out = NULL;
    size_t result_len = 0;

    if (!exception && value && JSValueIsObject(context, value)) {
        JSStringRef input = JSStringCreateWithUTF8CString(source);
        JSValueRef arg = JSValueMakeString(context, input);
        JSStringRelease(input);

        JSObjectRef function = JSValueToObject(context, value, &exception);
        if (!exception && function && JSObjectIsFunction(context, function)) {
            value = JSObjectCallAsFunction(context, function, NULL, 1, &arg, &exception);
            if (!exception && value && JSValueIsString(context, value)) {
                JSStringRef result = JSValueToStringCopy(context, value, &exception);
                if (!exception && result) {
                    if (JSCheckScriptSyntax(context, result, NULL, 1, &exception)) {
                        size_t cap = JSStringGetMaximumUTF8CStringSize(result);
                        if (cap > 1) {
                            out = malloc(cap);
                            if (out) {
                                size_t written = JSStringGetUTF8CString(result, out, cap);
                                if (written > 1) {
                                    result_len = written - 1;
                                } else {
                                    free(out);
                                    out = NULL;
                                }
                            }
                        }
                    }
                    JSStringRelease(result);
                }
            }
        }
    }

    if (exception) {
        if (!__atomic_exchange_n(&g_cloud_warned_once, 1, __ATOMIC_RELAXED)) {
            JSStringRef message = JSValueToStringCopy(context, exception, NULL);
            char description[512] = "(unknown)";
            if (message) {
                JSStringGetUTF8CString(message, description, sizeof(description));
                JSStringRelease(message);
            }
            SX_WARN("steamui: Cloud error patch skipped: %s", description);
        }
        free(out);
        out = NULL;
    } else if (!out) {
        if (!__atomic_exchange_n(&g_cloud_warned_once, 1, __ATOMIC_RELAXED))
            SX_WARN("steamui: Cloud error patch produced no output; serving original sp.js");
    }

    JSGlobalContextRelease(context);

    if (out && result_len == len && memcmp(out, source, len) == 0) {
        free(out);
        return NULL;
    }
    if (out && out_len)
        *out_len = result_len;
    return out;
}

