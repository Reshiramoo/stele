@tool
extends EditorContextMenuPlugin
## "Translate with Stele" on translation CSVs in the FileSystem dock.

const Catalog := preload("catalog.gd")

var open: Callable # (file: String)


func _popup_menu(paths: PackedStringArray) -> void:
	for path in paths:
		if Catalog.is_translation_csv(path):
			var theme := EditorInterface.get_editor_theme()
			add_context_menu_item("Translate with Stele", func(_selected: Array) -> void: open.call(path),
				theme.get_icon(&"Translation", &"EditorIcons"))
			return
