@tool
extends EditorDock
## Bottom dock that translates Godot CSV files the way Poedit translates .po catalogs:
## a list of entries where unfinished ones stand out, the source text above the
## translation, translation memory suggestions, notes and comments beside them, live
## validation and a progress bar. Catalog edits are undoable while the list has focus.

const Catalog := preload("catalog.gd")
const Validator := preload("validator.gd")
const TranslationMemory := preload("translation_memory.gd")

enum Show { ALL, UNFINISHED, NEEDS_WORK, ISSUES, TRANSLATED }
enum Order { FILE, SOURCE, TRANSLATION }
enum Action { NEW, OPEN, SAVE, RELOAD, ADD_ENTRY, RENAME_ENTRY, DELETE_ENTRY, ADD_FORM, REMOVE_FORM,
	ADD_LANGUAGE, PRE_TRANSLATE, VALIDATE, REGISTER, UNDO, REDO, MOVE_UP, MOVE_DOWN, TOGGLE_NEEDS_WORK, COPY_KEY }
const UNFINISHED_FIRST := 100 # View menu id, after the Order ids
const SECTIONS_FROM := 200 # View menu ids: 200 = no sections, 200 + column = sections from that column
## Note columns with these names (without the "_") hold sections by default.
const SECTION_COLUMNS: Array[String] = ["section", "category", "group", "screen", "scene", "page"]

const SETTING_TRANSLATIONS := "internationalization/locale/translations"
const META_SECTION := "stele"
const MAX_LIST_TEXT := 200
## Keys like "SHARE_MESSAGE" are ids, not text: nothing to check a translation against.
const ID_PATTERN := "^[A-Za-z0-9_.:/-]+$"

static var _id_regex := RegEx.create_from_string(ID_PATTERN)

var _plugin: EditorPlugin
var _catalog: Catalog
var _memory := TranslationMemory.new()
var _undo := UndoRedo.new()
var _saved_version := 0
var _unsaved_notes := false # notes and comments are saved, but not undoable
var _source := Catalog.KEY_COLUMN
var _target := -1
var _entry: Catalog.Entry
var _edit_before := {} # the entry's state when editing it began: one undo step per visit
var _items := {} # Entry -> TreeItem
var _issues := {} # Entry -> Array[Dictionary]
var _duplicates := {}
var _suggestions: Array[Dictionary] = []
var _terms: Array[Dictionary] = []
var _order := Order.FILE
var _unfinished_first := false
var _group_column := -1 # the column whose values are sections, or -1
var _section_value: Variant = null # the section shown, or null for all
var _updating := false
var _files := PackedStringArray()
var _pending := Callable() # what to do once unsaved changes are saved or discarded
var _col_key := -1
var _col_source := 1
var _col_translation := 2

var _file_select: OptionButton
var _source_select: OptionButton
var _target_select: OptionButton
var _section_select: OptionButton
var _filter: LineEdit
var _show: OptionButton
var _actions: PopupMenu
var _view: PopupMenu
var _empty: Label
var _main: HSplitContainer
var _tree: Tree
var _add_entry: Button
var _info: Label
var _source_view: TextEdit
var _source_plural_label: Label
var _source_plural_view: TextEdit
var _forms: TabContainer
var _form_edits: Array[TextEdit] = []
var _add_form: Button
var _remove_form: Button
var _needs_work: Button
var _issue_view: RichTextLabel
var _memory_view: RichTextLabel
var _context: PopupMenu
var _section_menu: PopupMenu
var _notes_box: VBoxContainer
var _note_edits := {} # column -> TextEdit
var _comment: TextEdit
var _status: Label
var _message: Label
var _register: Button
var _not_language: Button
var _progress: ProgressBar

var _file_dialog: EditorFileDialog
var _entry_dialog: ConfirmationDialog
var _entry_renaming := false
var _key_edit: LineEdit
var _context_label: Label
var _context_edit: LineEdit
var _plural_label: Label
var _plural_edit: LineEdit
var _source_text_label: Label
var _source_text_edit: LineEdit
var _entry_error: Label
var _language_dialog: ConfirmationDialog
var _language_edit: LineEdit
var _language_name: Label
var _unsaved_dialog: ConfirmationDialog
var _rename_column_dialog: ConfirmationDialog
var _alert: AcceptDialog


func setup(plugin: EditorPlugin) -> void:
	_plugin = plugin
	title = "Stele"
	layout_key = "stele_translations"
	icon_name = &"Translation"
	default_slot = DOCK_SLOT_BOTTOM
	available_layouts = DOCK_LAYOUT_HORIZONTAL | DOCK_LAYOUT_FLOATING
	custom_minimum_size.y = 300

	var box := VBoxContainer.new()
	add_child(box)
	_build_toolbar(box)

	_empty = Label.new()
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_empty.add_theme_color_override(&"font_color", _color(&"disabled_font_color"))
	box.add_child(_empty)

	_main = HSplitContainer.new()
	_main.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(_main)
	_build_list(_main)
	var side_split := HSplitContainer.new()
	side_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_main.add_child(side_split)
	_build_editor(side_split)
	_build_sidebar(side_split)
	_build_status_bar(box)
	_build_dialogs()
	_update_view()


## Rescans the project for translation CSVs, and reloads the open one if it changed on disk.
func refresh_files() -> void:
	var files := PackedStringArray()
	_collect_files(EditorInterface.get_resource_filesystem().get_filesystem(), files)
	files.sort()
	_files = files
	_memory.set_files(files)
	_fill_file_select()
	if _catalog and FileAccess.file_exists(_catalog.path) \
			and FileAccess.get_modified_time(_catalog.path) != _catalog.modified_time:
		if _is_dirty():
			_say("%s changed on disk. Catalog → Reload from Disk drops your unsaved changes." % _catalog.path.get_file())
		else:
			_reload()
	_update_status()


## Opens the file Stele had open when the editor last closed.
func reopen_last() -> void:
	var last: String = EditorInterface.get_editor_settings().get_project_metadata(META_SECTION, "last_file", "")
	if not last.is_empty() and FileAccess.file_exists(last):
		_open(last)


## Opens [param file], translating into [param locale] if given; asks about unsaved changes first.
func open_file(file: String, locale := "") -> void:
	if _catalog and file == _catalog.path:
		if not locale.is_empty():
			_set_target(_locale_column(locale))
		return
	_confirm_unsaved(func() -> void: _open(file, locale))


func is_dirty() -> bool:
	_flush_edit()
	return _is_dirty()


func get_file() -> String:
	return _catalog.path if _catalog else ""


## Saves if there are unsaved changes. Returns false only if saving failed.
func save() -> bool:
	return _save() if is_dirty() else true


func _exit_tree() -> void:
	_flush_edit()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_undo.free()
	elif what == NOTIFICATION_DRAG_END and _tree:
		_tree.drop_mode_flags = Tree.DROP_MODE_DISABLED


# --- Building the UI ---------------------------------------------------------------------

func _build_toolbar(parent: Control) -> void:
	var toolbar := HBoxContainer.new()
	parent.add_child(toolbar)
	var catalog_menu := MenuButton.new()
	catalog_menu.text = "Catalog"
	catalog_menu.flat = false
	catalog_menu.switch_on_hover = true
	_actions = catalog_menu.get_popup()
	_actions.add_icon_item(_icon("New"), "New Translation File…", Action.NEW)
	_actions.add_icon_item(_icon("Load"), "Open…", Action.OPEN)
	_actions.add_icon_item(_icon("Save"), "Save", Action.SAVE)
	_actions.add_icon_item(_icon("Reload"), "Reload from Disk", Action.RELOAD)
	_actions.add_separator()
	_actions.add_icon_item(_icon("Add"), "Add Entry…", Action.ADD_ENTRY)
	_actions.add_icon_item(_icon("Rename"), "Rename Entry…", Action.RENAME_ENTRY)
	_actions.add_icon_item(_icon("Remove"), "Delete Entry", Action.DELETE_ENTRY)
	_actions.add_item("Add Plural Form", Action.ADD_FORM)
	_actions.add_item("Remove Last Plural Form", Action.REMOVE_FORM)
	_actions.add_separator()
	_actions.add_icon_item(_icon("Translation"), "Add Language…", Action.ADD_LANGUAGE)
	_actions.add_item("Pre-translate from Memory", Action.PRE_TRANSLATE)
	_actions.add_icon_item(_icon("StatusWarning"), "Validate", Action.VALIDATE)
	_actions.add_item("Add Languages to Project Settings", Action.REGISTER)
	_actions.add_separator()
	_actions.add_icon_item(_icon("UndoRedo"), "Undo", Action.UNDO)
	_actions.add_item("Redo", Action.REDO)
	_actions.id_pressed.connect(_on_action)
	_actions.about_to_popup.connect(_update_actions)
	toolbar.add_child(catalog_menu)

	_file_select = OptionButton.new()
	_file_select.custom_minimum_size.x = 180 * EditorInterface.get_editor_scale()
	_file_select.fit_to_longest_item = false
	_file_select.clip_text = true
	_file_select.tooltip_text = "Translation CSVs in the project"
	_file_select.item_selected.connect(_on_file_selected)
	toolbar.add_child(_file_select)
	_tool_button(toolbar, "Save", "Save (%s+S)" % _mod(), _save)
	toolbar.add_child(VSeparator.new())

	var source_label := Label.new()
	source_label.text = "From"
	toolbar.add_child(source_label)
	_source_select = OptionButton.new()
	_source_select.tooltip_text = "Source text: the key or a language column"
	_source_select.item_selected.connect(func(index: int) -> void: _set_source(_source_select.get_item_id(index)))
	toolbar.add_child(_source_select)
	var target_label := Label.new()
	target_label.text = "To"
	toolbar.add_child(target_label)
	_target_select = OptionButton.new()
	_target_select.tooltip_text = "The language you're translating into"
	_target_select.item_selected.connect(func(index: int) -> void: _set_target(_target_select.get_item_id(index)))
	toolbar.add_child(_target_select)
	_tool_button(toolbar, "Add", "Add a language column", _ask_language)
	toolbar.add_child(VSeparator.new())

	_section_select = OptionButton.new()
	_section_select.tooltip_text = "Show one section. The sort menu picks which column holds sections."
	_section_select.fit_to_longest_item = false
	_section_select.clip_text = true
	_section_select.custom_minimum_size.x = 140 * EditorInterface.get_editor_scale()
	_section_select.item_selected.connect(_on_section_selected)
	_section_select.hide()
	toolbar.add_child(_section_select)
	_filter = LineEdit.new()
	_filter.placeholder_text = "Filter (%s+F)" % _mod()
	_filter.clear_button_enabled = true
	_filter.right_icon = _icon("Search")
	_filter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_filter.custom_minimum_size.x = 120 * EditorInterface.get_editor_scale()
	_filter.text_changed.connect(func(_text: String) -> void: _rebuild_list())
	toolbar.add_child(_filter)
	_show = OptionButton.new()
	for label in ["All", "Unfinished", "Needs Work", "With Issues", "Translated"]:
		_show.add_item(label)
	_show.tooltip_text = "Which entries to list"
	_show.item_selected.connect(func(_index: int) -> void: _rebuild_list())
	toolbar.add_child(_show)
	var view_menu := MenuButton.new()
	view_menu.icon = _icon("Sort")
	view_menu.tooltip_text = "Sort order and sections"
	_view = view_menu.get_popup()
	_view.id_pressed.connect(_on_view)
	toolbar.add_child(view_menu)
	_fill_view_menu()


