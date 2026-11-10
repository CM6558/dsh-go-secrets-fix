// Table headers set in bold, the way GitHub and the chat apps show them.
// gpt_markdown hands the header style to its cells as an inherited default,
// which the reply's explicit body weight overrides, so the header cells are
// marked up as bold before parsing instead.

/// [source] with the header cells of every pipe table wrapped in `**…**`.
///
/// Code fences are skipped; a cell that is empty or already carries
/// emphasis markers is left as written.
String boldTableHeaders(String source) {
  if (!source.contains('|') || !source.contains('-')) return source;
  final lines = source.split('\n');
  String? fence;
  var changed = false;
  for (var i = 0; i + 1 < lines.length; i++) {
    final line = lines[i];
    final marker = _fence.firstMatch(line)?.group(1);
    if (fence != null) {
      final close = _fenceClose.firstMatch(line)?.group(1);
      if (close != null && close[0] == fence[0] && close.length >= fence.length) fence = null;
      continue;
    }
    if (marker != null) {
      fence = marker;
      continue;
    }
    if (!line.contains('|') || !_isDelimiterRow(lines[i + 1], _cellsOf(_unquoted(line)).length)) continue;
    final bolded = _boldRow(line);
    if (bolded != line) {
      lines[i] = bolded;
      changed = true;
    }
    i += 1;
  }
  return changed ? lines.join('\n') : source;
}

final _fence = RegExp(r'^[ \t]*(?:>[ \t]?)*[ \t]*(`{3,}|~{3,})');
final _fenceClose = RegExp(r'^[ \t]*(?:>[ \t]?)*[ \t]*(`{3,}|~{3,})[ \t]*$');
final _delimiterCell = RegExp(r'^\s*:?-+:?\s*$');
final _pipe = RegExp(r'(?<!\\)\|');

String _unquoted(String line) => line.trim().replaceFirst(RegExp(r'^(?:>[ \t]?)*'), '').trim();

/// A GFM delimiter row with as many cells as the header (`a | b` over `---`
/// is a heading, not a table).
bool _isDelimiterRow(String line, int headerCells) {
  final t = _unquoted(line);
  if (!t.contains('-')) return false;
  final cells = _cellsOf(t);
  return cells.length == headerCells && cells.every(_delimiterCell.hasMatch);
}

List<String> _cellsOf(String row) {
  var t = row;
  if (t.startsWith('|')) t = t.substring(1);
  if (t.endsWith('|') && !t.endsWith(r'\|')) t = t.substring(0, t.length - 1);
  return t.split(_pipe);
}

/// The header row with each cell's text in `**…**`, keeping the row's quote
/// prefix, its pipes and the spaces around each cell.
String _boldRow(String line) {
  final prefix = RegExp(r'^[ \t]*(?:>[ \t]?)*').firstMatch(line)!.group(0)!;
  final body = line.substring(prefix.length);
  final parts = body.split(_pipe);
  for (var i = 0; i < parts.length; i++) {
    final cell = parts[i];
    final text = cell.trim();
    // The empty parts outside the leading / trailing pipe, and cells that
    // already have emphasis, stay as they are.
    if (text.isEmpty || text.contains('*') || text.contains('_')) continue;
    final start = cell.indexOf(text);
    parts[i] = '${cell.substring(0, start)}**$text**${cell.substring(start + text.length)}';
  }
  return prefix + parts.join('|');
}
