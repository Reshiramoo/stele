@tool
extends RefCounted
## A Godot CSV translation file, read the way Godot's importer reads it: column 0 holds
## the keys, "_" columns are notes, "?context" and "?plural" columns add context and
## plurals, rows with an empty key after a plural entry are its extra plural forms, and
## "?pluralrule" rows override plural rules. Every row is written back as it was read
## unless it was edited, so columns and rows Stele doesn't show survive a save.
##
## CSV has no room for Poedit's "Needs Work" flag or translator comments, so those live
## in a JSON sidecar next to the file ("strings.csv" -> "strings.csv.stele").

enum Kind { MESSAGE, PLURAL_RULE, OTHER }
enum Status { UNTRANSLATED, NEEDS_WORK, TRANSLATED }

const KEY_COLUMN := 0
const SIDECAR_SUFFIX := ".stele"
const IMPORTER := "csv_translation"
## The importer's "delimiter" option: Comma, Semicolon, Tab.
const DELIMITERS: Array[String] = [",", ";", "\t"]
const BOM := [0xEF, 0xBB, 0xBF]


## One logical row of the file: a message (first row plus one row per extra plural
## form), a "?pluralrule" row, or a row Godot skips (empty key).
class Entry:
	extends RefCounted
	var kind := 0
	var rows: Array[PackedStringArray] = []

	func cell(column: int, form := 0) -> String:
		if form >= rows.size() or column < 0 or column >= rows[form].size():
			return ""
		return rows[form][column]

	func set_cell(column: int, text: String, form := 0) -> void:
		var row := rows[form]
		if column >= row.size():
			row.resize(column + 1)
		row[column] = text
		rows[form] = row


var path := ""
var delimiter := ","
var columns := PackedStringArray()
var entries: Array[Entry] = [] # in file order, including rows that aren't messages
var context_column := -1
var plural_column := -1
var modified_time := 0
var bom := false # spreadsheet apps write and need a UTF-8 byte order mark; keep it

var _needs_work := {} # column name -> {entry id: true}
var _comments := {} # column name -> {entry id: comment}


## Whether Godot imports [param file] as translations (and not as plain data).
static func is_translation_csv(file: String) -> bool:
	if file.get_extension().to_lower() != "csv":
		return false
	var config := ConfigFile.new()
	if config.load(file + ".import") != OK:
		return true # not imported yet: CSV files default to translations
	return config.get_value("remap", "importer", IMPORTER) == IMPORTER


## The delimiter set in [param file]'s import options.
static func import_delimiter(file: String) -> String:
	var config := ConfigFile.new()
	if config.load(file + ".import") != OK:
		return DELIMITERS[0]
	return DELIMITERS[clampi(int(config.get_value("params", "delimiter", 0)), 0, DELIMITERS.size() - 1)]


static func is_locale_name(column_name: String) -> bool:
	if column_name.begins_with("_") or column_name.begins_with("?"):
		return false
	return not TranslationServer.standardize_locale(column_name).is_empty()


func load_file(file: String, file_delimiter := ",") -> Error:
	var f := FileAccess.open(file, FileAccess.READ)
	if f == null:
		return FileAccess.get_open_error()
	path = file
	delimiter = file_delimiter
	bom = f.get_buffer(3) == PackedByteArray(BOM)
	f.seek(3 if bom else 0)
	entries.clear()
	columns = f.get_csv_line(delimiter)
	if columns.size() == 1 and columns[0].is_empty():
		columns = PackedStringArray(["keys"])
	_find_special_columns()

	var plural_owner: Entry = null
	while not f.eof_reached():
		var row := f.get_csv_line(delimiter)
		if row.size() == 1 and row[0].is_empty():
			continue # the importer skips empty lines; they're not written back
		var row_key := row[0]
		if row_key.to_lower() == "?pluralrule":
			entries.append(_make_entry(Kind.PLURAL_RULE, row))
			plural_owner = null
			continue
		var row_context := _cell(row, context_column)
		var row_plural := _cell(row, plural_column)
		if plural_owner and row_key.is_empty() and row_context.is_empty() and row_plural.is_empty():
			plural_owner.rows.append(row)
			continue
		var entry := _make_entry(Kind.OTHER if row_key.is_empty() else Kind.MESSAGE, row)
		entries.append(entry)
		plural_owner = entry if entry.kind == Kind.MESSAGE and not row_plural.is_empty() else null
	f.close()
	modified_time = FileAccess.get_modified_time(path)
	_load_sidecar()
	return OK


func save() -> Error:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	if bom:
		f.store_buffer(PackedByteArray(BOM))
	var ok := f.store_csv_line(columns, delimiter)
	for entry in entries:
		for row in entry.rows:
			ok = f.store_csv_line(row, delimiter) and ok
	f.close()
	if not ok:
		return ERR_FILE_CANT_WRITE
	modified_time = FileAccess.get_modified_time(path)
	return _save_sidecar()