func _build_list(parent: Control) -> void:
	_tree = Tree.new()
	_tree.hide_root = true
	_tree.select_mode = Tree.SELECT_ROW
	_tree.column_titles_visible = true
	_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tree.size_flags_stretch_ratio = 1.3
	_tree.custom_minimum_size.x = 240 * EditorInterface.get_editor_scale()
	_tree.item_selected.connect(_on_item_selected)
	_tree.item_activated.connect(_focus_editor)
	_tree.gui_input.connect(_on_tree_input)
	_tree.allow_rmb_select = true
	_tree.item_mouse_selected.connect(_on_tree_clicked)
	_tree.empty_clicked.connect(_on_tree_clicked)
	_tree.set_drag_forwarding(_get_drag_data, _can_drop_data, _drop_data)
	parent.add_child(_tree)
	_context = PopupMenu.new()
	_context.id_pressed.connect(_on_action)
	add_child(_context)
	_section_menu = PopupMenu.new()
	_section_menu.id_pressed.connect(_on_section_menu)
	_context.add_child(_section_menu)
	_add_entry = Button.new()
	_add_entry.flat = true
	_add_entry.icon = _icon("Add")
	_add_entry.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_add_entry.focus_mode = Control.FOCUS_NONE
	_add_entry.tooltip_text = "Add Entry…"
	_add_entry.pressed.connect(func() -> void: _on_action(Action.ADD_ENTRY))
	_tree.add_child(_add_entry)
	_tree.resized.connect(_place_add_entry)
	_tree.theme_changed.connect(_place_add_entry)


func _build_editor(parent: Control) -> void:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.size_flags_stretch_ratio = 1.6
	box.custom_minimum_size.x = 240 * EditorInterface.get_editor_scale()
	parent.add_child(box)

	var source_header := HBoxContainer.new()
	box.add_child(source_header)
	source_header.add_child(_header("Source text"))
	_info = Label.new()
	_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_info.clip_text = true
	_info.add_theme_color_override(&"font_color", _color(&"disabled_font_color"))
	source_header.add_child(_info)
	_source_view = _text_edit()
	_source_view.editable = false
	box.add_child(_source_view)
	_source_plural_label = _header("Plural")
	box.add_child(_source_plural_label)
	_source_plural_view = _text_edit()
	_source_plural_view.editable = false
	box.add_child(_source_plural_view)

	var translation_header := HBoxContainer.new()
	box.add_child(translation_header)
	var translation_label := _header("Translation")
	translation_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	translation_label.mouse_filter = Control.MOUSE_FILTER_PASS
	translation_label.tooltip_text = "{m}+Enter: done, go to the next unfinished entry\n{m}+↑ / {m}+↓: previous / next entry\n{m}+Shift+↑ / ↓: previous / next unfinished entry\n{m}+B: copy the source text\n{m}+U: toggle Needs Work\n{m}+1 … 5: use a translation memory match\n{m}+F: filter · {m}+S: save\n{m}+Z / {m}+Shift+Z: undo / redo (with the list focused)\nAlt+↑ / Alt+↓: move the entry (with the list focused)".format({m = _mod()})
	translation_header.add_child(translation_label)
	_add_form = _tool_button(translation_header, "Add", "Add a plural form (in every language)",
		func() -> void: _on_action(Action.ADD_FORM))
	_remove_form = _tool_button(translation_header, "Remove", "Remove the last plural form (in every language)",
		func() -> void: _on_action(Action.REMOVE_FORM))
	_needs_work = Button.new()
	_needs_work.text = "Needs Work"
	_needs_work.toggle_mode = true
	_needs_work.tooltip_text = "Flag the translation for review (%s+U). Editing it clears the flag." % _mod()
	_needs_work.toggled.connect(_set_needs_work)
	translation_header.add_child(_needs_work)
	_forms = TabContainer.new()
	_forms.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_forms.size_flags_stretch_ratio = 1.3
	box.add_child(_forms)
	_ensure_forms(1)

	_issue_view = RichTextLabel.new()
	_issue_view.bbcode_enabled = true
	_issue_view.fit_content = true
	_issue_view.scroll_active = false
	box.add_child(_issue_view)


func _build_sidebar(parent: Control) -> void:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size.x = 200 * EditorInterface.get_editor_scale()
	parent.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)

	var memory_header := _header("Translation Memory")
	memory_header.mouse_filter = Control.MOUSE_FILTER_PASS
	memory_header.tooltip_text = "Close matches from this file and the project's other translation CSVs, with the words that differ highlighted, and translations of shorter entries that appear in this text. Click to use."
	box.add_child(memory_header)
	_memory_view = RichTextLabel.new()
	_memory_view.bbcode_enabled = true
	_memory_view.fit_content = true
	_memory_view.scroll_active = false
	_memory_view.meta_underlined = false
	_memory_view.meta_clicked.connect(_on_memory_clicked)
	box.add_child(_memory_view)
	_notes_box = VBoxContainer.new()
	box.add_child(_notes_box)
	box.add_child(_header("Translator Comment"))
	_comment = _text_edit()
	_comment.placeholder_text = "Translator comment for this language"
	_comment.size_flags_vertical = Control.SIZE_FILL
	_comment.scroll_fit_content_height = true
	_comment.custom_minimum_size.y = 40 * EditorInterface.get_editor_scale()
	_comment.text_changed.connect(_on_comment_changed)
	box.add_child(_comment)


func _build_status_bar(parent: Control) -> void:
	var bar := HBoxContainer.new()
	parent.add_child(bar)
	_status = Label.new()
	bar.add_child(_status)
	_message = Label.new()
	_message.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_message.clip_text = true
	_message.add_theme_color_override(&"font_color", _color(&"disabled_font_color"))
	bar.add_child(_message)
	_register = Button.new()
	_register.flat = true
	_register.icon = _icon("StatusWarning")
	_register.tooltip_text = "Godot only loads translations listed in Project Settings → Localization"
	_register.pressed.connect(_register_translations)
	bar.add_child(_register)
	_not_language = Button.new()
	_not_language.flat = true
	_not_language.icon = _icon("StatusWarning")
	_not_language.pressed.connect(_ask_rename_column)
	bar.add_child(_not_language)
	_progress = ProgressBar.new()
	_progress.custom_minimum_size.x = 160 * EditorInterface.get_editor_scale()
	_progress.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.add_child(_progress)


func _build_dialogs() -> void:
	_file_dialog = EditorFileDialog.new()
	_file_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	_file_dialog.add_filter("*.csv", "CSV Translations")
	_file_dialog.file_selected.connect(_on_file_dialog_selected)
	add_child(_file_dialog)

	_entry_dialog = ConfirmationDialog.new()
	var grid := GridContainer.new()
	grid.columns = 2
	_entry_dialog.add_child(grid)
	_key_edit = _dialog_field(grid, "Key", "Unique id, e.g. MENU_START").edit
	var context_field := _dialog_field(grid, "Context", "Tells apart entries with the same key")
	_context_label = context_field.label
	_context_edit = context_field.edit
	var plural_field := _dialog_field(grid, "Plural", "Optional: plural of the key, makes a plural entry")
	_plural_label = plural_field.label
	_plural_edit = plural_field.edit
	var source_field := _dialog_field(grid, "Source text", "")
	_source_text_label = source_field.label
	_source_text_edit = source_field.edit
	_entry_error = Label.new()
	_entry_error.add_theme_color_override(&"font_color", _color(&"error_color"))
	grid.add_child(Control.new())
	grid.add_child(_entry_error)
	for edit in [_key_edit, _context_edit]:
		edit.text_changed.connect(func(_text: String) -> void: _validate_entry_dialog())
	_entry_dialog.register_text_enter(_key_edit)
	_entry_dialog.confirmed.connect(_on_entry_dialog_confirmed)
	add_child(_entry_dialog)

	_language_dialog = ConfirmationDialog.new()
	_language_dialog.title = "Add Language"
	var language_box := VBoxContainer.new()
	_language_dialog.add_child(language_box)
	_language_edit = LineEdit.new()
	_language_edit.placeholder_text = "Locale code, e.g. fr, pt_BR, zh_Hant"
	_language_edit.custom_minimum_size.x = 280 * EditorInterface.get_editor_scale()
	_language_edit.text_changed.connect(_validate_language)
	language_box.add_child(_language_edit)
	_language_name = Label.new()
	language_box.add_child(_language_name)
	_language_dialog.register_text_enter(_language_edit)
	_language_dialog.confirmed.connect(func() -> void: _add_language(_language_edit.text.strip_edges()))
	add_child(_language_dialog)

	_unsaved_dialog = ConfirmationDialog.new()
	_unsaved_dialog.title = "Unsaved Changes"
	_unsaved_dialog.ok_button_text = "Save"
	_unsaved_dialog.add_button("Don't Save", true, "discard")
	_unsaved_dialog.confirmed.connect(func() -> void:
		if _save():
			_run_pending())
	_unsaved_dialog.custom_action.connect(func(_action: StringName) -> void:
		_unsaved_dialog.hide()
		_run_pending())
	_unsaved_dialog.canceled.connect(func() -> void:
		_pending = Callable()
		_fill_file_select())
	add_child(_unsaved_dialog)

	_rename_column_dialog = ConfirmationDialog.new()
	_rename_column_dialog.title = "Not a Language"
	_rename_column_dialog.ok_button_text = "Rename"
	_rename_column_dialog.confirmed.connect(_rename_column)
	add_child(_rename_column_dialog)

	_alert = AcceptDialog.new()
	_alert.title = "Stele"
	add_child(_alert)


