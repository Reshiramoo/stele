@tool
extends EditorPlugin

const TranslationDock := preload("editor/translation_dock.gd")
const ContextMenu := preload("editor/context_menu.gd")

var _dock: TranslationDock
var _context_menu: ContextMenu
var _refresh_queued := false


func _enter_tree() -> void:
	_dock = TranslationDock.new()
	_dock.setup(self)
	add_dock(_dock)
	_context_menu = ContextMenu.new()
	_context_menu.open = _open
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_FILESYSTEM, _context_menu)

	EditorInterface.get_resource_filesystem().filesystem_changed.connect(_queue_refresh)
	ProjectSettings.settings_changed.connect(_queue_refresh)
	_dock.refresh_files()
	_dock.reopen_last()


func _exit_tree() -> void:
	ProjectSettings.settings_changed.disconnect(_queue_refresh)
	EditorInterface.get_resource_filesystem().filesystem_changed.disconnect(_queue_refresh)
	remove_context_menu_plugin(_context_menu)
	remove_dock(_dock)
	_dock.queue_free()


## Inspecting a .translation file generated from a CSV opens the CSV at that language.
func _handles(object: Object) -> bool:
	return object is Translation and not _source_csv(object).is_empty()


func _edit(object: Object) -> void:
	if object is Translation:
		_open(_source_csv(object), object.locale)


## Asked when the editor closes: unsaved translations get a chance to be saved.
func _get_unsaved_status(for_scene: String) -> String:
	if not for_scene.is_empty() or not _dock.is_dirty():
		return ""
	return "Save changes to %s in Stele before closing?" % _dock.get_file().get_file()


## Called when the editor saves everything, including before running the project.
func _save_external_data() -> void:
	_dock.save()


func _open(file: String, locale := "") -> void:
	_dock.make_visible()
	_dock.open_file(file, locale)


## The CSV that "strings.ja.translation" was imported from.
static func _source_csv(translation: Translation) -> String:
	var path := translation.resource_path
	if path.get_extension() != "translation":
		return ""
	var csv := path.get_basename().get_basename() + ".csv"
	return csv if FileAccess.file_exists(csv) else ""


## The filesystem often changes in bursts; rescan once per frame at most.
func _queue_refresh() -> void:
	if _refresh_queued:
		return
	_refresh_queued = true
	_refresh.call_deferred()


func _refresh() -> void:
	_refresh_queued = false
	_dock.refresh_files()