## Messages in file order: the entries a translator works on.
func messages() -> Array[Entry]:
	return entries.filter(func(entry: Entry) -> bool: return entry.kind == Kind.MESSAGE)


func header(column: int) -> String:
	return columns[column] if column >= 0 and column < columns.size() else ""


func column_index(column_name: String) -> int:
	return Array(columns).find(column_name)


## Columns Godot turns into translations.
func locale_columns() -> PackedInt32Array:
	var result := PackedInt32Array()
	for i in range(1, columns.size()):
		if i != context_column and i != plural_column and is_locale_name(columns[i]):
			result.append(i)
	return result


## "_" columns, which Godot ignores: notes for translators.
func note_columns() -> PackedInt32Array:
	var result := PackedInt32Array()
	for i in range(1, columns.size()):
		if columns[i].begins_with("_"):
			result.append(i)
	return result


func key(entry: Entry) -> String:
	return entry.cell(KEY_COLUMN)


func context(entry: Entry) -> String:
	return entry.cell(context_column)


## Identifies a message the way gettext does: context, EOT, key.
func id(entry: Entry) -> String:
	return make_id(key(entry), context(entry))


func is_plural(entry: Entry) -> bool:
	return not entry.cell(plural_column).is_empty()


func form_count(entry: Entry) -> int:
	return entry.rows.size() if is_plural(entry) else 1


## The text of [param entry] in [param column], one string per plural form.
func forms(entry: Entry, column: int) -> PackedStringArray:
	var result := PackedStringArray()
	for form in form_count(entry):
		result.append(entry.cell(column, form))
	return result


func set_forms(entry: Entry, column: int, texts: PackedStringArray) -> void:
	for form in mini(texts.size(), form_count(entry)):
		entry.set_cell(column, texts[form], form)


## What the translator translates from. With the key column as the source, a plural
## entry's plural form comes from the "?plural" column.
func source_forms(entry: Entry, column: int) -> PackedStringArray:
	if column != KEY_COLUMN:
		return forms(entry, column)
	var result := PackedStringArray([key(entry)])
	if is_plural(entry):
		var plural := entry.cell(plural_column)
		for form in range(1, form_count(entry)):
			result.append(plural)
	return result


func status(entry: Entry, column: int) -> Status:
	for text in forms(entry, column):
		if text.is_empty():
			return Status.UNTRANSLATED
	return Status.NEEDS_WORK if is_needs_work(entry, column) else Status.TRANSLATED


## Counts for the status bar: total, translated, needs_work, untranslated.
func stats(column: int) -> Dictionary:
	var result := {total = 0, translated = 0, needs_work = 0, untranslated = 0}
	for entry in messages():
		result.total += 1
		match status(entry, column):
			Status.TRANSLATED: result.translated += 1
			Status.NEEDS_WORK: result.needs_work += 1
			_: result.untranslated += 1
	return result


func is_needs_work(entry: Entry, column: int) -> bool:
	return _needs_work.get(header(column), {}).has(id(entry))


func set_needs_work(entry: Entry, column: int, value: bool) -> void:
	var flags: Dictionary = _needs_work.get_or_add(header(column), {})
	if value:
		flags[id(entry)] = true
	else:
		flags.erase(id(entry))


func comment(entry: Entry, column: int) -> String:
	return _comments.get(header(column), {}).get(id(entry), "")


func set_comment(entry: Entry, column: int, text: String) -> void:
	var comments: Dictionary = _comments.get_or_add(header(column), {})
	if text.is_empty():
		comments.erase(id(entry))
	else:
		comments[id(entry)] = text


## A new message, full width, not yet in the catalog. [param plural] needs a "?plural" column.
func create_entry(entry_key: String, entry_context := "", plural := "") -> Entry:
	var row := PackedStringArray()
	row.resize(columns.size())
	row[KEY_COLUMN] = entry_key
	var entry := _make_entry(Kind.MESSAGE, row)
	if context_column >= 0:
		entry.set_cell(context_column, entry_context)
	if plural_column >= 0 and not plural.is_empty():
		entry.set_cell(plural_column, plural)
		add_form(entry)
	return entry


func insert_entry(entry: Entry, index: int) -> void:
	entries.insert(clampi(index, 0, entries.size()), entry)


## Removes [param entry] and returns where it was, for [method insert_entry].
func remove_entry(entry: Entry) -> int:
	var index := entries.find(entry)
	if index >= 0:
		entries.remove_at(index)
	return index


func find_entry(entry_id: String) -> Entry:
	for entry in entries:
		if entry.kind == Kind.MESSAGE and id(entry) == entry_id:
			return entry
	return null