# --- Opening and saving ------------------------------------------------------------------

func _open(file: String, locale := "", entry_id := "") -> void:
	var catalog := Catalog.new()
	var error := catalog.load_file(file, Catalog.import_delimiter(file))
	if error != OK:
		_show_alert("Could not open %s: %s." % [file, error_string(error)])
		_fill_file_select()
		return
	_catalog = catalog
	_undo.clear_history(false)
	_saved_version = _undo.get_version()
	_unsaved_notes = false
	_entry = null
	_edit_before = {}
	_pick_columns(locale)
	EditorInterface.get_editor_settings().set_project_metadata(META_SECTION, "last_file", file)
	_configure()
	_rebuild_list()
	var entry := catalog.find_entry(entry_id) if not entry_id.is_empty() else null
	var root := _tree.get_root()
	if entry == null and root and root.get_child_count() > 0:
		entry = root.get_child(0).get_metadata(0)
	_go_to(entry)
	_say("")


func _reload() -> void:
	if _catalog == null:
		return
	_open(_catalog.path, "", _catalog.id(_entry) if _entry else "")


func _save() -> bool:
	if _catalog == null:
		return false
	_flush_edit()
	var error := _catalog.save()
	if error != OK:
		_show_alert("Could not save %s: %s." % [_catalog.path, error_string(error)])
		return false
	_saved_version = _undo.get_version()
	_unsaved_notes = false
	# The same check the editor runs on focus: it reimports the CSV into .translation files.
	# Calling reimport_files() here instead crashes when saving while the editor quits.
	EditorInterface.get_resource_filesystem().scan_sources()
	_say("Saved %s." % _catalog.path.get_file())
	_update_status()
	return true


func _is_dirty() -> bool:
	return _catalog != null and (_undo.get_version() != _saved_version or _unsaved_notes)


func _confirm_unsaved(then: Callable) -> void:
	if not is_dirty():
		then.call()
		return
	_pending = then
	_unsaved_dialog.dialog_text = "Save changes to %s first?" % _catalog.path.get_file()
	_unsaved_dialog.popup_centered()


func _run_pending() -> void:
	var pending := _pending
	_pending = Callable()
	if pending.is_valid():
		pending.call()


func _collect_files(directory: EditorFileSystemDirectory, files: PackedStringArray) -> void:
	if directory == null:
		return
	for i in directory.get_file_count():
		var file := directory.get_file_path(i)
		if Catalog.is_translation_csv(file):
			files.append(file)
	for i in directory.get_subdir_count():
		_collect_files(directory.get_subdir(i), files)


func _fill_file_select() -> void:
	_file_select.clear()
	var current := get_file()
	var files := _files.duplicate()
	if not current.is_empty() and current not in files:
		files.append(current)
	if current.is_empty():
		_file_select.add_item("Select a translation file")
		_file_select.set_item_disabled(0, true)
	for file in files:
		_file_select.add_item(file.trim_prefix("res://"))
		_file_select.set_item_metadata(_file_select.item_count - 1, file)
		if file == current:
			_file_select.select(_file_select.item_count - 1)
	if current.is_empty():
		_file_select.select(0)


func _on_file_selected(index: int) -> void:
	var file: Variant = _file_select.get_item_metadata(index)
	if file is String:
		open_file(file)


func _on_file_dialog_selected(file: String) -> void:
	if _file_dialog.file_mode == EditorFileDialog.FILE_MODE_OPEN_FILE:
		open_file(file)
		return
	_confirm_unsaved(func() -> void:
		var f := FileAccess.open(file, FileAccess.WRITE)
		if f == null:
			_show_alert("Could not create %s: %s." % [file, error_string(FileAccess.get_open_error())])
			return
		f.store_csv_line(PackedStringArray(["keys", "en"]))
		f.close()
		EditorInterface.get_resource_filesystem().scan()
		_open(file))


# --- Columns -----------------------------------------------------------------------------

## Picks the source and target columns: remembered per file, else the first language
## as the source and the second as the target (or the key into the only language).
func _pick_columns(locale := "") -> void:
	var languages := _catalog.locale_columns()
	var remembered: Dictionary = EditorInterface.get_editor_settings().get_project_metadata(
		META_SECTION, "columns", {}).get(_catalog.path, {})
	# Defaults skip columns Godot takes for locales that aren't languages ("section").
	var real := Array(languages).filter(func(column: int) -> bool: return Catalog.is_language(_catalog.header(column)))
	var defaults := real if not real.is_empty() else Array(languages)
	_source = Catalog.KEY_COLUMN if defaults.size() < 2 else defaults[0]
	_target = -1 if defaults.is_empty() else defaults[mini(1, defaults.size() - 1)]
	if remembered.has("source"):
		var column := _catalog.column_index(remembered.source)
		if column == Catalog.KEY_COLUMN or column in languages:
			_source = column
	if remembered.has("target") and _catalog.column_index(remembered.target) in languages:
		_target = _catalog.column_index(remembered.target)
	if not locale.is_empty() and _locale_column(locale) != -1:
		_target = _locale_column(locale)
	if _target == _source:
		_source = Catalog.KEY_COLUMN
		for column in languages:
			if column != _target:
				_source = column
				break


func _remember_columns() -> void:
	var settings := EditorInterface.get_editor_settings()
	var columns: Dictionary = settings.get_project_metadata(META_SECTION, "columns", {})
	columns[_catalog.path] = {source = _catalog.header(_source), target = _catalog.header(_target)}
	settings.set_project_metadata(META_SECTION, "columns", columns)


func _set_source(column: int) -> void:
	if _catalog == null or column == _source:
		return
	_flush_edit()
	_source = column
	if _target == _source:
		_target = -1
		for language in _catalog.locale_columns():
			if language != _source:
				_target = language
				break
	_columns_changed()


func _set_target(column: int) -> void:
	if _catalog == null or column == -1 or column == _target:
		return
	_flush_edit()
	_target = column
	if _source == _target:
		_source = Catalog.KEY_COLUMN
	_columns_changed()


func _columns_changed() -> void:
	_remember_columns()
	_configure()
	_rebuild_list()
	_go_to(_entry)


func _locale_column(locale: String) -> int:
	var wanted := TranslationServer.standardize_locale(locale)
	for column in _catalog.locale_columns():
		if TranslationServer.standardize_locale(_catalog.header(column)) == wanted:
			return column
	return -1


## Sets up everything that depends on the catalog's columns.
func _configure() -> void:
	_fill_file_select()
	_source_select.clear()
	_target_select.clear()
	_source_select.add_item("Key", Catalog.KEY_COLUMN)
	for column in _catalog.locale_columns():
		_source_select.add_item(_language(column), column)
		if column != _source:
			_target_select.add_item(_language(column), column)
	_source_select.select(_source_select.get_item_index(_source))
	if _target != -1:
		_target_select.select(_target_select.get_item_index(_target))

	var show_key := _source != Catalog.KEY_COLUMN
	_tree.columns = 4 if show_key else 3
	_col_key = 1 if show_key else -1
	_col_source = 2 if show_key else 1
	_col_translation = _col_source + 1
	_tree.set_column_expand(0, false)
	_tree.set_column_custom_minimum_width(0, int(maxf(28 * EditorInterface.get_editor_scale(), _add_entry.get_combined_minimum_size().x)))
	if show_key:
		_tree.set_column_title(_col_key, "Key")
		_tree.set_column_expand_ratio(_col_key, 1)
		_tree.set_column_custom_minimum_width(_col_key, int(110 * EditorInterface.get_editor_scale()))
	_tree.set_column_title(_col_source, "Source: " + _language(_source))
	_tree.set_column_title(_col_translation, "Translation: " + _language(_target) if _target != -1 else "Translation")
	for column in range(1, _tree.columns):
		_tree.set_column_clip_content(column, true)
		_tree.set_column_title_alignment(column, HORIZONTAL_ALIGNMENT_LEFT)
	_tree.set_column_expand_ratio(_col_source, 2)
	_tree.set_column_expand_ratio(_col_translation, 2)
	_place_add_entry.call_deferred()
	_group_column = _pick_group_column()
	_fill_view_menu()

	for child in _notes_box.get_children():
		_notes_box.remove_child(child)
		child.queue_free()
	_note_edits.clear()
	for column in _catalog.note_columns():
		var note_name := _catalog.header(column).trim_prefix("_").capitalize()
		_notes_box.add_child(_header("Notes" if note_name.is_empty() or note_name == "Notes" else "Notes: " + note_name))
		var edit := _text_edit()
		edit.size_flags_vertical = Control.SIZE_FILL
		edit.scroll_fit_content_height = true
		edit.custom_minimum_size.y = 32 * EditorInterface.get_editor_scale()
		edit.placeholder_text = "Notes for translators (the %s column)" % _catalog.header(column)
		edit.text_changed.connect(_on_note_changed.bind(column))
		_notes_box.add_child(edit)
		_note_edits[column] = edit
	_update_view()


