# Feature audit against Notepad++ 8.9.8
Every entry of the upstream `IDR_M30_MENU` (669 menu entries) plus the non-menu subsystems, compared against
this port and independently re-checked in both directions. Two runs: before the gap work and after.

| | before | after |
|---|---|---|
| examined | 607 | 657 |
| implemented | 403 | 641 |
| partial | 40 | 55 |
| missing | 128 | 18 |

The "after" run was taken before the final pass; the 11 entries it still listed as missing that have since
been implemented are counted here and listed at the end.

| area | examined | implemented | partial | missing |
|---|---|---|---|---|
| File / Window / Tabs | 41 | 38 | 3 | 0 |
| Edit | 104 | 87 | 17 | 0 |
| Search | 66 | 63 | 3 | 0 |
| View | 91 | 69 | 18 | 3 |
| Encoding / Language | 153 | 157 | 1 | 0 |
| Settings menu and the Preferences dialog | 131 | 169 | 6 | 8 |
| Tools / Macro / Run / Plugins / Help | 30 | 26 | 0 | 4 |
| Subsystems that are not menu commands | 41 | 32 | 7 | 3 |

## Still missing

Everything below is bound to Windows, to the plugin DLL API, or to a Scintilla backend feature the Cocoa port does not have.


### View

- **IE** `IDM_VIEW_IN_IE` — Internet Explorer does not exist on macOS, so there is no possible equivalent — recorded as missing for completeness rather than as an actionable gap.
- **Text Direction RTL** `IDM_EDIT_RTL`
- **Text Direction LTR** `IDM_EDIT_LTR`

### Settings menu and the Preferences dialog

- **Settings > Import > Import plugin(s)...** `IDM_SETTING_IMPORTPLUGIN` — The port has no plugin system at all (see NPPPreferences.h:pluginPanelKeepState comment 'no plugin system here'), so there is nothing to import into.
- **General > Menu > Hide (use Alt or F10 key to toggle)** `IDC_CHECK_HIDEMENUBAR` — Permanently disabled control with a tooltip explaining macOS owns the menu bar. Property hideMenuBar exists but nothing reads it.
- **General > Menu > Hide right shortcuts** `IDC_CHECK_HIDERIGHTSHORTCUTSOFMENUBAR` — Same reason; hideMenuRightShortcuts is stored but unread.
- **Toolbar > Standard icons: small** `IDC_RADIO_STANDARD` — The radio is present but permanently disabled, so the fifth icon set cannot be chosen.
- **Multi-Instance > Panel State: Plugin Panels** `IDC_CHECK_PLUGINPANEL` — Permanently disabled checkbox.
- **MISC > system tray action** `IDC_COMBO_SYSTRAY_ACTION_CHOICE` — Permanently disabled; systemTrayAction is stored but never acted on (NPPPreferences.h documents this).
- **MISC > rendering mode** `IDC_COMBO_SC_TECHNOLOGY_CHOICE`
- **MISC > Auto-updater** `IDC_COMBO_AUTOUPDATE`

### Tools / Macro / Run / Plugins / Help

- **Run > Validate shortcuts.xml** `IDM_EXECUTE_VALIDATE_SHORTCUTSXML` — The port keeps shortcuts in NSUserDefaults keyed by command tag rather than an XML file, so there is neither a file to validate nor the HMAC trust record upstream writes.
- **Plugins > Open Plugins Folder...** `IDM_SETTING_OPENPLUGINSDIR`
- **? > Update Notepad++** `IDM_UPDATE_NPP`
- **? > Set Updater Proxy...** `IDM_CONFUPDATERPROXY`

### Subsystems that are not menu commands

- **Plugin API (MISC/PluginsManager: plugin loading, NPPM_/NPPN_ messages, plugin menu, Plugins Admin)** `plugin-api` — No plugin loading, no NPPM_ message interface, no Plugins menu, no Plugins Admin. Also removes the Plugin tab from the shortcut mapper.
- **Auto-updater (WinGUp / GUP.exe, NppGUI::_autoUpdateOpt: disabled / on startup / on exit)** `auto-updater` — A permanently-disabled control, so missing by the audit rule.
- **System tray / minimise to tray (WinControls/TrayIcon, NppGUI::_isMinimizedToTray, -systemtray)** `system-tray`

## Implemented after the second audit run

- **Edge** `IDM_VIEW_IN_EDGE`
- **Character sets > Arabic > OEM 720** `IDM_FORMAT_DOS_720`
- **Character sets > Western European > OEM 858** `IDM_FORMAT_DOS_858`
- **Searching > Fill Find in Files Directory Field Based On Active Document** `IDC_CHECK_FILL_DIR_FIELD_FROM_ACTIVE_DOC`
- **Searching > Fill Find Field with Selected Text** `IDC_CHECK_FILL_FIND_FIELD_WITH_SELECTED`
- **Searching > Select Word Under Caret when Nothing Selected** `IDC_CHECK_FILL_FIND_FIELD_SELECT_CARET`
- **Searching > Find dialog remains open after search that outputs to results window** `IDC_CHECK_FINDDLG_ALWAYS_VISIBLE`
- **MISC > Document Switcher: Enable MRU behaviour** `IDC_CHECK_STYLEMRU`
- **Right-click on the bookmark margin pops the Search ▸ Bookmark submenu (NppNotification.cpp SCN_MARGINRIGHTCLICK, line 173)** `scn-margin-right-click`
- **Dragging a tab out of the strip — drop in the same view pops a Move/Clone to Other View menu, drop in the other view group transfers the buffer, drop outside the window opens a new instance (NppNotification.cpp TCN_TABDROPPEDOUTSIDE, line 758)** `tab-dropped-outside`
- **Ghost typing easter egg (-qn= / -qt= / -qf= / -qSpeed, winmain.cpp:299-330)** `ghost-typing`

