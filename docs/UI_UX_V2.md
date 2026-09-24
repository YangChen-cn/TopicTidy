# macOS UI/UX V2

The full organizer remains a native `NavigationSplitView`. Its sidebar and toolbar use system materials and controls; the file list is a plain, selectable `List`. The menu bar panel stays compact. No custom glass overlays or opaque sidebar backgrounds are used, so system appearance and Reduce Transparency remain in control.

The regular menu bar panel is 340pt wide. Its primary action uses the short label “预览整理…”; the file count appears in the suggestion summary and again in the confirmation preview. The refresh control remains accessible by its full label and tooltip while showing only the icon in the compact panel.

## File interactions

- Select multiple files with the normal macOS Command/Shift selection gestures. The toolbar menu can show the selection in Finder, move it to an existing topic, or exclude it after confirmation.
- Drag a file or a selection from the list onto a topic in the sidebar. The payload contains only the active plan ID and member IDs. The service validates the saved plan and destination topic and applies the entire selection in one SQLite transaction. A failed member rolls back the whole edit. The drag never moves a file on disk.
- Space or the toolbar's eye button opens Quick Look for the selection. Individual file menus also offer Quick Look and Finder. Existing move, split, merge, rename, and exclude commands remain available.
- Preview, explicit confirmation, full-topic restrictions, durable move intent, and undo remain owned by `AppService`/`Operations`.

## Preferences and progress

The Settings scene and menu bar settings page share controls for General (scan and organize directories), Automation (auto-confirm and threshold), and Schedule (daily scan). Enabling auto-confirm still requires a separate explicit authorization alert. Changing scan roots still revokes the persisted authorization in the core.

The dedicated Settings window uses one native Form with all four sections. The narrow menu bar panel shows the same controls in one scroll view, so Automation and Schedule follow the directory settings without an extra tab or nested list.

The scan service reports four real milestones: scanning files, checking/extracting content, semantic analysis, and saving suggestions. The UI shows an indeterminate spinner and the current stage; it does not invent a percentage. These callbacks do not alter clustering behavior. Other operations use a generic busy state.

## Validation scope

Automated validation uses temporary Downloads directories. The new core tests cover the four scan milestones and atomic multi-file topic editing, including rollback on a bad member ID. Manual acceptance should check native list selection, drag/drop, Space Quick Look, settings authorization, Dark Mode, Reduce Transparency, Reduce Motion, VoiceOver, and keyboard focus in the locally built app. The app is built for local review only; no DMG or release is produced.