func _language(column: int) -> String:
	if column == Catalog.KEY_COLUMN:
		return "Key"
	var header := _catalog.header(column)
	if not Catalog.is_language(header):
		return "%s (not a language)" % header
	var language := TranslationServer.get_locale_name(TranslationServer.standardize_locale(header))
	return "%s (%s)" % [language, header] if language else header


# --- The list ----------------------------------------------------------------------------

func _rebuild_list() -> void:
	_updating = true
	_tree.clear()
	_items.clear()
	_issues.clear()
	if _catalog == null or _target == -1:
		_updating = false
		return
	_fill_sections()
	_duplicates = _catalog.duplicate_ids()
	var root := _tree.create_item()
	var filter := _filter.text.strip_edges()
	for entry in _catalog.messages():
		_issues[entry] = _check(entry)
	for entry in _sorted(_catalog.messages()):
		if not _matches(entry, filter):
			continue
		var item := _tree.create_item(root)
		item.set_metadata(0, entry)
		_items[entry] = item
		_update_item(entry)
	var selected: TreeItem = _items.get(_entry)
	if selected:
		selected.select(0)
		_tree.scroll_to_item(selected)
	_updating = false
	_update_status()


func _sorted(entries: Array[Catalog.Entry]) -> Array[Catalog.Entry]:
	var order := {}
	var keys := {}
	for i in entries.size():
		var entry := entries[i]
		order[entry] = i
		match _order:
			Order.SOURCE: keys[entry] = _catalog.source_forms(entry, _source)[0]
			Order.TRANSLATION: keys[entry] = entry.cell(_target)
	var unfinished := {}
	if _unfinished_first:
		for entry in entries:
			unfinished[entry] = _catalog.status(entry, _target) != Catalog.Status.TRANSLATED
	var sorted := entries.duplicate()
	sorted.sort_custom(func(a: Catalog.Entry, b: Catalog.Entry) -> bool:
		if _unfinished_first and unfinished[a] != unfinished[b]:
			return unfinished[a]
		if _order != Order.FILE:
			var compared: int = String(keys[a]).naturalnocasecmp_to(keys[b])
			if compared != 0:
				return compared < 0
		return order[a] < order[b])
	return sorted


func _matches(entry: Catalog.Entry, filter: String) -> bool:
	var status := _catalog.status(entry, _target)
	match _show.selected:
		Show.UNFINISHED:
			if status == Catalog.Status.TRANSLATED:
				return false
		Show.NEEDS_WORK:
			if status != Catalog.Status.NEEDS_WORK:
				return false
		Show.ISSUES:
			if _issues.get(entry, []).is_empty():
				return false
		Show.TRANSLATED:
			if status != Catalog.Status.TRANSLATED:
				return false
	if _section_value != null and entry.cell(_group_column) != _section_value:
		return false
	if filter.is_empty():
		return true
	for text in [_catalog.key(entry), _catalog.context(entry)] + Array(_catalog.source_forms(entry, _source)) \
			+ Array(_catalog.forms(entry, _target)):
		if String(text).findn(filter) != -1:
			return true
	return false


func _update_item(entry: Catalog.Entry) -> void:
	_issues[entry] = _check(entry)
	var item: TreeItem = _items.get(entry)
	if item == null:
		return
	var status := _catalog.status(entry, _target)
	var issues: Array[Dictionary] = _issues[entry]
	var source := _catalog.source_forms(entry, _source)[0]
	var translations := _catalog.forms(entry, _target)
	if _col_key != -1:
		var context := _catalog.context(entry)
		item.set_text(_col_key, _catalog.key(entry) + (" (%s)" % context if context else ""))
	item.set_text(_col_source, _one_line(source))
	item.set_text(_col_translation, _one_line(translations[0]) + (" (+%d forms)" % (translations.size() - 1) if translations.size() > 1 else ""))

	var icon: Texture2D = null
	if issues.any(func(issue: Dictionary) -> bool: return issue.severity == Validator.Severity.ERROR):
		icon = _icon("StatusError")
	elif not issues.is_empty():
		icon = _icon("StatusWarning")
	item.set_icon(0, icon)
	var bold := EditorInterface.get_editor_theme().get_font(&"bold", &"EditorFonts")
	for column in range(1, _tree.columns):
		if status == Catalog.Status.NEEDS_WORK:
			item.set_custom_color(column, _color(&"warning_color"))
		else:
			item.clear_custom_color(column)
		item.set_custom_font(column, bold if status == Catalog.Status.UNTRANSLATED else null)
	var tooltip := "%s\n\n%s" % [source, "\n".join(translations)]
	tooltip += "\n\n" + ["Untranslated", "Needs work", "Translated"][status]
	for issue in issues:
		tooltip += "\n• " + issue.message
	for column in _tree.columns:
		item.set_tooltip_text(column, tooltip)


## Validation issues of [param entry] in the target language, per plural form.
func _check(entry: Catalog.Entry) -> Array[Dictionary]:
	var issues: Array[Dictionary] = []
	if _duplicates.has(_catalog.id(entry)):
		issues.append({severity = Validator.Severity.ERROR,
			message = "Another entry has the same key and context; Godot keeps only the last one."})
	var sources := _catalog.source_forms(entry, _source)
	if _source == Catalog.KEY_COLUMN and _id_regex.search(sources[0]):
		return issues
	var translations := _catalog.forms(entry, _target)
	for form in translations.size():
		for issue in Validator.check(sources[mini(form, sources.size() - 1)], translations[form]):
			if translations.size() > 1:
				issue.message = "%s: %s" % [_form_title(form, translations.size()), issue.message]
			issues.append(issue)
	return issues


## Puts the Add Entry button on the status column's empty header cell, measured the way Tree draws it.
func _place_add_entry() -> void:
	var panel := _tree.get_theme_stylebox(&"panel")
	var title := _tree.get_theme_stylebox(&"title_button_normal")
	var font := _tree.get_theme_font(&"title_button_font")
	var height := font.get_height(_tree.get_theme_font_size(&"title_button_font_size")) + title.get_minimum_size().y
	_add_entry.position = Vector2(panel.get_margin(SIDE_LEFT), panel.get_margin(SIDE_TOP))
	_add_entry.size = Vector2(_tree.get_column_width(0), height)


func _on_item_selected() -> void:
	if _updating:
		return
	var item := _tree.get_selected()
	if item:
		_select(item.get_metadata(0))


func _on_tree_clicked(at: Vector2, button: int) -> void:
	if button != MOUSE_BUTTON_RIGHT or _catalog == null or _target == -1:
		return
	if _tree.get_item_at_position(at) == null:
		_select(null)
	_context.clear()
	_context.add_icon_item(_icon("Add"), "Add Entry…", Action.ADD_ENTRY)
	if _entry:
		_context.add_icon_item(_icon("Rename"), "Rename Entry…", Action.RENAME_ENTRY, KEY_F2)
		_context.add_icon_item(_icon("Remove"), "Delete Entry", Action.DELETE_ENTRY, KEY_DELETE)
		_context.add_separator()
		var item: TreeItem = _items.get(_entry)
		_context.add_icon_item(_icon("MoveUp"), "Move Up", Action.MOVE_UP, (KEY_MASK_ALT | KEY_UP) as Key)
		_context.set_item_disabled(_context.item_count - 1, not _can_move() or item == null or item.get_prev() == null)
		_context.add_icon_item(_icon("MoveDown"), "Move Down", Action.MOVE_DOWN, (KEY_MASK_ALT | KEY_DOWN) as Key)
		_context.set_item_disabled(_context.item_count - 1, not _can_move() or item == null or item.get_next() == null)
		if _group_column != -1 and _group_column != _catalog.context_column:
			_fill_section_menu()
			_context.add_submenu_node_item("Move to Section", _section_menu)
		_context.add_separator()
		_context.add_check_item("Needs Work", Action.TOGGLE_NEEDS_WORK, (KEY_MASK_CMD_OR_CTRL | KEY_U) as Key)
		_context.set_item_checked(_context.item_count - 1, _catalog.is_needs_work(_entry, _target))
		_context.add_icon_item(_icon("ActionCopy"), "Copy Key", Action.COPY_KEY)
	_context.reset_size()
	_context.position = Vector2i(_tree.get_screen_position() + at)
	_context.popup()


func _fill_section_menu() -> void:
	_section_menu.clear()
	var sections := PackedStringArray()
	for entry in _catalog.messages():
		if entry.cell(_group_column) not in sections:
			sections.append(entry.cell(_group_column))
	for i in sections.size():
		_section_menu.add_radio_check_item(sections[i] if sections[i] else "No section", i)
		_section_menu.set_item_checked(i, sections[i] == _entry.cell(_group_column))
	_section_menu.set_meta(&"sections", sections)


