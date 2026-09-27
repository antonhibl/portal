# The C core asks each platform only for primitives

Portal's native module has two interfaces. Emacs calls the Lisp functions of ADR 0002, which `native/Core/emacs.c` hands to the C core. Each platform implements the platform interface, `native/Core/include/portal.h`: Swift on macOS today, and possibly a GTK implementation on Linux later. We shape the platform interface around what a platform must do, not around Portal's features. Examples are creating a native view, attaching it to a frame at a rectangle, loading a URL, posting a message to a page, pasting into a terminal, and giving a view the keyboard. Portal's own rules live once, in the core: target identity, input handoff, notification order, the bridge queue, and toolbar state. The platform tells the core what happened, such as a key press, a message a page posted, or a title change, by calling core functions. A new platform then implements a short list of primitives, and tests run the real core against a fake platform.

We apply four rules. First, a platform operation must be something the core cannot build from primitives it already has: to draw a rectangle, a triangle and a polygon, ask for a line. Second, two operations merge only when they are one capability; a string verb chosen at runtime is not a merge (ADR 0002). Third, a platform calls into the core only on the thread that runs module calls, and never reaches Emacs; records to Emacs go through the core's notification pipe. Fourth, the core has one implementation and one caller, `emacs.c`, so it needs no portable interface of its own beyond the Lisp functions.

## Considered Options

- **A platform interface that mirrors the Lisp functions.** This is what the first portable-core task produced, to move the bindings into C without moving logic. As an end state, it would make every platform reimplement Portal's rules behind the same 19 operations. We keep it only as the starting point that the later tasks reduce.
- **One generic call with a verb and JSON arguments.** This was rejected for the same reasons as in ADR 0002. It hides the platform's real obligations and checks them only at runtime.

## Consequences

Each remaining portable-core task moves one area of logic into the core. It removes that area's Lisp-shaped operations from `portal.h` and adds only the primitives and events the core needs. Lisp functions keep their names and behavior throughout.