## Ids used by more than one message: Godot keeps only the last one.
func duplicate_ids() -> Dictionary:
	var seen := {}
	var duplicates := {}
	for entry in messages():
		var entry_id := id(entry)
		if seen.has(entry_id):
			duplicates[entry_id] = true
		seen[entry_id] = true
	return duplicates


## Renames a message, carrying its Needs Work flags and comments over.
func set_key(entry: Entry, entry_key: String, entry_context: String) -> void:
	var old_id := id(entry)
	var new_id := make_id(entry_key, entry_context)
	entry.set_cell(KEY_COLUMN, entry_key)
	if context_column >= 0:
		entry.set_cell(context_column, entry_context)
	if old_id == new_id:
		return
	for store: Dictionary in [_needs_work, _comments]:
		for column_values: Dictionary in store.values():
			if column_values.has(old_id):
				column_values[new_id] = column_values[old_id]
				column_values.erase(old_id)


## Adds an extra plural form row to [param entry].
func add_form(entry: Entry) -> void:
	var row := PackedStringArray()
	row.resize(entry.rows[0].size())
	entry.rows.append(row)


## Removes the last plural form row and returns it, for [method restore_form].
func remove_form(entry: Entry) -> PackedStringArray:
	if entry.rows.size() <= 1:
		return PackedStringArray()
	return entry.rows.pop_back()


func restore_form(entry: Entry, row: PackedStringArray) -> void:
	entry.rows.append(row)


## Appends a column (a new language, say) and returns its index.
func add_column(column_name: String) -> int:
	columns.append(column_name)
	_find_special_columns()
	return columns.size() - 1


## Removes the last column; only used to undo [method add_column].
func remove_last_column() -> void:
	var column := columns.size() - 1
	columns.remove_at(column)
	for entry in entries:
		for form in entry.rows.size():
			if entry.rows[form].size() > column:
				var row := entry.rows[form]
				row.resize(column)
				entry.rows[form] = row
	_find_special_columns()


func sidecar_path() -> String:
	return path + SIDECAR_SUFFIX


func _find_special_columns() -> void:
	# Only the first of each counts, as in the importer.
	context_column = -1
	plural_column = -1
	for i in range(1, columns.size()):
		var lower := columns[i].to_lower()
		if lower == "?context" and context_column == -1:
			context_column = i
		elif lower == "?plural" and plural_column == -1:
			plural_column = i


func _load_sidecar() -> void:
	_needs_work = {}
	_comments = {}
	if not FileAccess.file_exists(sidecar_path()):
		return
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(sidecar_path()))
	if not data is Dictionary:
		push_warning("Stele: ignoring unreadable %s" % sidecar_path())
		return
	for column_name: String in data.get("needs_work", {}):
		var flags := {}
		for entry_id: String in data.needs_work[column_name]:
			flags[entry_id] = true
		_needs_work[column_name] = flags
	for column_name: String in data.get("comments", {}):
		_comments[column_name] = Dictionary(data.comments[column_name]).duplicate()


## Writes flags and comments for messages and columns that still exist; removes the
## sidecar once there's nothing left to keep.
func _save_sidecar() -> Error:
	var ids := {}
	for entry in messages():
		ids[id(entry)] = true
	var needs_work := {}
	for column_name: String in _needs_work:
		if column_index(column_name) == -1:
			continue
		var kept: Array = _needs_work[column_name].keys().filter(func(entry_id: String) -> bool: return ids.has(entry_id))
		if not kept.is_empty():
			kept.sort()
			needs_work[column_name] = kept
	var comments := {}
	for column_name: String in _comments:
		if column_index(column_name) == -1:
			continue
		var kept := {}
		for entry_id: String in _comments[column_name]:
			if ids.has(entry_id):
				kept[entry_id] = _comments[column_name][entry_id]
		if not kept.is_empty():
			comments[column_name] = kept

	if needs_work.is_empty() and comments.is_empty():
		if FileAccess.file_exists(sidecar_path()):
			return DirAccess.remove_absolute(sidecar_path())
		return OK
	var data := {}
	if not needs_work.is_empty():
		data.needs_work = needs_work
	if not comments.is_empty():
		data.comments = comments
	var f := FileAccess.open(sidecar_path(), FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(data, "\t", true) + "\n")
	return OK


func _make_entry(kind: Kind, row: PackedStringArray) -> Entry:
	var entry := Entry.new()
	entry.kind = kind
	entry.rows.append(row)
	return entry


static func make_id(entry_key: String, entry_context: String) -> String:
	return entry_key if entry_context.is_empty() else entry_context + "\u0004" + entry_key


static func _cell(row: PackedStringArray, column: int) -> String:
	return row[column] if column >= 0 and column < row.size() else ""