## Gives the entry the picked section and moves it after that section's last entry.
func _on_section_menu(index: int) -> void:
	var section: String = _section_menu.get_meta(&"sections")[index]
	var entry := _entry
	if entry == null or entry.cell(_group_column) == section:
		return
	_flush_edit()
	var others := _catalog.entries.duplicate()
	others.erase(entry)
	var at := _catalog.entries.find(entry) # stays put when the section has no entries yet
	for i in others.size():
		if others[i].kind == Catalog.Kind.MESSAGE and others[i].cell(_group_column) == section:
			at = i + 1
	_commit("Move to Section", _apply_section.bind(entry, section, at),
		_apply_section.bind(entry, entry.cell(_group_column), _catalog.entries.find(entry)))


func _apply_section(entry: Catalog.Entry, section: String, index: int) -> void:
	entry.set_cell(_group_column, section)
	_catalog.remove_entry(entry)
	_catalog.insert_entry(entry, index)
	_rebuild_list()
	_go_to(entry)


## Entries can be moved while the list shows them in file order.
func _can_move() -> bool:
	return _order == Order.FILE and not _unfinished_first


## Moves the current entry past its neighbour in the list.
func _move(step: int) -> void:
	if _entry == null:
		return
	if not _can_move():
		_say("Sort by File Order, without Unfinished First, to move entries.")
		return
	var item: TreeItem = _items.get(_entry)
	var other := (item.get_prev() if step < 0 else item.get_next()) if item else null
	if other:
		_move_entry(_entry, other.get_metadata(0), step > 0)


## Moves [param entry] just before or after [param anchor] in the file.
func _move_entry(entry: Catalog.Entry, anchor: Catalog.Entry, after: bool) -> void:
	if entry == anchor:
		return
	_flush_edit()
	var old := _catalog.entries.find(entry)
	var others := _catalog.entries.duplicate()
	others.erase(entry)
	var index := others.find(anchor) + (1 if after else 0)
	if index != old:
		_commit("Move Entry", _apply_move.bind(entry, index), _apply_move.bind(entry, old))


func _apply_move(entry: Catalog.Entry, index: int) -> void:
	_catalog.remove_entry(entry)
	_catalog.insert_entry(entry, index)
	_rebuild_list()
	_go_to(entry)


func _get_drag_data(at: Vector2) -> Variant:
	var item := _tree.get_item_at_position(at)
	if item == null or not _can_move():
		return null
	var label := Label.new()
	label.text = _catalog.key(item.get_metadata(0))
	_tree.set_drag_preview(label)
	_tree.drop_mode_flags = Tree.DROP_MODE_INBETWEEN
	return {stele_entry = item.get_metadata(0)}


func _can_drop_data(_at: Vector2, data: Variant) -> bool:
	return data is Dictionary and data.has("stele_entry")


func _drop_data(at: Vector2, data: Variant) -> void:
	_tree.drop_mode_flags = Tree.DROP_MODE_DISABLED
	var target := _tree.get_item_at_position(at)
	var after := _tree.get_drop_section_at_position(at) > 0
	if target == null: # below the last entry
		var items := _tree.get_root().get_children()
		if items.is_empty():
			return
		target = items[-1]
		after = true
	_move_entry(data.stele_entry, target.get_metadata(0), after)


func _on_tree_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.keycode == KEY_DELETE and not key.is_command_or_control_pressed():
		_on_action(Action.DELETE_ENTRY)
		_tree.accept_event()
	elif key.keycode == KEY_F2:
		_on_action(Action.RENAME_ENTRY)
		_tree.accept_event()


## Makes [param entry] the edited entry, recording the previous entry's edit first.
func _select(entry: Catalog.Entry) -> void:
	_flush_edit()
	_go_to(entry)


## Shows [param entry] without recording anything: for undo/redo and rebuilds.
func _go_to(entry: Catalog.Entry) -> void:
	if entry and _catalog.entries.find(entry) == -1:
		entry = null
	_entry = entry
	var item: TreeItem = _items.get(entry)
	if item and not item.is_selected(0):
		_updating = true
		item.select(0)
		_tree.scroll_to_item(item)
		_updating = false
	elif item == null:
		_tree.deselect_all()
	_show_entry()


## Moves [param step] entries through the list; with [param unfinished], to the next
## entry that isn't translated, wrapping around.
func _go(step: int, unfinished: bool) -> void:
	if _catalog == null or _target == -1:
		return
	_flush_edit()
	var items := _tree.get_root().get_children() if _tree.get_root() else []
	if items.is_empty():
		return
	var index := items.find(_items.get(_entry))
	if index == -1 and step < 0:
		index = items.size()
	for i in range(1, items.size() + 1):
		var next := index + step * i
		if unfinished:
			next = posmod(next, items.size())
		elif next < 0 or next >= items.size():
			return
		var entry: Catalog.Entry = items[next].get_metadata(0)
		if not unfinished or (entry != _entry and _catalog.status(entry, _target) != Catalog.Status.TRANSLATED):
			_go_to(entry)
			return
	_say("Nothing left to translate in this list.")


# --- The editor --------------------------------------------------------------------------

func _show_entry() -> void:
	_updating = true
	var entry := _entry
	var editable := entry != null and _target != -1
	for edit in _form_edits:
		edit.editable = editable
	_needs_work.disabled = not editable
	_comment.editable = editable
	for edit: TextEdit in _note_edits.values():
		edit.editable = editable
	if not editable:
		_ensure_forms(1)
		_form_edits[0].text = ""
		_source_view.text = ""
		_source_plural_label.hide()
		_source_plural_view.hide()
		_add_form.hide()
		_remove_form.hide()
		_info.text = ""
		_comment.text = ""
		for edit: TextEdit in _note_edits.values():
			edit.text = ""
		_needs_work.set_pressed_no_signal(false)
		_issue_view.text = ""
		_memory_view.text = ""
		_suggestions.clear()
		_terms.clear()
		_edit_before = {}
		_updating = false
		return

	var info := PackedStringArray()
	if _source != Catalog.KEY_COLUMN:
		info.append("Key: " + _catalog.key(entry))
	if not _catalog.context(entry).is_empty():
		info.append("Context: " + _catalog.context(entry))
	_info.text = "  ·  ".join(info)
	var sources := _catalog.source_forms(entry, _source)
	_source_view.text = sources[0]
	_source_view.placeholder_text = "(empty in %s)" % _language(_source)
	var plural := _catalog.is_plural(entry)
	_source_plural_label.visible = plural
	_source_plural_view.visible = plural
	_source_plural_view.text = sources[1] if sources.size() > 1 else ""

	var translations := _catalog.forms(entry, _target)
	_ensure_forms(translations.size())
	for form in translations.size():
		if _form_edits[form].text != translations[form]:
			_form_edits[form].text = translations[form]
		_form_edits[form].clear_undo_history()
		_forms.set_tab_title(form, _form_title(form, translations.size()))
	_add_form.visible = plural
	_remove_form.visible = plural
	_remove_form.disabled = translations.size() <= 2
	_needs_work.set_pressed_no_signal(_catalog.is_needs_work(entry, _target))
	_comment.text = _catalog.comment(entry, _target)
	for column: int in _note_edits:
		_note_edits[column].text = entry.cell(column)
	_edit_before = _state(entry)
	_show_issues()
	_show_memory()
	_updating = false


func _ensure_forms(count: int) -> void:
	while _form_edits.size() < count:
		var edit := _text_edit()
		edit.placeholder_text = "Translation"
		edit.text_changed.connect(_on_form_changed.bind(_form_edits.size()))
		_forms.add_child(edit)
		_form_edits.append(edit)
	while _form_edits.size() > count:
		var edit: TextEdit = _form_edits.pop_back()
		_forms.remove_child(edit)
		edit.queue_free()
	_forms.tabs_visible = count > 1
	_forms.current_tab = clampi(_forms.current_tab, 0, count - 1)


func _form_title(form: int, count: int) -> String:
	if count == 2:
		return "Singular" if form == 0 else "Plural"
	return "Form %d" % (form + 1)


func _on_form_changed(form: int) -> void:
	if _updating or _entry == null or _target == -1:
		return
	var translations := _catalog.forms(_entry, _target)
	if form >= translations.size() or translations[form] == _form_edits[form].text:
		return
	translations[form] = _form_edits[form].text
	_catalog.set_forms(_entry, _target, translations)
	if _catalog.is_needs_work(_entry, _target):
		# Editing a translation is reviewing it, as in Poedit.
		_catalog.set_needs_work(_entry, _target, false)
		_needs_work.set_pressed_no_signal(false)
	_update_item(_entry)
	_show_issues()
	_update_status()


func _on_note_changed(column: int) -> void:
	if _updating or _entry == null or _entry.cell(column) == _note_edits[column].text:
		return
	_entry.set_cell(column, _note_edits[column].text)
	_unsaved_notes = true
	_update_status()


func _on_comment_changed() -> void:
	if _updating or _entry == null or _target == -1 or _catalog.comment(_entry, _target) == _comment.text:
		return
	_catalog.set_comment(_entry, _target, _comment.text)
	_unsaved_notes = true
	_update_status()


func _show_issues() -> void:
	var lines := PackedStringArray()
	for issue: Dictionary in _issues.get(_entry, []):
		var color := _color(&"error_color" if issue.severity == Validator.Severity.ERROR else &"warning_color")
		lines.append("[color=#%s]%s[/color]" % [color.to_html(false), _escape_bbcode(issue.message)])
	_issue_view.text = "\n".join(lines)
	_issue_view.visible = not lines.is_empty()


