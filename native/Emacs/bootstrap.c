/* SPDX-License-Identifier: GPL-3.0-or-later */
/* The C ABI entry point; module behaviour lives in Swift. */
#include "CEmacs.h"

int plugin_is_GPL_compatible;
extern int portal_swift_init(emacs_env *env);

int emacs_module_init(struct emacs_runtime *runtime)
{
    if (runtime->size < (ptrdiff_t) sizeof *runtime)
        return 1;
    emacs_env *env = runtime->get_environment(runtime);
    if (env->size < (ptrdiff_t) sizeof *env)
        return 2;
    return portal_swift_init(env);
}