## Partial

Implemented but materially reduced against upstream.

### File / Window / Tabs

- **File > Open Containing Folder > PowerShell** — There is no second shell entry: cmd and PowerShell collapse into a single "Open in Terminal", and the app is hardcoded to com.apple.Terminal (src/NPPEditorWindowController.mm:128-133, with a ponytail note that a preferred-terminal preference is not read). No way to pick a second/alternate shell from the menu.
- **Window > Windows...** — No modal document dialog. The Document List panel covers only part of upstream's WindowsDlg: single-row activate (:230,:234), and Save/Close/Copy Path for one document at a time through the row context menu (:249-250). Missing: multi-selection save/close (upstream IDC_WINDOWS_SAVE / IDC_WINDOWS_CLOSE act on every selected row), the "Sort" button that pushes the list order onto the real tabs (doSortToTabs), and any entry point from the Window menu at all — a user looking for "Windows..." finds nothing there.
- **Window > Recent Window (open-document list injected into the Window menu)** — Upstream replaces this placeholder at popup time with the numbered (&1..&0) list of open buffers, dirty-marked, so ⌥W-then-digit activates a document. In the port the Window menu has no document list and no numeric accelerators; the same list is only reachable from the tab strip's chevron or the Document List panel.

### Edit

- **Split Lines** — Always splits at the current window width. Upstream (NppCommands.cpp:2101-2129) splits at the vertical-edge column when edge mode is EDGE_LINE/EDGE_BACKGROUND/EDGE_MULTILINE (using the LAST multi-edge column), and only uses width 0 for EDGE_NONE. The port does support edge columns (NPPPreferences.mm:970-985), so a user with a vertical edge set gets a different split width than N++.
- **Sort Lines Lexicographically Ascending** — Sorts on the whole line only. Upstream passes fromColumn/toColumn derived from a rectangular selection (NppCommands.cpp:955-971, Sorters.h) so a column-block selection sorts by the text inside that column range; the port's RewriteBlock/BlockForSelection (NPPEditCommands.mm:52-66, 98-111) uses SCI_GETSELECTIONSTART/END and whole lines, and never reads SCI_GETRECTANGULARSELECTION*. Column sorting is absent for every sort variant.
- **Sort Lines Lex. Ascending Ignoring Case** — Same column-range gap as the other sorts: no fromColumn/toColumn key from a rectangular selection.
- **Sort Lines In Locale Order Ascending** — No column-range sort key from a rectangular selection.
- **Sort Lines As Integers Ascending** — No column-range sort key. Also, upstream raises a 'Sorting Error' message box naming the offending line when a line has no number; the port silently orders non-numeric lines last.
- **Sort Lines As Decimals (Comma) Ascending** — No column-range sort key from a rectangular selection.
- **Sort Lines As Decimals (Dot) Ascending** — No column-range sort key from a rectangular selection.
- **Sort Lines By Length Ascending** — No column-range sort key from a rectangular selection.
- **Sort Lines Lexicographically Descending** — No column-range sort key from a rectangular selection.
- **Sort Lines Lex. Descending Ignoring Case** — No column-range sort key from a rectangular selection.
- **Sort Lines In Locale Order Descending** — No column-range sort key from a rectangular selection.
- **Sort Lines As Integers Descending** — No column-range sort key; no 'Sorting Error' dialog for unparsable lines.
- **Sort Lines As Decimals (Comma) Descending** — No column-range sort key from a rectangular selection.
- **Sort Lines As Decimals (Dot) Descending** — No column-range sort key from a rectangular selection.
- **Sort Lines By Length Descending** — No column-range sort key from a rectangular selection.
- **Block Uncomment** — 
- **Skip Current & Go to Next Multi-select** — 

### Search

- **Find (Volatile) Next** — Deviation, not a gap: the port passes wholeWord:YES (NPPFindPanelController.mm:709) where upstream sets op._isWholeWord = false (NppCommands.cpp:1698), so a partial-word selection will not match mid-word occurrences. It also falls back to the word at the caret where upstream returns early on an empty selection.
- **Find (Volatile) Previous** — 
- **Bookmark > Paste to (Replace) Bookmarked Lines** — Upstream Notepad_plus::pasteToMarkedLines (Notepad_plus.cpp:2996-3002) replaces EVERY bookmarked line with the WHOLE clipboard string. So with a one-line clipboard and N bookmarks, upstream rewrites all N lines while the port rewrites only the first bookmarked line; the other N-1 are left untouched. The port acknowledges the divergence in a 'ponytail:' comment at NPPSearchViewCommands.mm:650.

### View

