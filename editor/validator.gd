@tool
extends RefCounted
## Poedit-style checks on a translation against its source text: placeholders, BBCode
## tags, line breaks, surrounding whitespace and ending punctuation.

enum Severity { WARNING, ERROR }

## Placeholders of String's % operator ("%s", "%05.2f", "%*d") and of String.format() ("{name}", "{0}").
const PLACEHOLDER_PATTERN := "%[-+0]*(?:\\d+|\\*)?(?:\\.(?:\\d+|\\*))?[scdoxXfv%]|\\{[A-Za-z0-9_]*\\}"
## BBCode tag names, with "/" for closing tags: "[color=red]" -> "color", "[/b]" -> "/b".
const TAG_PATTERN := "\\[(/?[A-Za-z_]+)(?:[= ][^\\]]*)?\\]"
## Ending punctuation that should carry over, grouped by meaning across scripts.
const ENDINGS: Array[String] = [".。．", "!！", "?？", ":：", "…", ",、，", ";；"]

static var _placeholder := RegEx.create_from_string(PLACEHOLDER_PATTERN)
static var _tag := RegEx.create_from_string(TAG_PATTERN)


## Returns [code]{severity, message}[/code] dictionaries; empty when the translation looks fine
## or is empty.
static func check(source: String, translation: String) -> Array[Dictionary]:
	var issues: Array[Dictionary] = []
	if translation.is_empty() or source.is_empty():
		return issues
	_compare(issues, Severity.ERROR, "Placeholders", _matches(_placeholder, source, 0), _matches(_placeholder, translation, 0))
	_compare(issues, Severity.WARNING, "BBCode tags", _matches(_tag, source, 1), _matches(_tag, translation, 1))

	var source_breaks := _line_breaks(source)
	var translation_breaks := _line_breaks(translation)
	if source_breaks != translation_breaks:
		issues.append(_issue(Severity.WARNING, "The source has %d line break%s, the translation %d." % [
			source_breaks, "" if source_breaks == 1 else "s", translation_breaks]))
	if _leading(source) != _leading(translation):
		issues.append(_issue(Severity.WARNING, "Leading whitespace differs from the source."))
	if _trailing(source) != _trailing(translation):
		issues.append(_issue(Severity.WARNING, "Trailing whitespace differs from the source."))

	var source_end := _ending(source)
	var group := _ending_group(source_end)
	var translation_end := _ending(translation)
	if not group.is_empty() and (translation_end.is_empty() or not group.contains(translation_end)):
		issues.append(_issue(Severity.WARNING, "The source ends with “%s” but the translation doesn't." % source_end))
	return issues


static func _compare(issues: Array[Dictionary], severity: Severity, what: String, expected: Array, actual: Array) -> void:
	var missing := _difference(expected, actual)
	var extra := _difference(actual, expected)
	if not missing.is_empty():
		issues.append(_issue(severity, "%s missing from the translation: %s" % [what, " ".join(missing)]))
	if not extra.is_empty():
		issues.append(_issue(severity, "%s not in the source: %s" % [what, " ".join(extra)]))


## Items of [param a] left after taking out one per item of [param b].
static func _difference(a: Array, b: Array) -> PackedStringArray:
	var left := b.duplicate()
	var result := PackedStringArray()
	for item: String in a:
		var index := left.find(item)
		if index == -1:
			result.append(item)
		else:
			left.remove_at(index)
	return result


static func _matches(regex: RegEx, text: String, group: int) -> Array:
	return regex.search_all(text).map(func(found: RegExMatch) -> String: return found.get_string(group))


## Real line breaks and "\n" escapes, which the importer unescapes.
static func _line_breaks(text: String) -> int:
	return text.count("\n") + text.count("\\n")


static func _leading(text: String) -> bool:
	return not text.is_empty() and text.lstrip(" \t") != text


static func _trailing(text: String) -> bool:
	return not text.is_empty() and text.rstrip(" \t") != text


static func _ending(text: String) -> String:
	var stripped := text.strip_edges(false, true)
	if stripped.ends_with("..."):
		return "…"
	return stripped.right(1)


static func _ending_group(character: String) -> String:
	if character.is_empty():
		return ""
	for group in ENDINGS:
		if group.contains(character):
			return group
	return ""


static func _issue(severity: Severity, message: String) -> Dictionary:
	return {severity = severity, message = message}
