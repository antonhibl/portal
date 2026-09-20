/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Test-only event injection inside the disposable Emacs process.  Exercises
   AppKit event dispatch without Accessibility permission or global key events. */
#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#include <emacs-module.h>
#include <stdlib.h>

int plugin_is_GPL_compatible;

static NSWindow *activeWindow(void)
{
    static __weak NSWindow *lastWindow;
    NSWindow *window = NSApp.keyWindow;
    // The desktop app may regain activation between tool calls. Keep local
    // injection addressed to this disposable Emacs window in that case.
    if (!window) {
        window = NSApp.mainWindow ?: lastWindow;
        [window makeKeyWindow];
    }
    lastWindow = window;
    return window;
}

static emacs_value focusWeb(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
    (void)nargs; (void)args; (void)data;
    NSWindow *window = activeWindow();
    for (NSView *view in window.contentView.subviews) {
        if ([view isKindOfClass:WKWebView.class] && !view.isHiddenOrHasHiddenAncestor) {
            return env->intern(env, [window makeFirstResponder:view] ? "t" : "nil");
        }
    }
    return env->intern(env, "nil");
}

static emacs_value key(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
    emacs_value nilValue = env->intern(env, "nil");
    NSInteger code = env->extract_integer(env, args[0]);
    NSEventModifierFlags flags = (NSEventModifierFlags)env->extract_integer(env, args[1]);
    ptrdiff_t size = 0;
    if (!env->copy_string_contents(env, args[2], NULL, &size)) return nilValue;
    char *bytes = malloc((size_t)size);
    if (!bytes) return nilValue;
    if (!env->copy_string_contents(env, args[2], bytes, &size)) { free(bytes); return nilValue; }
    NSString *text = [[NSString alloc] initWithBytes:bytes length:(NSUInteger)(size - 1)
                                         encoding:NSUTF8StringEncoding];
    free(bytes);
    NSWindow *window = activeWindow();
    if (!window || !text) return nilValue;
    BOOL windowless = nargs > 3 && env->is_not_nil(env, args[3]);
    NSString *unmodified = text;
    if ((flags & NSEventModifierFlagControl) && text.length == 1) {
        unichar character = [text characterAtIndex:0];
        if (character >= 1 && character <= 26) {
            character += 'a' - 1;
            unmodified = [NSString stringWithCharacters:&character length:1];
        }
    }
    for (NSNumber *type in @[@(NSEventTypeKeyDown), @(NSEventTypeKeyUp)]) {
        NSEvent *event = [NSEvent keyEventWithType:type.unsignedIntegerValue
            location:NSZeroPoint modifierFlags:flags timestamp:NSProcessInfo.processInfo.systemUptime
            windowNumber:windowless ? 0 : window.windowNumber context:nil characters:text
            charactersIgnoringModifiers:unmodified isARepeat:NO keyCode:(unsigned short)code];
        if (data) [NSApp postEvent:event atStart:NO];
        else [NSApp sendEvent:event];
    }
    return env->intern(env, "t");
}

int emacs_module_init(struct emacs_runtime *runtime)
{
    emacs_env *env = runtime->get_environment(runtime);
    emacs_value args[] = {
        env->intern(env, "portal-test-native-key"),
        env->make_function(env, 3, 4, key, "Send an AppKit key event: CODE FLAGS TEXT &optional WINDOWLESS.", NULL)
    };
    env->funcall(env, env->intern(env, "fset"), 2, args);
    args[0] = env->intern(env, "portal-test-native-post-key");
    args[1] = env->make_function(env, 3, 4, key,
        "Queue an AppKit key event: CODE FLAGS TEXT &optional WINDOWLESS.", (void *)1);
    env->funcall(env, env->intern(env, "fset"), 2, args);
    args[0] = env->intern(env, "portal-test-native-focus-web");
    args[1] = env->make_function(env, 0, 0, focusWeb, "Focus the visible native webview.", NULL);
    env->funcall(env, env->intern(env, "fset"), 2, args);
    return 0;
}