- **Post-It** — Only swaps window chrome (borderless + NSFloatingWindowLevel + movableByWindowBackground). Upstream Notepad_plus.cpp:6176 postItToggle also hides the status bar, the tab bar, the menu bar and the toolbar rebar and forces Always-on-Top. The port's own comment at NPPSearchViewCommands.mm:237 states the tab bar cannot be hidden because -layoutContent recomputes it; the status bar is likewise left visible.
- **Show Control Characters / Unicode EOL** — canPerformCommand (NPPSearchViewCommands.mm:503) returns NPPPreferences.shared.showNonPrintingChars, so the item is greyed out whenever 'Show Non-Printing Characters' is off. Upstream NppCommands.cpp:2625 makes IDM_VIEW_NPC_CCUNIEOL an independent toggle with no such gate. Also missing upstream's SCI_STYLESETVISIBLE fixup for the ErrorList / EscapeSequence lexers (NppCommands.cpp:2644-2659).
- **Hide Lines** — Does not merge with adjacent hidden sections the way upstream ScintillaEditView::hideLines does — it just deletes stale markers inside the range (the port's own comment at NPPSearchViewCommands.mm:406). Hiding two abutting ranges therefore leaves the marker bookkeeping different from upstream. There is also no 'unhide' affordance beyond clicking the markers.
- **Fold Level 2** — 
- **Fold Level 3** — 
- **Fold Level 4** — 
- **Fold Level 5** — 
- **Fold Level 6** — 
- **Fold Level 7** — 
- **Fold Level 8** — 
- **Unfold Level 2** — 
- **Unfold Level 3** — 
- **Unfold Level 4** — 
- **Unfold Level 5** — 
- **Unfold Level 6** — 
- **Unfold Level 7** — 
- **Unfold Level 8** — 
- **Summary...** — Omits the three file-identity lines upstream puts at the top of the same dialog (NppCommands.cpp:2841-2855): 'Full file path', 'Created' and 'Modified'. Selection reporting also differs: upstream reports selected characters / selected bytes / number of ranges; the port reports selected characters / words / lines / selections.

### Encoding / Language

- **Language > User-Defined** — The runtime UDL list (upstream IDM_LANG_USER+1..+30) is fully present. What is missing is the static IDM_LANG_USER item itself — upstream's plain "User-Defined" entry that sets L_USER with no UDL name selected. In the port "User-Defined" is only a submenu header and is not clickable, so there is no way to select the generic user-defined lexer without a named UDL. Edge case.

### Settings menu and the Preferences dialog

- **Tab Bar > Enable pin tab feature** — Pinning works and is always on; the upstream switch to turn the feature off is absent from the Tab Bar page.
- **Editing 1 > Caret blink rate** — Upstream is a continuous slider across the whole rate range; the port offers four presets.
- **File Association page (register/unregister extensions)** — Registering works; there is no equivalent of upstream's '<-' unregister button, and the flat extension table has no per-language grouping. Also lacks the per-language source list / registered list pair.
- **Multi-Instance > Default / Always multi-instance / Open session in a new instance** — 
- **MISC > File Status Auto-Detection combo** — 
- **MISC > Scroll to the last line after update** — Cannot be combined with the non-silent mode the way two independent upstream checkboxes can.

### Subsystems that are not menu commands

- **Session save/restore (Save Session… / Load Session… + auto session at quit/launch, Parameters.cpp writeSession/getSessionFromXmlTree)** — Works and round-trips mainView/subView, activeView/activeIndex, filename, lang, userReadOnly, startPos/endPos, firstVisibleLine, <Mark> bookmarks and parked untitled buffers. But six upstream per-file fields are written as hard-coded constants and never read back: encoding="-1", tabColourId="-1", RTL="no", originalFileLastModifTimestamp="0", xOffset/scrollWidth/selMode/offset="0" (NPPEditorWindowController.mm:1323-1336). Upstream also writes <Fold line=…> per file (Parameters.cpp:4613), tabPinned, untitleTabRenamed and the ten map* docMap attributes — none of which exist in the port (grep for foldState/tabPinned/mapFirstVisibleDocLine in src returns nothing). So folds, pinned tabs, tab colours, per-file encoding and doc-map position are all lost across a restart.
- **Localization from PowerEditor/installer/nativeLang/*.xml (localization.cpp NativeLangSpeaker)** — Main menu only. Upstream additionally translates the Preferences dialog (changePreferenceDlgLang), Find/Replace (changeFindReplaceDlgLang), the UDL dialog (changeUserDefineLang), the Shortcut Mapper (getShortcutMapperLangStr), the tab and tray context menus (changeLangTabContextMenu / changeLangTabDropContextMenu / changeLangTrayIconContexMenu), the project-panel menus (getProjectPanelLangMenuStr), and every message box (getMsgBoxLang). None of those surfaces is translated in the port, so picking French re-titles the menu bar and leaves every dialog in English.
- **Shortcut mapper (WinControls/Grid/ShortcutMapper.cpp, shortcuts.xml)** — Three of upstream's five tabs. Upstream ShortcutMapper.h:25 is `enum GridState {STATE_MENU, STATE_MACRO, STATE_USER, STATE_PLUGIN, STATE_SCINTILLA}` — the port has no Scintilla-commands tab, so the editor's own key bindings (ScintillaKeyMap / scintKeys.xml) cannot be rebound at all. STATE_PLUGIN is moot because there is no plugin system.
- **Command line arguments (winmain.cpp FLAG_* / CmdLineParams)** — Six documented switches are parsed and then deliberately ignored (NPPCommandLine.mm:92-103): -noPlugin and -pluginMessage= (no plugin system), -systemtray (no tray), -multiInst (macOS reuses the running app), -export=functionList (no headless function-list export), and the -qn=/-qt=/-qf=/-qSpeed ghost-typing easter eggs. Everything else — -ro, -fullReadOnly, -fullReadOnlySavingForbidden, -nosession, -notabbar, -alwaysOnTop, -r, -openSession, -openFoldersAsWorkspace, -monitor, -monitoringMode, -quickPrint, -loadingTime, -settingsDir=, -titleAdd=, -udl=, -l, -L, -n/-c/-p/-x/-y, --help — is honoured.
- **Docking panel framework (WinControls/DockingWnd) — panels docked to any edge, tabbed, resizable** — No floating/undocked panels. Upstream's DockingWnd lets a panel be dragged out into its own floating window and re-docked to another edge; grep for float/undock/detach in NPPPanelHost.mm finds only CGFloat. Also no top edge.
- **Window ▸ Windows… modal list (WinControls/WindowsDlg) — activate/save/close selected documents, sortable columns** — The sorting and the list both exist, but as a menu of sort commands plus a docked panel rather than the modal dialog; the dialog's multi-select Save / Close buttons have no equivalent (the panel is single-activation, NPPUtilityPanels.mm:137-220).
- **Multi-instance modes (NppGUI::_multiInstSetting: mono / always multi / session in new instance) and handing files to a running instance** — The preference and the new-instance launch work, but the -multiInst command-line switch itself is explicitly ignored (NPPCommandLine.mm:96), so `Notepad++ -multiInst file` reuses the running app instead of starting a second copy.

## Beyond the menu

The audit above is exhaustive on the menu side (parsed from `Notepad_plus.rc`) but its non-menu list was
enumerated by hand. A second pass read the upstream tree through six independent lenses — notification handling,
window-message side effects, file I/O edge cases, the editor component, the buffer model, and what each dialog
offers beyond the command that opens it — and claimed 33 further omissions, of which 32 survived refutation.
All 32 have since been implemented; two of them were defects rather than missing features:

- every save replaced the file, so its creation date was reset and its extended attributes, POSIX mode and ACL
  were lost; a hard-linked file was silently detached from its other name
- a file that was read-only on disk was overwritten with no warning

What that pass found, for the record:


### medium

- **Document Map is indexed with display lines, so folds or word wrap desync its viewport box and its click targets** — Open View > Document Map, then collapse a fold or turn on word wrap (upstream: `/Users/m_canfirat/npp/notepad-plus-plus/PowerEditor/src/NppNotification.cpp:159 (_pDocMap->fold on SCN_MARGINCLICK)`)
- **Editor zoom is per-document and never persisted: it resets when you switch tabs and is gone after a restart** — Upstream zoom is a property of the *view*, so Ctrl+wheel or View ▸ Zoom applies to every buffer shown in that view and survives a quit/relaunch (main and sub kept separately unless zoom sync is on) (upstream: `PowerEditor/src/NppBigSwitch.cpp:2861 (saveScintillasZoom() on WM_CLOSE) → Notepad_plus.cpp:5808-5814; persisted as zoom/zoom2 (Parameters.cpp:7260-7261`)
- **No "Find in these search results" — a Find-in-Files result set cannot be narrowed by a second search** — Right-clicking the Find Results panel in Notepad++ offers "Find in these search results...", which searches only the lines already found and builds a new, narrower result set — the standard drill-down after a broad Find in Files (upstream: `PowerEditor/src/NppBigSwitch.cpp:465 (WM_FINDALL_INCURRENTFINDER) and :517 (NPPM_INTERNAL_FINDINFINDERDLG)`)
- **Every save resets the file's creation date and wipes its extended attributes** — Colour-tag a file in Finder, give it a Finder comment, or look at its Created date; open it in the port, hit Cmd+S once and all of that is gone (upstream: `PowerEditor/src/MISC/Common/FileInterface.cpp:37-50 (stores the original WIN32_FILE_ATTRIBUTE_DATA`)
- **A file that is read-only on disk is overwritten by Save with no warning** — Neither layer exists in the port (upstream: `PowerEditor/src/NppIO.cpp:1777-1788 - fileSave() opens with `if (buf->isReadOnly())``)
- **The charset an HTML or XML file declares in its own header is ignored when opening it** — Open a non-UTF-8 .html or .xml that declares its own charset - `<meta http-equiv="Content-Type" content="text/html; charset=windows-1251">`, `<?xml version="1.0" encoding="Shift_JIS"?>` - and Notepad++ decodes it with the declared charset, no guessing (upstream: `PowerEditor/src/NppIO.cpp:441-444 - doOpen() calls getHtmlXmlEncoding(longFileName) and hands the result to loadFile as the encoding before any detection runs; implementation at Notepad_plus.cpp:1125-1235 reads the first 1024 bytes and regex-matches `<?xml version="..." encoding="..."?>` for L_XML and `<meta http-equiv=Content-Type ... charset=...>` (two orderings) for L_HTML`)
- **Closing several dirty files asks once per file - no "Yes to All" / "No to All"** — Close All, Close All but This, Close All to the Right, or quitting with twenty dirty buffers means twenty dialogs and twenty clicks (upstream: `PowerEditor/src/NppIO.cpp:1272 (and :1354`)
- **A column selection is never converted to independent multi-carets by arrow/Home/End/Enter/Backspace** — Upstream, with the default preference on: Alt+drag a rectangle, press an arrow key / Home / End / Enter / Backspace and the rectangle becomes N independent carets you can move and edit per line; Esc collapses back to one caret (upstream: `PowerEditor/src/ScintillaComponent/ScintillaEditView.cpp:794-836 (WM_KEYDOWN`)
- **Collapsed fold state is never saved in a session — every fold reopens expanded after restart** — Fold a 4000-line file down to its function headers, quit, relaunch: Notepad++ brings it back folded exactly as you left it, the port brings the whole file back expanded (upstream: `PowerEditor/src/Notepad_plus.cpp:6534-6538 (editView->getCurrentFoldStates / buf->getHeaderLineState into sessionFileInfo._foldStates); PowerEditor/src/Parameters.cpp:4613 writes <Fold line="N"/>`)
- **A manually chosen character set is not remembered across a session — the encoding attribute is written as a constant -1** — Open a legacy 8-bit file, fix its mojibake with Encoding > Character sets > .. (upstream: `PowerEditor/src/Notepad_plus.cpp:6517 (sessionFileInfo built with buf->getEncoding()); PowerEditor/src/Parameters.cpp:4579 writes encoding=`)
- **Style Configurator has no "User ext." or "User keywords" fields — no way to map an extension to a built-in language or extend a lexer's keyword list** — Upstream, picking a language in Style Configurator shows its default extensions plus an editable "User ext." box, and each style shows its default keyword list plus an editable "User keywords" box — that is how .foo is made to open as C++ and how a project's own type names get syntax colour (upstream: `PowerEditor/src/WinControls/ColourPicker/WordStyleDlg.cpp:288-300 (EN_CHANGE on IDC_USER_KEYWORDS_EDIT → updateUserKeywords`)
- **Folder as Workspace tree: no "Find in Files" scoped to the clicked folder, no shell-here, no Expand All / Locate-current-file** — Right-clicking a folder in the tree upstream searches it (Find in Files) or opens a shell in it, and a toolbar button expands the tree down to the file being edited (upstream: `PowerEditor/src/WinControls/FileBrowser/fileBrowser.cpp:409-447 (root/folder/file popup menus incl. IDM_FILEBROWSER_FINDINFILES`)
- **Closing several modified documents asks once per file — no "Yes to all" / "No to all"** — Close All, or quitting, with ten modified documents produces ten separate Save/Don't Save/Cancel sheets in the port; upstream settles the batch in one click whenever more than one document is at stake (upstream: `PowerEditor/src/WinControls/AboutDlg/AboutDlg.h:109-138 (DoSaveOrNotBox`)

### low

- **Double-clicking the status bar's Ln:Col field or its length/lines field does nothing** — In Notepad++ double-clicking the "Ln : Col" panel opens Go To Line and double-clicking the "length : lines" panel opens Summary (upstream: `/Users/m_canfirat/npp/notepad-plus-plus/PowerEditor/src/NppNotification.cpp:976-984 (NM_DBLCLK: STATUSBAR_CUR_POS -> IDM_SEARCH_GOTOLINE`)
- **Begin/End Select anchor is not shifted when text is inserted or deleted before it** — Mark a spot with Edit > Begin/End Select, then type, paste or run a replace anywhere above that spot, then invoke Begin/End Select again: the selection starts at the wrong place, off by exactly the number of characters added or removed (upstream: `/Users/m_canfirat/npp/notepad-plus-plus/PowerEditor/src/NppNotification.cpp:64 calling ScintillaEditView::updateBeginEndSelectPosition`)
- **Tooltip of an untitled tab omits the tab's creation time** — Hovering an untitled tab in Notepad++ shows when that tab was created, which is how a user tells several "new 1 / new 2" scratch tabs apart (upstream: `/Users/m_canfirat/npp/notepad-plus-plus/PowerEditor/src/NppNotification.cpp:1285-1293 (TTN_GETDISPINFO appends Buffer::tabCreatedTimeString() for an untitled buffer; the string is set in ScintillaComponent/Buffer.h:296-306)`)
- **Renaming or deleting a user-defined language leaves open documents pointing at the old name** — Rename a UDL while a file using it is open: Notepad++ moves the file's association to the new name; the port leaves the document's userDefinedLanguageName on the old string, so the status bar keeps reading "OldName (User Defined)" and the Language menu no longer ticks anything (upstream: `PowerEditor/src/NppBigSwitch.cpp:394-409 (WM_REMOVE_USERLANG walks every buffer and resets those on the removed UDL to (L_USER`)
- **No "Copy link" in the editor context menu when right-clicking a URL** — Right-clicking a URL with nothing selected turns the context menu's "Copy" into "Copy link" and copies the entire URL under the cursor in one click (upstream: `PowerEditor/src/NppBigSwitch.cpp:2067-2068 (WM_CONTEXTMENU sets copyLink = no selection && caret inside a URL_INDIC range) → WinControls/ContextMenu/ContextMenu.cpp:114-127 (rewrites the Copy item as IDM_EDIT_COPY_LINK) → NppCommands.cpp:542-553 (selects the whole URL`)
- **Mouse back/forward buttons (and right-button + wheel) do not switch documents** — On a mouse with side buttons, back/forward step through the open documents in Notepad++ (Safari and Finder honour the same buttons on macOS, so the gesture is not Windows-only) (upstream: `PowerEditor/src/NppBigSwitch.cpp:1249-1264 (WM_APPCOMMAND: APPCOMMAND_BROWSER_BACKWARD/FORWARD → activateNextDoc(dirUp/dirDown)) and :1237-1247 (WM_MOUSEWHEEL with MK_RBUTTON held → IDC_PREV_DOC / IDC_NEXT_DOC)`)
- **Paste into multiple carets does not distribute clipboard lines one per caret** — Upstream: copy a rectangular/column block, place N carets, paste — clipboard line 1 goes to caret 1, line 2 to caret 2, etc.; when the clipboard has more lines than carets each caret gets an equal group of lines joined by EOL (upstream: `PowerEditor/src/ScintillaComponent/ScintillaEditView.cpp:4866-4957 (pasteToMultiSelection)`)
- **Delete with multiple carets at end-of-line does nothing instead of joining lines** — Put carets at the end of several lines (multi-edit) and press forward-Delete: upstream removes the EOL at every caret, joining each line with the next, in one undo step (upstream: `PowerEditor/src/ScintillaComponent/ScintillaEditView.cpp:713-793 (WM_KEYDOWN`)
- **Style Configurator's "Global override" is listed but inert — no forced foreground/background/bold/italic/underline** — Upstream's Style Configurator has seven "Enable global …" checkboxes that force one colour/weight across every syntax style of every language (upstream: `PowerEditor/src/ScintillaComponent/ScintillaEditView.cpp:894-965 (setStyle applies GlobalOverride to every style it pushes`)
- **Indent guides use SC_IV_LOOKBOTH in Python-style indentation languages** — With indent guides on (the port's default, NPPPreferences.h:183), upstream uses SC_IV_LOOKFORWARD for indentation-folded languages so a blank line ending a block takes its guides from the following line, not the deeper block above (upstream: `PowerEditor/src/ScintillaComponent/ScintillaEditView.cpp:2179 and :3457-3458 — `isPythonStyleIndentation(typeDoc) ? SC_IV_LOOKFORWARD : SC_IV_LOOKBOTH`; isPythonStyleIndentation at ScintillaEditView.h:660 covers Python`)
- **The file's read-only bit on disk is never re-checked while the file is open** — chmod -w a file that is open (or a lock-based VCS taking it back): Notepad++ locks the buffer and refuses edits; the port lets you keep typing and only surfaces the problem when the save fails (upstream: `PowerEditor/src/ScintillaComponent/Buffer.cpp:521-527 (Buffer::checkFileState re-reads FILE_ATTRIBUTE_READONLY and raises BufferChangeReadonly when it flipped)`)
- **Per-tab colour is not saved in a session — tabColourId is written as a constant -1** — Colour-code a working set of tabs with View > Tab > Apply Color 1-5, quit, relaunch: Notepad++ brings the colours back, the port brings every tab back plain (upstream: `PowerEditor/src/Notepad_plus.cpp:6520 (sfi._individualTabColour = docTab[k]->getIndividualTabColourId(i)); PowerEditor/src/Parameters.cpp:4585 writes it`)
- **Extension-less filenames upstream maps to a language: 8 of the 12 are missing** — Open a Rakefile, a Vagrantfile, an SConstruct, a wscript, a PKGBUILD or a crontab: Notepad++ highlights them as Ruby / Python / Bash, the port opens them as Normal Text — no highlighting, no folding, no language-aware comment toggling, wrong language in the status bar (upstream: `PowerEditor/src/ScintillaComponent/Buffer.cpp:330-339 (Buffer::setFileName refines L_TEXT by exact filename: makefile/GNUmakefile -> Makefile`)
- **Project Panel has no "Find in Projects" and no "Modify File Path" for a file whose path is broken** — The port marks a project file whose path no longer exists in red with a warning triangle (NPPProjectPanel.mm:656-681) but offers no way to re-point it — upstream's "Modify File Path" exists for exactly that; the port's Rename only edits the label (NPPProjectPanel.mm:415, its own comment says so), so a moved file must be removed and re-added (upstream: `PowerEditor/src/WinControls/ProjectPanel/ProjectPanel.cpp:280 + :1156 (IDM_PROJECT_FINDINPROJECTSWS → NPPM_INTERNAL_FINDINPROJECTS) and :330 + :1211 (IDM_PROJECT_MODIFYFILEPATH → FileRelocalizerDlg)`)
- **Document List panel is single-selection with three fixed columns — no Ext/Path column toggles, no "Group by View", no multi-row right-click** — Upstream the Document List can be narrowed to just names, grouped by edit view when the window is split, and several documents shift-selected then closed or saved in one action (upstream: `PowerEditor/src/WinControls/VerticalFileSwitcher/VerticalFileSwitcher.cpp:543-563 + :566-600 (header right-click menu toggling the Ext column`)
- **Open and Save panels have no language file-type filter, and Save As has no "Append extension"** — Upstream's Open dialog lets a crowded folder be narrowed to one language, and Save As appends the chosen type's extension to a name typed without one (upstream: `PowerEditor/src/NppIO.cpp:1076 and :1096-1112 (one setExtFilter entry per built-in language and per UDL`)
- **Style Configurator has no Global Override controls (force one foreground/background/bold/italic/underline across every style)** — Upstream a user edits the "Global override" style then ticks which of its attributes beat every language's styles — usually to force one background colour or kill all italics (upstream: `PowerEditor/src/WinControls/ColourPicker/WordStyleDlg.cpp:60-71 (updateGlobalOverrideCtrls loads NppGUI._globalOverride into the seven IDC_GLOBAL_*_CHECK boxes) with handlers at :432-470; ids in WordStyleDlgRes.h:50-56`)
- **Status bar: double-clicking the Ln/Col field does not open Go To Line, and the length/lines field does not open Summary** — Upstream every status-bar field is live; the port wired the language, EOL and encoding menus and the INS/OVR toggle only (upstream: `PowerEditor/src/NppNotification.cpp:972-982 (NM_DBLCLK on the status bar: STATUSBAR_CUR_POS → IDM_SEARCH_GOTOLINE`)
- **Character Panel drops the HTML Decimal and HTML Hexadecimal columns, and double-click always inserts the character rather than the clicked column's entity** — Upstream the panel doubles as an entity picker: double-clicking the HTML Name cell for © inserts &copy;, the decimal cell &#169;, the hex cell &#xA9; (upstream: `PowerEditor/src/WinControls/AnsiCharPanel/ansiCharPanel.cpp:40-52 (six columns: Value`)

## Reachability

A feature on a menu the user never opens is, to that user, missing. After a complaint that "there is no split
screen" — the second edit view was fully implemented, but Notepad++ users reach it by right-clicking a tab and
the port only had it on the View menu — a fourth pass audited the *access paths* rather than the features:
the shipped keyboard shortcuts, every right-click menu, the mouse and drag gestures, the toolbar, and the
affordances inside each panel and dialog. 34 claims, 22 confirmed after refutation, 12 rejected as correct
macOS adaptations (⌃Tab for Ctrl+Tab, a sheet for a modal dialog, ⌘ for Ctrl). All 22 are now restored.

The two that mattered most:

- the editor right-click menu was half of Notepad++'s, missing the sixteen token-styling entries, Open File,
  Search on Internet, Begin/End Select, Block Uncomment and Hide Lines — and the menu builder could not express
  submenus at all, so the user could not add them back either
- the Find panel's "Find All in Current Document" button carried the upstream caption but *marked* the matches
  instead of listing them, and the menu path overrode a typed regex with the word under the caret

The full list:


### high

- **Editor right-click is missing most of Notepad++'s default context menu: the three token-styling submenus, Open File, Search on Internet, Begin/End Select, Block Uncomment, Hide Lines** — Upstream's shipped ScintillaContextMenu (NppConstants.h:478-539, the contextMenu.model.xml literal) is Cut/Copy/Paste/Delete/Select all/Begin-End Select ▸ Style all occurrences of token (5) ▸ Style one token (5) ▸ Clear style (6) ▸ UPPERCASE/lowercase ▸ Open File / Search on Internet ▸ Toggle Single Line Comment / Block Comment / Block Uncomment ▸ Hide lines
- **The Find dialog's "Find All in Current Document" button marks matches instead of listing them in the Search results panel** — Upstream FindReplaceDlg.rc:69 puts a button with exactly this caption on the Find tab, and FindReplaceDlg.cpp:2352 makes it read the Find combo and call findAllIn(CURRENT_DOC) — the results panel opens with every hit listed and clickable

### medium

- **The function-key row is assigned to the wrong commands: F3 = Focus on Another View (upstream F8), F5/⇧F5 = next/prev search result (upstream F4/⇧F4), and upstream's F5 = Run… sits on ⌘⇧R** — Every F-key a Notepad++ user has in their fingers lands somewhere else or nowhere
- **⌘⇧R opens the Run dialog; upstream Ctrl+Shift+R toggles macro recording, which has no key in the port** — The Notepad++ macro loop is Ctrl+Shift+R … edits … Ctrl+Shift+R, then Ctrl+Shift+P
- **"Pin Tab" is on no menu in the port, and the shipped "Show only pinned button" preference then makes pinning completely unreachable** — Upstream offers pinning two ways: the pin box on the tab, and right-click tab ▸ Pin Tab (NppNotification.cpp:1106, renamed Pin/Unpin at :1228-1236)
- **Right-clicking the split divider does nothing — upstream that is the only place Rotate exists** — With the editor split, a Notepad++ user who wants side-by-side turned into stacked right-clicks the bar between the two views
- **Double-clicking the split divider does not reset it to 50/50 — and nothing else in the port does either** — Upstream Splitter.cpp:353-365 (WM_LBUTTONDBLCLK) snaps the divider back to even halves, and the flags that enable it are on by default for the editor splitter (SplitterContainer.h:73 SV_ENABLERDBLCLK|SV_ENABLELDBLCLK, applied at Notepad_plus.cpp:442)
- **Right-clicking a row in the Document List gives 3 items, not the tab context menu** — Upstream the Document List is the tab bar in list form: VerticalFileSwitcher.cpp:411-419 forwards NM_RCLICK to the main window, and NppNotification.cpp:1086-1130 pops the *same* menu as right-clicking a tab (Close All BUT This, Close to Left/Right, Save As, Rename, Reload, Print, Open Containing Folder, Move/Clone to Other View, Read-Only, Copy Full Path/Filename/Dir), plus a 4-item multi-select menu (Close Selected files, Close Other files, Copy Selected Names, Copy Selected Pathnames) at NppNotification.cpp:1090-1093
- **Delete key in the search-results panel removes nothing** — FindReplaceDlg.cpp:5002 maps VK_DELETE to Finder::deleteResult, and deleteResult (FindReplaceDlg.cpp:668-711) drops either the clicked hit line or, on a fold-header line, the whole file's block — the standard way to prune a Find-in-Files run down to a worklist
- **Shortcut Mapper has no filter box** — ShortcutMapper.rc:33-35 gives the mapper a "Filter:" label, an edit field and a ✕ clear button; typing "comment" narrows the grid to matching commands
- **UDL Styler exposes no Nesting checkboxes and no way to leave a colour transparent** — UserDefineDialog.rc:266-267 gives every UDL style two "Transparent" checkboxes, and :269-295 a whole "Nesting" group (Delimiter 1-8, Keyword 1-8, Comment, Comment line, Operators 1-2, Numbers) — the only way to say "keywords still highlight inside this delimiter"

### low

- **Column Editor has no key equivalent (upstream Alt+C)** — Alt+C right after a column selection is how column-editor users open it, without leaving the keyboard
- **Fold All / Unfold All have no keys while the rarely used Fold Level 1-8 do** — Upstream Alt+0 / Alt+Shift+0 (Parameters.cpp:357-358) are the fold keys people actually use; the numbered levels are the rare ones
- **Right-clicking the split divider does nothing; upstream's only path to flipping the split between side-by-side and stacked is that gesture** — Confirmed upstream: Splitter.cpp:276 forwards WM_RBUTTONDOWN as WM_DOPOPUPMENU, and SplitterContainer.cpp:248-270 builds a two-item popup, "Rotate to right" / "Rotate to left"
- **Tab right-click omits upstream's "Open into" and "Move Document" entries: Open in Terminal, Open Containing Folder as Workspace, Move to Start / Move to End, Move to / Open in New Instance** — Upstream's tab menu groups four Open-into entries (NppNotification.cpp:1109-1113) and six Move-Document entries (:1129-1134)
- **Document List row right-click offers four items where upstream reuses the entire tab context menu** — Confirmed upstream: NppNotification.cpp:1057-1080 handles the Document List's NM_RCLICK, returns early with a four-item menu only when nbSelectedFiles() > 1 (Close Selected files / Close Other files / Copy Selected Names / Copy Selected Pathnames), and otherwise falls through to _tabPopupMenu.display(p) at :1238 — a single-row right-click gets the whole tab menu
- **Panel group on the toolbar is 3 buttons instead of 5 — Document List has no button and the Customize palette cannot add one** — Upstream's panel strip is UDL / Document Map / Document List / Function List / Folder as Workspace, each a pressed-state toggle (Notepad_plus.cpp:111-116)
- **Macro toolbar group stops after Play, and a Run button upstream does not have sits in the slot where Save Current Recorded Macro belongs** — Upstream's macro strip is five buttons — record, stop, play, run-multiple, save — and Save Current Recorded Macro lights up the instant recording stops with an unsaved macro (Notepad_plus.cpp:130-131, enable rule at :2728)
- **Middle-clicking a Document List row does not close the document** — VerticalFileSwitcher.cpp:303-334 subclasses the list view specifically so WM_MBUTTONUP hit-tests the row and calls closeDoc — middle-click-to-close works in the list exactly as on a tab
- **Find in Files: the Directory and Filters fields are plain text fields with no history drop-down** — FindReplaceDlg.rc:36 and :39 make both Filters and Directory CBS_DROPDOWN combos, backed by the 10-entry _findHistoryPaths/_findHistoryFilters (Parameters.h:1153-1159), so switching back to a folder searched earlier, or between "*.cpp" and "*.h;*.hpp", is one drop-down pick
- **No swap control between the Find and Replace fields** — FindReplaceDlg.rc:34 puts a split button between the two combos; FindReplaceDlg.cpp:1708-1712 hangs "⇅ Swap Find with Replace", "⤵ Copy from Find to Replace", "⤴ Copy from Replace to Find" off it
- **Style Configurator shows the User keywords field with no read-only "Default keywords" list beside it** — WordStyleDlg.rc:64-68 pairs a read-only multiline "Default keywords" box with "+" and the editable "User-defined keywords" box, so you can see what the language already highlights before adding to it