func _show_memory() -> void:
	var source := _catalog.source_forms(_entry, _source)[0]
	_suggestions = _memory.suggest(_catalog, _source, _target, source, _entry)
	_terms = _memory.terms(_catalog, _source, _target, source, _entry)
	var dim := _color(&"disabled_font_color").to_html(false)
	var lines := PackedStringArray()
	for i in _suggestions.size():
		var suggestion := _suggestions[i]
		var score := "Exact" if suggestion.score >= 1.0 else "%d%%" % roundi(suggestion.score * 100.0)
		lines.append("[url=s%d][b]%s[/b]  %s[/url]" % [i, score, _escape_bbcode(suggestion.text)])
		var note := "%s+%d" % [_mod(), i + 1]
		if suggestion.origin != _catalog.path.get_file():
			note += " · " + suggestion.origin
		lines.append("[color=#%s]%s  ·  %s[/color]" % [dim, _diff(suggestion.source, source), note])
	if not _terms.is_empty():
		lines.append("[b]Terms[/b]")
		for i in _terms.size():
			lines.append("[url=t%d]%s → %s[/url]" % [i, _escape_bbcode(_terms[i].term), _escape_bbcode(_terms[i].text)])
	if lines.is_empty():
		lines.append("[color=#%s]No similar entries or known terms.[/color]" % dim)
	_memory_view.text = "\n".join(lines)


## [param matched] with the words [param current] doesn't have struck out, then the words
## only [param current] has: what to change in the suggested translation.
func _diff(matched: String, current: String) -> String:
	var removed := _color(&"warning_color").to_html(false)
	var added := _color(&"success_color").to_html(false)
	var current_words := {}
	for word in current.split(" ", false):
		current_words[_bare_word(word)] = true
	var matched_words := {}
	var result := PackedStringArray()
	for word in _one_line(matched).split(" ", false):
		matched_words[_bare_word(word)] = true
		var escaped := _escape_bbcode(word)
		result.append(escaped if current_words.has(_bare_word(word)) else "[color=#%s][s]%s[/s][/color]" % [removed, escaped])
	for word in _one_line(current).split(" ", false):
		if not matched_words.has(_bare_word(word)):
			result.append("[color=#%s]+%s[/color]" % [added, _escape_bbcode(word)])
	return " ".join(result)


static func _bare_word(word: String) -> String:
	return word.strip_edges().to_lower().lstrip("\"'([¿¡").rstrip("\"').,!?:;…")


func _on_memory_clicked(meta: Variant) -> void:
	var link := String(meta)
	var index := link.substr(1).to_int()
	if link.begins_with("s"):
		_use_suggestion(index)
	elif link.begins_with("t") and index < _terms.size() and _entry:
		var edit := _current_form()
		if edit.editable:
			edit.insert_text_at_caret(_terms[index].text)
			edit.grab_focus()
			_on_form_changed(_form_edits.find(edit))


func _use_suggestion(index: int) -> void:
	if index < _suggestions.size() and _entry:
		_replace_text(_current_form(), _suggestions[index].text)


func _copy_source() -> void:
	if _entry == null:
		return
	var sources := _catalog.source_forms(_entry, _source)
	_replace_text(_current_form(), sources[mini(_forms.current_tab, sources.size() - 1)])


## Replaces the text as one undoable TextEdit operation, so Ctrl+Z in the editor brings it back.
func _replace_text(edit: TextEdit, text: String) -> void:
	if not edit.editable:
		return
	edit.begin_complex_operation()
	edit.select_all()
	if text.is_empty():
		edit.delete_selection()
	else:
		edit.insert_text_at_caret(text)
	edit.end_complex_operation()
	edit.grab_focus()
	_on_form_changed(_form_edits.find(edit))


func _current_form() -> TextEdit:
	return _form_edits[clampi(_forms.current_tab, 0, _form_edits.size() - 1)]


func _focus_editor() -> void:
	if _entry:
		_current_form().grab_focus()


func _done_and_next() -> void:
	if _entry == null:
		return
	_set_needs_work(false)
	_go(1, true)
	_focus_editor()


# --- Undoable changes --------------------------------------------------------------------

## What one undo step restores for an entry in the target language.
func _state(entry: Catalog.Entry) -> Dictionary:
	return {forms = _catalog.forms(entry, _target), needs_work = _catalog.is_needs_work(entry, _target)}


## Records the edits made to the current entry since it was shown as one undo step.
func _flush_edit() -> void:
	if _catalog == null or _entry == null or _edit_before.is_empty() or _target == -1:
		return
	var after := _state(_entry)
	if after == _edit_before:
		return
	_undo.create_action("Edit Translation")
	_undo.add_do_method(_apply_states.bind([[_entry, after]], _target))
	_undo.add_undo_method(_apply_states.bind([[_entry, _edit_before]], _target))
	_undo.commit_action(false)
	_edit_before = after
	_update_status()


func _set_needs_work(value: bool) -> void:
	if _entry == null or _target == -1:
		return
	_flush_edit()
	if _catalog.is_needs_work(_entry, _target) == value:
		_needs_work.set_pressed_no_signal(value)
		return
	var after := _edit_before.duplicate()
	after.needs_work = value
	_commit("Mark Needs Work" if value else "Clear Needs Work",
		_apply_states.bind([[_entry, after]], _target), _apply_states.bind([[_entry, _edit_before]], _target))


## [param changes]: [entry, state] pairs. Shows the entry when there's one, else refreshes the list.
func _apply_states(changes: Array, column: int) -> void:
	for change: Array in changes:
		_catalog.set_forms(change[0], column, change[1].forms)
		_catalog.set_needs_work(change[0], column, change[1].needs_work)
	if changes.size() == 1:
		_update_item(changes[0][0])
		_go_to(changes[0][0])
		_update_status()
	else:
		_rebuild_list()
		_go_to(_entry)


func _apply_insert(entry: Catalog.Entry, index: int) -> void:
	_catalog.insert_entry(entry, index)
	_rebuild_list()
	_go_to(entry)


func _apply_remove(entry: Catalog.Entry) -> void:
	var next := _neighbour(entry)
	_catalog.remove_entry(entry)
	_rebuild_list()
	_go_to(next)


func _apply_key(entry: Catalog.Entry, key: String, context: String) -> void:
	_catalog.set_key(entry, key, context)
	_rebuild_list()
	_go_to(entry)


func _apply_add_form(entry: Catalog.Entry) -> void:
	_catalog.add_form(entry)
	_update_item(entry)
	_go_to(entry)


func _apply_remove_form(entry: Catalog.Entry) -> void:
	_catalog.remove_form(entry)
	_update_item(entry)
	_go_to(entry)


func _apply_restore_form(entry: Catalog.Entry, row: PackedStringArray) -> void:
	_catalog.restore_form(entry, row)
	_update_item(entry)
	_go_to(entry)


func _apply_add_column(column_name: String) -> void:
	_target = _catalog.add_column(column_name)
	_columns_changed()


func _apply_remove_last_column() -> void:
	var removed := _catalog.columns.size() - 1
	_catalog.remove_last_column()
	if _source == removed:
		_source = Catalog.KEY_COLUMN
	if _target == removed:
		_pick_columns()
	_columns_changed()


func _commit(action: String, do_method: Callable, undo_method: Callable) -> void:
	_undo.create_action(action)
	_undo.add_do_method(do_method)
	_undo.add_undo_method(undo_method)
	_undo.commit_action()
	_update_status()


## The entry to show once [param entry] is gone: the next one in the list, else the previous.
func _neighbour(entry: Catalog.Entry) -> Catalog.Entry:
	var item: TreeItem = _items.get(entry)
	if item == null:
		return _entry if _entry != entry else null
	var other := item.get_next() if item.get_next() else item.get_prev()
	return other.get_metadata(0) if other else null


func _on_action(id: int) -> void:
	match id:
		Action.NEW, Action.OPEN:
			_file_dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE if id == Action.NEW else EditorFileDialog.FILE_MODE_OPEN_FILE
			_file_dialog.title = "New Translation File" if id == Action.NEW else "Open Translation File"
			_file_dialog.popup_file_dialog()
		Action.SAVE:
			_save()
		Action.RELOAD:
			if _catalog:
				_reload()
		Action.ADD_ENTRY:
			_ask_entry(false)
		Action.RENAME_ENTRY:
			_ask_entry(true)
		Action.DELETE_ENTRY:
			if _entry:
				_flush_edit()
				var entry := _entry
				_commit("Delete Entry", _apply_remove.bind(entry), _apply_insert.bind(entry, _catalog.entries.find(entry)))
		Action.ADD_FORM:
			if _entry and _catalog.is_plural(_entry):
				_flush_edit()
				_commit("Add Plural Form", _apply_add_form.bind(_entry), _apply_remove_form.bind(_entry))
		Action.REMOVE_FORM:
			if _entry and _catalog.form_count(_entry) > 2:
				_flush_edit()
				_commit("Remove Plural Form", _apply_remove_form.bind(_entry), _apply_restore_form.bind(_entry, _entry.rows[-1]))
		Action.ADD_LANGUAGE:
			_ask_language()
		Action.PRE_TRANSLATE:
			_pre_translate()
		Action.VALIDATE:
			_validate()
		Action.REGISTER:
			_register_translations()
		Action.UNDO:
			_undo_redo(true)
		Action.REDO:
			_undo_redo(false)
		Action.MOVE_UP, Action.MOVE_DOWN:
			_move(-1 if id == Action.MOVE_UP else 1)
		Action.TOGGLE_NEEDS_WORK:
			if _entry and _target != -1:
				_set_needs_work(not _catalog.is_needs_work(_entry, _target))
		Action.COPY_KEY:
			if _entry:
				DisplayServer.clipboard_set(_catalog.key(_entry))
				_say("Copied %s." % _catalog.key(_entry))


