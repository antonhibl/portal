# One Portal view per buffer, following the selected pane

Every view kind uses the same placement rule. A buffer has at most one Portal view, and the view appears in the selected pane that shows the buffer. Other panes showing the same buffer display only its placeholder text. We chose this rule because a terminal session and a hosted app's document can each be drawn in only one place at a time, and every view kind must behave the same way. To see two web pages side by side, open two buffers.

## Considered Options

- **A native view in every pane showing the buffer.** Web views used to work this way, with each pane holding its own independent page. We dropped it because terminals and hosted apps cannot support it, and keeping it for web alone would give the kinds different lifecycles.
