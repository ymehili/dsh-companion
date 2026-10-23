# Mac DSH appearance, native iPhone mechanics — version 0.4

The user's supplied sidebar screenshot is the visual target: a **flat rail**, not Apple's default grouped cards. Preserve the leading whale/wordmark, full-width New Session, inline search, compact workspace/title/status rows, restrained selection fill, Working/Settled hierarchy and bottom connection footer. Scale typography/touch areas for a phone rather than reproducing desktop pixels blindly.

Native components and native appearance are separate choices. SwiftUI List/Button/TextField can be styled like DSH without replacing their interaction mechanics. Version 0.4 corrects the 0.3 overcorrection toward generic grouped iOS presentation.

| Area | Implementation |
| --- | --- |
| Navigation | Native NavigationSplitView/NavigationLink, system edge-back animation and cancellation; no global custom drag/offset drawer |
| Rail | Plain native List, transparent rows on DSH colors; no rounded white shelf cards |
| Header | Leading vector wordmark; decorative iOS 26 toolbar shared-glass background explicitly hidden |
| New Session | Full-width native bordered Button with restrained DSH tint and rectangular rounded border |
| Search | Inline native TextField after New Session, real focus/keyboard handling, not a navigation-bar search pill |
| Threads | Two-line workspace/title/status; real registered workspace names and a subtle last-selected fill |
| Shelves | Native Section/DisclosureGroup with compact labels and genuine counts; collapse does not invent membership |
| Footer | Fixed Mac-connection label and native menu; no fabricated account identity |
| Chat | DSH canvas/user-bubble treatment, native segmented Picker, disclosure activity and app-specific native Markdown |
| Composer/settings | Native TextField, PhotosPicker, Button, Menu, sheets/forms and stock navigation |

## Data parity

Use both the session/Inbox feeds **and workspace/follow**. Before grouping, exclude subagent children, non-current blanks and the core archive registry. The old omission of this visibility step inflated Inbox counts. Missing facts use the same fallback as the Mac; existing facts and projected pending requests are preserved. The same registry supplies workspace display names.

The live parity probe compares exact shelf session-ID sets for shared captured inputs. Counts naturally change during normal use and are not hard-coded to the screenshot. See the sidebar investigation for the 284→5 regression fixture and live result.

## Boundaries

Plugins, Automation tasks and the unsupported microphone are still omitted. Provider/permission changes, shelf mutations, general files, historical images and advanced team/question/plan editors remain Mac-only. Native transport/pairing and the Mac/tunnel configuration are unchanged. Additional physical-device/accessibility/Markdown boundaries remain in QA. Production follows the device's color scheme; explicit dark appearance is a DEBUG-only preview fixture.
