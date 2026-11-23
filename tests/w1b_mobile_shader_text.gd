extends RefCounted
## Shared by the baseline recorder and the Mobile shader source test.

const DIRECTORY := "res://scripts/visual/shaders/"
const FIXTURE := "res://tests/fixtures/w1b_mobile_shader_text.json"

enum Branch { OTHER, COMPATIBILITY, MOBILE_ELSE }


static func normalize(source: String) -> String:
	var condition := RegEx.create_from_string("^#\\s*if\\s+CURRENT_RENDERER\\s*==\\s*RENDERER_COMPATIBILITY$")
	var directive := RegEx.create_from_string("^#\\s*(if|ifdef|ifndef|else|endif)\\b")
	var default_hook := RegEx.create_from_string("(?m)^\\s*#ifndef (W1B_\\w+)[ \\t]*\\r?\\n([ \\t]*#define \\1\\((\\w+)\\) \\(\\3\\)[ \\t]*)\\r?\\n[ \\t]*#endif[ \\t]*$")
	var identity := RegEx.create_from_string("^#define W1B_\\w+\\((\\w+)\\) \\(\\1\\)$")
	var lines := PackedStringArray()
	var branches: Array[Branch] = []
	var excluded := 0
	for line: String in source.split("\n"):
		var stripped := line.strip_edges()
		var token := directive.search(stripped)
		if token:
			match token.get_string(1):
				"if", "ifdef", "ifndef":
					if condition.search(stripped):
						branches.append(Branch.COMPATIBILITY)
						excluded += 1
						continue
					branches.append(Branch.OTHER)
				"else":
					if not branches.is_empty() and branches.back() == Branch.COMPATIBILITY:
						branches[-1] = Branch.MOBILE_ELSE
						excluded -= 1
						continue
				"endif":
					if not branches.is_empty():
						var branch: Branch = branches.pop_back()
						if branch == Branch.COMPATIBILITY:
							excluded -= 1
						if branch != Branch.OTHER:
							continue
		if excluded == 0:
			lines.append(stripped)

	var result := default_hook.sub("\n".join(lines), "", true)
	lines.clear()
	for line: String in result.split("\n"):
		if not identity.search(line):
			lines.append(line)
	var whitespace := RegEx.create_from_string("\\s+")
	return whitespace.sub(_unwrap_calls("\n".join(lines)), " ", true).strip_edges()


static func _unwrap_calls(source: String) -> String:
	var pattern := RegEx.create_from_string("\\b(?:W1A_LIN|W1A_OUT|W1B_\\w+)\\s*\\(")
	var start := 0
	var found := pattern.search(source)
	while found:
		var cursor := found.get_end()
		var depth := 1
		while cursor < source.length() and depth > 0:
			match source[cursor]:
				"(":
					depth += 1
				")":
					depth -= 1
			cursor += 1
		start = found.get_start()
		var line_start := source.left(start).rfind("\n") + 1
		if depth == 0 and not source.substr(line_start, start - line_start).strip_edges().begins_with("#"):
			var arg_start := found.get_end()
			source = source.left(start) + source.substr(arg_start, cursor - arg_start - 1) + source.substr(cursor)
		else:
			start = found.get_end()
		found = pattern.search(source, start)
	return source


static func snapshot() -> Dictionary:
	var texts := {}
	for file: String in DirAccess.get_files_at(DIRECTORY):
		if file.ends_with(".gdshader") or file.ends_with(".gdshaderinc"):
			texts[file] = normalize(FileAccess.get_file_as_string(DIRECTORY + file))
	return texts
