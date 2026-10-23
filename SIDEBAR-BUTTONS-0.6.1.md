# Sidebar controls — 0.6.1/build 11

The user supplied an actual ChatGPT sidebar screenshot, especially for New Chat, search and settings. Its private conversation titles were not copied into source/fixtures.

The native DSH adaptation keeps the user's selected Mac-style branding, Inbox/Working/Settled and bottom-docked lower shelves, while moving controls to the observed locations:

- Top-right native circular search button; it reveals the existing native search field, and close clears search. While searching, all matching shelves share the main list; bottom docking resumes when search closes.
- Bottom-left blue capsule New Session button, outside the scrollable Inbox.
- Bottom-right gear opening actual DSH controls: connection status/reconnect, pairing, questions and approvals. It is a native menu, not a fabricated ChatGPT account/settings product.
- No disclosure arrows on individual conversations. Rows are native Buttons that update the same split-view selection; native NavigationSplitView transitions and edge-back remain system-owned. Shelf expansion arrows remain functional.

Initial complete regression run: **23 unit + 28 UI = 51 passed**, zero failures, including direct row navigation, reopening drafts, successful/cancelled native edge-back, bottom-dock position while scrolling, search keyboard dismissal and the new button positions/settings menu. Render was inspected, then the button sizes/material were tightened to match the reference more closely. The final exact refinement also passed all **51** tests, and its exported render was inspected.

Signature verification passed; **0.6.1/build 11 is installed and independently confirmed by device app inventory**, database sequence 3796. JEV's staged retry fix still requires the user's own Mac restart; no active work is restarted or automation state changed here.