func _update_actions() -> void:
	var has_catalog := _catalog != null
	var has_entry := _entry != null and _target != -1
	for id in [Action.SAVE, Action.RELOAD, Action.ADD_ENTRY, Action.ADD_LANGUAGE, Action.REGISTER]:
		_actions.set_item_disabled(_actions.get_item_index(id), not has_catalog)
	for id in [Action.RENAME_ENTRY, Action.DELETE_ENTRY]:
		_actions.set_item_disabled(_actions.get_item_index(id), _entry == null)
	_actions.set_item_disabled(_actions.get_item_index(Action.ADD_FORM), not (has_entry and _catalog.is_plural(_entry)))
	_actions.set_item_disabled(_actions.get_item_index(Action.REMOVE_FORM), not (has_entry and _catalog.form_count(_entry) > 2))
	for id in [Action.PRE_TRANSLATE, Action.VALIDATE]:
		_actions.set_item_disabled(_actions.get_item_index(id), not has_catalog or _target == -1)
	_actions.set_item_disabled(_actions.get_item_index(Action.UNDO), not _undo.has_undo())
	_actions.set_item_disabled(_actions.get_item_index(Action.REDO), not _undo.has_redo())
	_actions.set_item_text(_actions.get_item_index(Action.UNDO),
		"Undo " + _undo.get_current_action_name() if _undo.has_undo() else "Undo")


func _undo_redo(undo: bool) -> void:
	_flush_edit()
	if undo and _undo.has_undo():
		var action := _undo.get_current_action_name()
		_undo.undo()
		_say("Undid %s." % action)
	elif not undo and _undo.has_redo():
		_undo.redo()
		_say("Redid %s." % _undo.get_current_action_name())
	_update_status()


## Fills untranslated entries with exact translation memory matches, flagged Needs Work.
func _pre_translate() -> void:
	if _catalog == null or _target == -1:
		return
	_flush_edit()
	var matches := _memory.exact_matches(_catalog, _source, _target)
	var after := []
	var before := []
	for entry in _catalog.messages():
		if _catalog.is_plural(entry) or _catalog.status(entry, _target) != Catalog.Status.UNTRANSLATED:
			continue
		var source := _catalog.source_forms(entry, _source)[0]
		if matches.has(source):
			before.append([entry, _state(entry)])
			after.append([entry, {forms = PackedStringArray([matches[source]]), needs_work = true}])
	if after.is_empty():
		_say("Translation memory has no exact matches for the untranslated entries.")
		return
	_commit("Pre-translate", _apply_states.bind(after, _target), _apply_states.bind(before, _target))
	_say("Pre-translated %d entr%s from translation memory; they're flagged Needs Work." % [
		after.size(), "y" if after.size() == 1 else "ies"])


func _validate() -> void:
	if _catalog == null or _target == -1:
		return
	_flush_edit()
	_show.select(Show.ISSUES)
	_rebuild_list()
	var count := _tree.get_root().get_child_count()
	if count == 0:
		_show.select(Show.ALL)
		_rebuild_list()
		_say("No issues found.")
	else:
		_go_to(_tree.get_root().get_child(0).get_metadata(0))
		_say("%d entr%s with issues." % [count, "y" if count == 1 else "ies"])


# --- Dialogs -----------------------------------------------------------------------------

func _ask_entry(renaming: bool) -> void:
	if _catalog == null or (renaming and _entry == null):
		return
	_flush_edit()
	_entry_renaming = renaming
	_entry_dialog.title = "Rename Entry" if renaming else "Add Entry"
	_entry_dialog.ok_button_text = "Rename" if renaming else "Add"
	_key_edit.text = _catalog.key(_entry) if renaming else ""
	_context_edit.text = _catalog.context(_entry) if renaming else ""
	_plural_edit.text = ""
	_source_text_edit.text = ""
	var has_context := _catalog.context_column != -1
	_context_label.visible = has_context
	_context_edit.visible = has_context
	var has_plural := not renaming and _catalog.plural_column != -1
	_plural_label.visible = has_plural
	_plural_edit.visible = has_plural
	var has_source := not renaming and _source != Catalog.KEY_COLUMN
	_source_text_label.visible = has_source
	_source_text_edit.visible = has_source
	_source_text_label.text = _language(_source)
	_validate_entry_dialog()
	_entry_dialog.reset_size()
	_entry_dialog.popup_centered(Vector2i(int(420 * EditorInterface.get_editor_scale()), 0))
	_key_edit.grab_focus()
	_key_edit.select_all()


func _validate_entry_dialog() -> void:
	var key := _key_edit.text
	var existing := _catalog.find_entry(Catalog.make_id(key, _context_edit.text))
	var error := ""
	if key.is_empty():
		error = "The key can't be empty."
	elif key.begins_with("?"):
		error = "Keys starting with \"?\" are reserved by Godot."
	elif existing and not (_entry_renaming and existing == _entry):
		error = "Another entry already uses this key."
	_entry_error.text = error
	_entry_dialog.get_ok_button().disabled = not error.is_empty()


func _on_entry_dialog_confirmed() -> void:
	var key := _key_edit.text
	var context := _context_edit.text if _catalog.context_column != -1 else ""
	if _entry_renaming:
		var entry := _entry
		_commit("Rename Entry", _apply_key.bind(entry, key, context),
			_apply_key.bind(entry, _catalog.key(entry), _catalog.context(entry)))
		return
	var entry := _catalog.create_entry(key, context, _plural_edit.text)
	if _source != Catalog.KEY_COLUMN:
		entry.set_cell(_source, _source_text_edit.text)
	if _group_column != -1 and _group_column != _catalog.context_column:
		# New entries join the section being worked on.
		var section: String = _section_value if _section_value != null else (_entry.cell(_group_column) if _entry else "")
		entry.set_cell(_group_column, section)
	var index := _catalog.entries.find(_entry) + 1 if _entry else _catalog.entries.size()
	_commit("Add Entry", _apply_insert.bind(entry, index), _apply_remove.bind(entry))
	_focus_editor.call_deferred()


func _ask_language() -> void:
	if _catalog == null:
		return
	_language_edit.text = ""
	_validate_language("")
	_language_dialog.popup_centered()
	_language_edit.grab_focus()


func _validate_language(text: String) -> void:
	var code := text.strip_edges()
	var locale := TranslationServer.standardize_locale(code)
	var valid := false
	if code.is_empty():
		_language_name.text = "Godot names translation columns after locales."
	elif not Catalog.is_locale_name(code):
		_language_name.text = "Not a locale code."
	elif _locale_column(code) != -1:
		_language_name.text = "%s is already in this file." % TranslationServer.get_locale_name(locale)
	else:
		_language_name.text = "%s (%s)" % [TranslationServer.get_locale_name(locale), locale]
		valid = true
	_language_dialog.get_ok_button().disabled = not valid


func _add_language(code: String) -> void:
	if _catalog == null or not Catalog.is_locale_name(code) or _locale_column(code) != -1:
		return
	_flush_edit()
	_commit("Add Language " + code, _apply_add_column.bind(code), _apply_remove_last_column)


## The generated .translation files of the open catalog that Project Settings doesn't list yet.
func _unregistered_translations() -> PackedStringArray:
	var result := PackedStringArray()
	if _catalog == null:
		return result
	var registered: PackedStringArray = ProjectSettings.get_setting(SETTING_TRANSLATIONS, PackedStringArray())
	for column in _catalog.locale_columns():
		if not Catalog.is_language(_catalog.header(column)):
			continue
		var locale := TranslationServer.standardize_locale(_catalog.header(column))
		var file := "%s.%s.translation" % [_catalog.path.get_basename(), locale]
		if not FileAccess.file_exists(file) or file in registered:
			continue
		var uid := ResourceLoader.get_resource_uid(file)
		if uid != ResourceUID.INVALID_ID and ResourceUID.id_to_text(uid) in registered:
			continue
		result.append(file)
	return result


## Columns Godot imports as locales whose language it doesn't know, like "section" or "comment".
func _not_languages() -> PackedInt32Array:
	var result := PackedInt32Array()
	if _catalog == null:
		return result
	for column in _catalog.locale_columns():
		if not Catalog.is_language(_catalog.header(column)):
			result.append(column)
	return result


func _ask_rename_column() -> void:
	var odd := _not_languages()
	if odd.is_empty():
		return
	var header := _catalog.header(odd[0])
	var base := _catalog.path.get_basename()
	_rename_column_dialog.dialog_text = ("Godot reads the “%s” column as a language and imports it into %s.%s.translation.\n\n"
		+ "Rename it to “_%s”? Godot ignores columns starting with “_”, and Stele shows them as notes beside each entry.\n"
		+ "After saving, you can delete the old .translation file and remove it from Project Settings → Localization.") % [
		header, base.get_file(), TranslationServer.standardize_locale(header), header]
	_rename_column_dialog.set_meta(&"column", odd[0])
	_rename_column_dialog.popup_centered()


func _rename_column() -> void:
	var column: int = _rename_column_dialog.get_meta(&"column")
	var header := _catalog.header(column)
	_flush_edit()
	_commit("Rename Column", _apply_rename_column.bind(column, "_" + header), _apply_rename_column.bind(column, header))


func _apply_rename_column(column: int, column_name: String) -> void:
	_catalog.rename_column(column, column_name)
	if _source not in _catalog.locale_columns() and _source != Catalog.KEY_COLUMN \
			or _target not in _catalog.locale_columns():
		_pick_columns()
	_columns_changed()


func _register_translations() -> void:
	var missing := _unregistered_translations()
	if missing.is_empty():
		_say("Every language of this file is in Project Settings → Localization (save to generate new ones).")
		return
	var registered: PackedStringArray = ProjectSettings.get_setting(SETTING_TRANSLATIONS, PackedStringArray())
	registered.append_array(missing)
	ProjectSettings.set_setting(SETTING_TRANSLATIONS, registered)
	ProjectSettings.save()
	_say("Added %s to Project Settings → Localization." % ", ".join(Array(missing).map(
		func(file: String) -> String: return file.get_file())))
	_update_status()


# --- Status and view ---------------------------------------------------------------------

