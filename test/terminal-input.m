/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Test-only event injection inside the disposable Emacs process.  Exercises
   AppKit event dispatch without Accessibility permission or global key events. */
#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#include <emacs-module.h>
#include <stdlib.h>

int plugin_is_GPL_compatible;
static __weak NSWindow *explicitWindow;

static NSWindow *activeWindow(void)
{
    if (explicitWindow) return explicitWindow;
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

static emacs_value targetFrame(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
    (void)nargs; (void)data;
    explicitWindow = nil;
    if (!env->is_not_nil(env, args[0])) return env->intern(env, "t");
    ptrdiff_t size = 0;
    if (!env->copy_string_contents(env, args[0], NULL, &size)) return env->intern(env, "nil");
    char *bytes = malloc((size_t)size);
    if (!bytes) return env->intern(env, "nil");
    if (!env->copy_string_contents(env, args[0], bytes, &size)) { free(bytes); return env->intern(env, "nil"); }
    NSString *title = [NSString stringWithUTF8String:bytes];
    free(bytes);
    for (NSWindow *window in NSApp.windows) {
        if ([window.title isEqualToString:title]) { explicitWindow = window; break; }
    }
    return env->intern(env, explicitWindow ? "t" : "nil");
}

static NSArray<NSView *> *descendants(NSView *root)
{
    NSMutableArray<NSView *> *result = [NSMutableArray array];
    for (NSView *child in root.subviews) {
        [result addObject:child];
        [result addObjectsFromArray:descendants(child)];
    }
    return result;
}

static emacs_value focusWeb(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
    (void)nargs; (void)args; (void)data;
    NSWindow *window = activeWindow();
    for (NSView *view in descendants(window.contentView)) {
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
        if (character <= 31) {
            // Match AppKit's unmodified character for control punctuation too
            // (e.g. C-] is byte 29, but charactersIgnoringModifiers is "]").
            character += character >= 1 && character <= 26 ? 'a' - 1 : '@';
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

// Asynchronous JS inspection stays inside this test module. No emacs_env is
// captured by WebKit completions, and the production editor has no eval API.
static NSString *webResult;
static emacs_value webEval(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
    (void)nargs; (void)data;
    if (!env->is_not_nil(env, args[0])) {
        if (!webResult) return env->intern(env, "nil");
        return env->make_string(env, webResult.UTF8String, (ptrdiff_t)[webResult lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
    }
    ptrdiff_t size = 0;
    if (!env->copy_string_contents(env, args[0], NULL, &size)) return env->intern(env, "nil");
    char *bytes = malloc((size_t)size);
    if (!bytes) return env->intern(env, "nil");
    if (!env->copy_string_contents(env, args[0], bytes, &size)) { free(bytes); return env->intern(env, "nil"); }
    NSString *script = [NSString stringWithUTF8String:bytes];
    free(bytes);
    webResult = nil;
    for (NSView *view in descendants(activeWindow().contentView)) {
        if ([view isKindOfClass:WKWebView.class] && !view.isHiddenOrHasHiddenAncestor) {
            [(WKWebView *)view callAsyncJavaScript:script arguments:@{} inFrame:nil
                inContentWorld:WKContentWorld.pageWorld completionHandler:^(id value, NSError *error) {
                    NSDictionary *result = error ? @{ @"error": error.localizedDescription }
                        : @{ @"value": value ?: NSNull.null };
                    NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingFragmentsAllowed error:nil];
                    webResult = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
                }];
            return env->intern(env, "t");
        }
    }
    return env->intern(env, "nil");
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
    args[0] = env->intern(env, "portal-test-web-eval");
    args[1] = env->make_function(env, 1, 1, webEval,
        "Evaluate SCRIPT in the visible webview; nil retrieves the async JSON result.", NULL);
    env->funcall(env, env->intern(env, "fset"), 2, args);
    args[0] = env->intern(env, "portal-test-native-target-frame");
    args[1] = env->make_function(env, 1, 1, targetFrame,
        "Target a frame with TITLE for local test injection; nil restores active-window targeting.", NULL);
    env->funcall(env, env->intern(env, "fset"), 2, args);
    return 0;
}
