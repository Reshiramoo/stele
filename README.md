# Stele

Translation editor plugin for Godot 4.6+: Poedit's workflow for Godot's CSV translation files,
in a bottom dock inside the editor. Named after the Rosetta Stone, a stele with one text in three scripts.

## Install

1. Clone this repository into your project's `addons` folder as `stele`:
   ```bash
   git clone https://github.com/Reshiramoo/stele.git addons/stele
   ```
   (or add it as a submodule: `git submodule add https://github.com/Reshiramoo/stele.git addons/stele`).
   The folder must be named `stele`.
2. **Project → Project Settings → Plugins** → enable **Stele**. A **Stele** tab appears in the bottom panel.

## Translating

Open a file from the dock's file list (every CSV the project imports as translations), with
**Catalog → Open…**, by right-clicking a `.csv` in the FileSystem dock → **Translate with Stele**,
or by selecting one of its generated `.translation` files (it opens at that language).
Pick the source and target languages in the toolbar (**From** / **To**). The source can be the
key column itself, for files that only hold IDs. The dock remembers your choice for each file.

| Area | What it does |
|---|---|
| **List** | Every entry with its key, source text and translation; the **+** in the header's corner adds an entry. Untranslated entries are **bold**, Needs Work entries are yellow, and entries with issues get a warning or error icon. Filter by text, show All / Unfinished / Needs Work / With Issues / Translated, sort by file order, source or translation, with unfinished entries first if you like. |
| **Source text** | The text to translate, its plural form, key and context. |
| **Translation** | The editor. Plural entries get one tab per form. **Needs Work** flags a translation for review; editing it clears the flag, as in Poedit. Issues show up underneath as you type. |
| **Suggestions** | Translation memory: finished translations of similar source text from this file and every other translation CSV in the project, with a match percentage. Double-click or press Ctrl+1 … 9 to use one. |
| **Notes / Translator Comment** | The file's `_` note columns, editable, and a comment for this language. |
| **Status bar** | Translated / untranslated / needs work / issue counts and a progress bar, like Poedit's. A button appears when some languages aren't in **Project Settings → Localization** yet; click it to add them. |

**Catalog** menu: New Translation File, Open, Save, Reload from Disk, Add / Rename (F2) / Delete (Del) Entry,
Add / Remove Plural Form, Add Language, **Pre-translate from Memory** (fills untranslated entries from exact
translation-memory matches and flags them Needs Work), **Validate** (lists the entries with issues), Add
Languages to Project Settings, Undo, Redo.

Saving (Ctrl+S in the dock, or **Catalog → Save**) writes the CSV and reimports it, so the game picks up the
new text right away. Unsaved translations are also saved whenever the editor saves (saving a scene, running the
project), and the editor asks about them when it closes.

### Shortcuts

Poedit's, active while the dock has focus. Use Cmd instead of Ctrl on macOS.

| Key | Action |
|---|---|
| Ctrl+Enter | Done: clear Needs Work and go to the next unfinished entry |
| Ctrl+↑ / Ctrl+↓ | Previous / next entry |
| Ctrl+Shift+↑ / Ctrl+Shift+↓ | Previous / next unfinished entry |
| Ctrl+B | Copy the source text into the translation |
| Ctrl+U | Toggle Needs Work |
| Ctrl+1 … Ctrl+9 | Use suggestion 1 … 9 |
| Ctrl+F | Filter |
| Ctrl+S | Save |
| Ctrl+Z / Ctrl+Shift+Z | Undo / redo catalog changes (with the list focused; in a text box they undo its typing) |

## Checks

Like Poedit's validation, each translation is compared against its source text:

| Check | Severity |
|---|---|
| Placeholders differ: `%s`, `%d`, `%05.2f`… (String's `%` operator) and `{name}`, `{0}` (`String.format()`) | Error |
| Two entries share a key and context (Godot keeps only the last) | Error |
| BBCode tags differ (`[b]`, `[/b]`, `[color=…]`…) | Warning |
| Different number of line breaks (real ones or `\n`) | Warning |
| Leading or trailing whitespace differs | Warning |
| The source ends with `.` `!` `?` `:` `…` `,` `;` and the translation doesn't (full-width `。！？：、` count) | Warning |

When the source is the key column and the key is an id (`SHARE_MESSAGE`, `menu.start`), there's no text to
compare against, so only the duplicate check runs. Keys written as text (`"Hello, %s!"`) are checked as usual.

## The CSV file

Stele reads a file the way Godot's CSV importer does, and honours the file's import options (delimiter):

```csv
keys,?context,?plural,en,ja,fr,_notes
?pluralrule,,,,,nplurals=2; plural=(n > 1);,
MENU_START,,,Start Game,ゲームスタート,Commencer,Main menu button
OPEN,verb,,Open,開く,Ouvrir,
APPLE,,APPLES,%d apple,%d個のりんご,%d pomme,
,,,%d apples,,%d pommes,
```

| Column / row | Meaning |
|---|---|
| First column | The key (`tr("MENU_START")`). |
| A locale (`en`, `ja`, `pt_BR`…) | One language. |
| `_anything` | Ignored by Godot: notes for translators. Use it for grouping columns like `_section` too. |
| `?context` | Tells apart entries with the same key (`tr("OPEN", "verb")`). |
| `?plural` | Makes the entry plural; the rows below it with an empty key hold the other plural forms (`tr_n()`). |
| `?pluralrule` row | Overrides a language's plural rule. Kept as is; not shown. |

Godot accepts almost any word as a locale, so a column named `section` or `comment` becomes a translation of its
own. Stele marks such columns "(not a language)", doesn't pick them by default, and shows a warning in the status
bar; click it to rename the column to `_section` (undoable).

Saving rewrites the file from what was read, so columns, rows and special rows Stele doesn't show stay as they
were, and a UTF-8 byte order mark (which spreadsheet apps rely on) is kept. Quoting is normalised: cells are only
quoted when they need it. Empty lines are dropped, as the importer does.

CSV has nowhere to store Needs Work flags or translator comments, so Stele keeps them in a small JSON file next
to the CSV (`strings.csv` → `strings.csv.stele`). Commit it along with the CSV so your team shares them. It's
deleted when there's nothing left to keep.

## Not supported (yet)

- `.po` / `.pot` files: Godot can import those directly, and Poedit itself handles them.
- Removing a language column (do it in a text editor or spreadsheet).
- Machine translation.