func _update_status() -> void:
	if _catalog == null or _target == -1:
		_status.text = ""
		_progress.hide()
		_register.hide()
		_not_language.hide()
		return
	_fill_sections()
	var stats := _catalog.stats(_target)
	var with_issues := _issues.values().filter(func(issues: Array) -> bool: return not issues.is_empty()).size()
	var percent: float = 100.0 * stats.translated / stats.total if stats.total > 0 else 100.0
	var parts := PackedStringArray(["%sTranslated: %d of %d (%d%%)" % [
		"● " if _is_dirty() else "", stats.translated, stats.total, floori(percent)]])
	if stats.untranslated > 0:
		parts.append("Untranslated: %d" % stats.untranslated)
	if stats.needs_work > 0:
		parts.append("Needs work: %d" % stats.needs_work)
	if with_issues > 0:
		parts.append("Issues: %d" % with_issues)
	_status.text = "  ·  ".join(parts)
	_status.tooltip_text = "Unsaved changes" if _is_dirty() else ""
	_progress.value = percent
	_progress.show()
	var missing := _unregistered_translations().size()
	_register.text = "%d not in Localization" % missing
	_register.visible = missing > 0
	var odd := _not_languages()
	_not_language.visible = not odd.is_empty()
	if not odd.is_empty():
		_not_language.text = "“%s” isn't a language" % _catalog.header(odd[0])
		_not_language.tooltip_text = "Godot treats this column as a locale and generates a translation for it.\nClick to rename it to “_%s”, a notes column Godot ignores." % _catalog.header(odd[0])


func _update_view() -> void:
	var ready := _catalog != null and _target != -1
	_main.visible = ready
	_empty.visible = not ready
	if _catalog == null:
		_empty.text = "Pick a translation CSV above or use Catalog → Open…, or right-click a .csv in the FileSystem dock → Translate with Stele."
	elif _target == -1:
		_empty.text = "%s has no language columns yet. Add one with the + button or Catalog → Add Language…" % _catalog.path.get_file()
	_source_select.disabled = not ready
	_target_select.disabled = not ready
	_show.disabled = not ready
	_section_select.disabled = not ready
	_filter.editable = ready
	_update_status()


func _on_view(id: int) -> void:
	if id >= SECTIONS_FROM:
		_group_column = id - SECTIONS_FROM if id > SECTIONS_FROM else -1
		_section_value = null
		var settings := EditorInterface.get_editor_settings()
		var sections: Dictionary = settings.get_project_metadata(META_SECTION, "sections", {})
		sections[_catalog.path] = _catalog.header(_group_column)
		settings.set_project_metadata(META_SECTION, "sections", sections)
	elif id == UNFINISHED_FIRST:
		_unfinished_first = not _unfinished_first
	else:
		_order = id as Order
	_update_view_menu()
	_rebuild_list()


func _fill_view_menu() -> void:
	_view.clear()
	_view.add_radio_check_item("File Order", Order.FILE)
	_view.add_radio_check_item("By Source Text", Order.SOURCE)
	_view.add_radio_check_item("By Translation", Order.TRANSLATION)
	_view.add_separator()
	_view.add_check_item("Unfinished First", UNFINISHED_FIRST)
	_view.add_separator("Sections From")
	_view.add_radio_check_item("None", SECTIONS_FROM)
	if _catalog:
		for column in _group_candidates():
			_view.add_radio_check_item(_catalog.header(column), SECTIONS_FROM + column)
	_update_view_menu()


func _update_view_menu() -> void:
	for order: int in Order.values():
		_view.set_item_checked(_view.get_item_index(order), order == _order)
	_view.set_item_checked(_view.get_item_index(UNFINISHED_FIRST), _unfinished_first)
	for i in _view.item_count:
		var id := _view.get_item_id(i)
		if id >= SECTIONS_FROM:
			_view.set_item_checked(i, id == SECTIONS_FROM + maxi(_group_column, 0))


## Columns that can hold sections: the notes columns and "?context".
func _group_candidates() -> PackedInt32Array:
	var result := _catalog.note_columns()
	if _catalog.context_column != -1:
		result.append(_catalog.context_column)
	return result


## The section column chosen for this file, else a notes column named like one ("_section").
func _pick_group_column() -> int:
	var candidates := _group_candidates()
	var remembered: Variant = EditorInterface.get_editor_settings().get_project_metadata(
		META_SECTION, "sections", {}).get(_catalog.path)
	if remembered is String:
		if remembered.is_empty():
			return -1 # chose None
		var column := _catalog.column_index(remembered)
		if column in candidates:
			return column
	for column in candidates:
		if _catalog.header(column).trim_prefix("_").to_lower() in SECTION_COLUMNS:
			return column
	return -1


## Lists the sections in file order, with how many entries are left to translate in each.
func _fill_sections() -> void:
	_section_select.visible = _catalog != null and _group_column != -1
	if not _section_select.visible:
		_section_value = null
		return
	var counts := {} # section -> [entries, unfinished], in file order
	for entry in _catalog.messages():
		var count: Array = counts.get_or_add(entry.cell(_group_column), [0, 0])
		count[0] += 1
		if _target != -1 and _catalog.status(entry, _target) != Catalog.Status.TRANSLATED:
			count[1] += 1
	if _section_value != null and not counts.has(_section_value):
		_section_value = null
	_section_select.clear()
	_section_select.add_item("All Sections")
	_section_select.set_item_metadata(0, null)
	for section: String in counts:
		var left: int = counts[section][1]
		var index := _section_select.item_count
		_section_select.add_item("%s (%s)" % [section if section else "No section", "%d left" % left if left else "done"])
		_section_select.set_item_metadata(index, section)
		_section_select.set_item_tooltip(index, "%d entries, %d left to translate" % [counts[section][0], left])
		if section == _section_value:
			_section_select.select(index)
	if _section_value == null:
		_section_select.select(0)


func _on_section_selected(index: int) -> void:
	_section_value = _section_select.get_item_metadata(index)
	_select(_entry)
	_rebuild_list()
	var root := _tree.get_root()
	if not _items.has(_entry) and root.get_child_count() > 0:
		_go_to(root.get_child(0).get_metadata(0))


func _say(text: String) -> void:
	_message.text = text
	_message.tooltip_text = text


func _show_alert(text: String) -> void:
	_alert.dialog_text = text
	_alert.popup_centered()


# --- Shortcuts ---------------------------------------------------------------------------

## Poedit's shortcuts, active while focus is anywhere in the dock. They run before the
## focused control and the editor's own shortcuts see the key.
func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or _catalog == null or not is_visible_in_tree():
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus == null or not is_ancestor_of(focus) or _is_dialog_open():
		return
	if _shortcut(key, focus):
		get_viewport().set_input_as_handled()


func _is_dialog_open() -> bool:
	for dialog: Window in [_file_dialog, _entry_dialog, _language_dialog, _unsaved_dialog, _rename_column_dialog, _alert]:
		if dialog.visible:
			return true
	return false


func _shortcut(key: InputEventKey, focus: Control) -> bool:
	if focus == _tree and key.alt_pressed and not key.is_command_or_control_pressed() and not key.shift_pressed \
			and (key.keycode == KEY_UP or key.keycode == KEY_DOWN):
		_move(-1 if key.keycode == KEY_UP else 1)
		return true
	if not key.is_command_or_control_pressed() or key.alt_pressed:
		return false
	var shift := key.shift_pressed
	if key.keycode >= KEY_1 and key.keycode <= KEY_9 and not shift:
		_use_suggestion(key.keycode - KEY_1)
		return true
	match key.keycode:
		KEY_ENTER, KEY_KP_ENTER:
			_done_and_next()
		KEY_UP:
			_go(-1, shift)
		KEY_DOWN:
			_go(1, shift)
		KEY_B:
			_copy_source()
		KEY_U:
			if _entry:
				_set_needs_work(not _catalog.is_needs_work(_entry, _target))
		KEY_S:
			_save()
		KEY_F:
			_filter.grab_focus()
			_filter.select_all()
		KEY_Z, KEY_Y:
			if focus is TextEdit or focus is LineEdit:
				return false # their own undo
			_undo_redo(key.keycode == KEY_Z and not shift)
		_:
			return false
	return true


# --- Helpers -----------------------------------------------------------------------------

func _header(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.theme_type_variation = &"HeaderSmall"
	return label


func _text_edit() -> TextEdit:
	var edit := TextEdit.new()
	edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	edit.custom_minimum_size.y = 40 * EditorInterface.get_editor_scale()
	return edit


func _dialog_field(grid: GridContainer, label_text: String, placeholder: String) -> Dictionary:
	var label := Label.new()
	label.text = label_text
	grid.add_child(label)
	var edit := LineEdit.new()
	edit.placeholder_text = placeholder
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(edit)
	return {label = label, edit = edit}


func _tool_button(parent: Control, icon_name: String, tooltip: String, callback: Callable) -> Button:
	var button := Button.new()
	button.icon = _icon(icon_name)
	button.flat = true
	button.tooltip_text = tooltip
	button.pressed.connect(callback)
	parent.add_child(button)
	return button


static func _one_line(text: String) -> String:
	var line := text.replace("\r", "").replace("\n", " ⏎ ")
	return line.left(MAX_LIST_TEXT) + "…" if line.length() > MAX_LIST_TEXT else line


static func _escape_bbcode(text: String) -> String:
	return text.replace("[", "[lb]")


static func _mod() -> String:
	return "Cmd" if OS.get_name() == "macOS" else "Ctrl"


static func _color(color_name: StringName) -> Color:
	return EditorInterface.get_editor_theme().get_color(color_name, &"Editor")


static func _icon(icon_name: String) -> Texture2D:
	var theme := EditorInterface.get_editor_theme()
	return theme.get_icon(icon_name, &"EditorIcons") if theme.has_icon(icon_name, &"EditorIcons") else null
