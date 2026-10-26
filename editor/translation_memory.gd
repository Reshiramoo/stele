@tool
extends RefCounted
## Translation memory: the finished translations of the open catalog and of every other
## translation CSV in the project, looked up by source text. Close matches become
## suggestions, like Poedit's sidebar; exact ones drive Pre-translate. Short entries found
## inside a source text ("Frog" in "Frog skin unlocked!") are offered as terms.

const Catalog := preload("catalog.gd")

const MIN_SCORE := 0.75
const MAX_SUGGESTIONS := 5
const MAX_TERMS := 8
const MAX_TERM_WORDS := 4
const TRAILING_PUNCTUATION := ".!?:;,…。！？：；、，"

static var _tags := RegEx.create_from_string("\\[/?[A-Za-z_]+(?:[= ][^\\]]*)?\\]")

var _files := PackedStringArray()
var _cache := {} # path -> Catalog, reloaded when the file changes on disk


## The project's translation CSVs to learn from.
func set_files(files: PackedStringArray) -> void:
	_files = files
	for cached: String in _cache.keys():
		if cached not in files:
			_cache.erase(cached)


## Up to [constant MAX_SUGGESTIONS] [code]{text, score, source, origin}[/code] dictionaries,
## best first, for translating [param text] from [param source_column] to
## [param target_column] of [param current]. Other files are matched by locale.
func suggest(current: Catalog, source_column: int, target_column: int, text: String,
		exclude: Catalog.Entry = null) -> Array[Dictionary]:
	var best := {} # translation -> suggestion
	if text.strip_edges().is_empty():
		return []
	for pair in _pairs(current, source_column, target_column, exclude):
		var source: String = pair.source
		var score := 1.0
		if source != text:
			var ratio := float(mini(source.length(), text.length())) / maxi(source.length(), text.length())
			if ratio < MIN_SCORE * 0.5:
				continue
			score = text.similarity(source)
			if score < MIN_SCORE:
				continue
		var known: Dictionary = best.get(pair.translation, {})
		if known.is_empty() or score > known.score:
			best[pair.translation] = {text = pair.translation, score = score, source = source, origin = pair.origin}
	var result: Array[Dictionary] = []
	result.assign(best.values())
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.score > b.score)
	return result.slice(0, MAX_SUGGESTIONS)


## Short finished entries whose source appears as whole words inside [param text]:
## [code]{term, text, origin}[/code] dictionaries, longest term first. BBCode and ending
## punctuation are left out of both sides, so the translation fits into a sentence.
func terms(current: Catalog, source_column: int, target_column: int, text: String,
		exclude: Catalog.Entry = null) -> Array[Dictionary]:
	var haystack := _plain(text).to_lower()
	var found := {} # lowercase term -> term
	for pair in _pairs(current, source_column, target_column, exclude):
		var term := _plain(pair.source)
		var lower := term.to_lower()
		if term.length() < 2 or term.length() >= haystack.length() or found.has(lower) \
				or term.split(" ", false).size() > MAX_TERM_WORDS or not _contains_words(haystack, lower):
			continue
		var translation := _plain(pair.translation)
		if not translation.is_empty():
			found[lower] = {term = term, text = translation, origin = pair.origin}
	var result: Array[Dictionary] = []
	result.assign(found.values())
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.term.length() > b.term.length())
	return result.slice(0, MAX_TERMS)


## Source text -> translation for every exact match available, the open catalog first.
func exact_matches(current: Catalog, source_column: int, target_column: int) -> Dictionary:
	var result := {}
	for pair in _pairs(current, source_column, target_column, null):
		if not result.has(pair.source):
			result[pair.source] = pair.translation
	return result


func _pairs(current: Catalog, source_column: int, target_column: int, exclude: Catalog.Entry) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var target_locale := TranslationServer.standardize_locale(current.header(target_column))
	var source_locale := "" if source_column == Catalog.KEY_COLUMN \
		else TranslationServer.standardize_locale(current.header(source_column))
	_collect(result, current, source_column, target_column, exclude)
	for file in _files:
		if file == current.path:
			continue
		var catalog := _load(file)
		if catalog == null:
			continue
		var target := _locale_column(catalog, target_locale)
		var source := Catalog.KEY_COLUMN if source_locale.is_empty() else _locale_column(catalog, source_locale)
		if target != -1 and source != -1:
			_collect(result, catalog, source, target, null)
	return result


func _collect(result: Array[Dictionary], catalog: Catalog, source_column: int, target_column: int,
		exclude: Catalog.Entry) -> void:
	var origin := catalog.path.get_file()
	for entry in catalog.messages():
		if entry == exclude or catalog.is_plural(entry) \
				or catalog.status(entry, target_column) != Catalog.Status.TRANSLATED:
			continue
		var source := catalog.source_forms(entry, source_column)[0]
		if not source.is_empty():
			result.append({source = source, translation = entry.cell(target_column), origin = origin})


func _load(file: String) -> Catalog:
	var cached: Catalog = _cache.get(file)
	if cached and cached.modified_time == FileAccess.get_modified_time(file):
		return cached
	var catalog := Catalog.new()
	if catalog.load_file(file, Catalog.import_delimiter(file)) != OK:
		_cache.erase(file)
		return null
	_cache[file] = catalog
	return catalog


## [param text] without BBCode tags, surrounding whitespace or ending punctuation.
static func _plain(text: String) -> String:
	return _tags.sub(text, "", true).strip_edges().rstrip(TRAILING_PUNCTUATION).strip_edges()


## Whether [param needle] occurs in [param haystack] with no letters or digits glued to it.
static func _contains_words(haystack: String, needle: String) -> bool:
	var from := 0
	while true:
		var at := haystack.find(needle, from)
		if at == -1:
			return false
		var end := at + needle.length()
		if (at == 0 or not _is_word_character(haystack[at - 1])) \
				and (end == haystack.length() or not _is_word_character(haystack[end])):
			return true
		from = at + 1
	return false


## Letters with case, digits and "_". Scripts without spaces between words (CJK) never glue.
static func _is_word_character(character: String) -> bool:
	return character.to_upper() != character.to_lower() or character.is_valid_int() or character == "_"


static func _locale_column(catalog: Catalog, locale: String) -> int:
	for column in catalog.locale_columns():
		if TranslationServer.standardize_locale(catalog.header(column)) == locale:
			return column
	return -1
