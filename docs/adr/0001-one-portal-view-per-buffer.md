# One Portal view per buffer, following the selected pane

Every buffer has at most one Portal view, shown in the selected pane displaying that buffer. While the minibuffer is selected, this means its return window, so previews there, such as Consult's, show their views. Other panes displaying the buffer show only placeholder text. This rule keeps all view kinds consistent: a terminal session or hosted app's document can appear in only one place at a time. For two web pages side by side, open two buffers.

## Considered Options

- **A native view in every pane showing the buffer.** Web views formerly gave each pane an independent page. We dropped this because terminals and hosted apps cannot support it; retaining it for web alone would give view kinds different lifecycles.
