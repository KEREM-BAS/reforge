/// Produces a unified diff between two versions of a file.
///
/// [before] is `null` for a created file and [after] is `null` for a deleted
/// file. Lines are compared including their terminators, so line-ending and
/// trailing-newline changes are visible in the output.
String unifiedDiff({
  required String path,
  required String? before,
  required String? after,
  int context = 3,
}) {
  final oldLines = _splitLines(before ?? '');
  final newLines = _splitLines(after ?? '');
  final ops = _diff(oldLines, newLines);
  if (ops.every((op) => op.kind == _OpKind.equal)) {
    return '';
  }

  final buffer = StringBuffer()
    ..writeln(before == null ? '--- /dev/null' : '--- a/$path')
    ..writeln(after == null ? '+++ /dev/null' : '+++ b/$path');

  for (final hunk in _hunks(ops, context)) {
    buffer.writeln('@@ -${_range(hunk.oldStart, hunk.oldCount)} '
        '+${_range(hunk.newStart, hunk.newCount)} @@');
    for (final op in hunk.ops) {
      final prefix = switch (op.kind) {
        _OpKind.equal => ' ',
        _OpKind.delete => '-',
        _OpKind.insert => '+',
      };
      final line = op.line;
      if (line.endsWith('\n')) {
        buffer
          ..write(prefix)
          ..write(line.substring(0, line.length - 1))
          ..write('\n');
      } else {
        buffer
          ..write(prefix)
          ..write(line)
          ..write('\n')
          ..write(r'\ No newline at end of file')
          ..write('\n');
      }
    }
  }
  return buffer.toString();
}

/// Counts added and removed lines between two file versions.
({int added, int removed}) diffStat(String? before, String? after) {
  var added = 0;
  var removed = 0;
  for (final op in _diff(_splitLines(before ?? ''), _splitLines(after ?? ''))) {
    if (op.kind == _OpKind.insert) added++;
    if (op.kind == _OpKind.delete) removed++;
  }
  return (added: added, removed: removed);
}

String _range(int start, int count) {
  if (count == 1) return '$start';
  return '$start,$count';
}

List<String> _splitLines(String content) {
  final lines = <String>[];
  var start = 0;
  for (var i = 0; i < content.length; i++) {
    if (content.codeUnitAt(i) == 0x0A) {
      lines.add(content.substring(start, i + 1));
      start = i + 1;
    }
  }
  if (start < content.length) {
    lines.add(content.substring(start));
  }
  return lines;
}

enum _OpKind { equal, delete, insert }

final class _Op {
  const _Op(this.kind, this.line, this.oldIndex, this.newIndex);

  final _OpKind kind;
  final String line;

  /// 0-based index in the old file (for equal/delete), or the old position
  /// before which an insertion happens.
  final int oldIndex;

  /// 0-based index in the new file (for equal/insert), or the new position
  /// before which a deletion happens.
  final int newIndex;
}

/// Myers' O((N+M)D) difference algorithm.
List<_Op> _diff(List<String> a, List<String> b) {
  final n = a.length;
  final m = b.length;
  final max = n + m;
  if (max == 0) return const [];

  final offset = max;
  var v = List<int>.filled(2 * max + 2, 0);
  final trace = <List<int>>[];

  outer:
  for (var d = 0; d <= max; d++) {
    trace.add(List<int>.of(v));
    for (var k = -d; k <= d; k += 2) {
      int x;
      if (k == -d || (k != d && v[k - 1 + offset] < v[k + 1 + offset])) {
        x = v[k + 1 + offset];
      } else {
        x = v[k - 1 + offset] + 1;
      }
      var y = x - k;
      while (x < n && y < m && a[x] == b[y]) {
        x++;
        y++;
      }
      v[k + offset] = x;
      if (x >= n && y >= m) {
        break outer;
      }
    }
  }

  final ops = <_Op>[];
  var x = n;
  var y = m;
  for (var d = trace.length - 1; d >= 0; d--) {
    v = trace[d];
    final k = x - y;
    final int prevK;
    if (k == -d || (k != d && v[k - 1 + offset] < v[k + 1 + offset])) {
      prevK = k + 1;
    } else {
      prevK = k - 1;
    }
    final prevX = d == 0 ? 0 : v[prevK + offset];
    final prevY = d == 0 ? 0 : prevX - prevK;
    while (x > prevX && y > prevY) {
      ops.add(_Op(_OpKind.equal, a[x - 1], x - 1, y - 1));
      x--;
      y--;
    }
    if (d > 0) {
      if (x == prevX) {
        ops.add(_Op(_OpKind.insert, b[y - 1], x, y - 1));
        y--;
      } else {
        ops.add(_Op(_OpKind.delete, a[x - 1], x - 1, y));
        x--;
      }
    }
  }
  return ops.reversed.toList();
}

final class _Hunk {
  _Hunk(this.ops);

  final List<_Op> ops;

  int get oldCount => ops.where((op) => op.kind != _OpKind.insert).length;
  int get newCount => ops.where((op) => op.kind != _OpKind.delete).length;

  int get oldStart {
    final first = ops.first;
    final count = oldCount;
    final index = first.oldIndex;
    return count == 0 ? index : index + 1;
  }

  int get newStart {
    final first = ops.first;
    final count = newCount;
    final index = first.newIndex;
    return count == 0 ? index : index + 1;
  }
}

List<_Hunk> _hunks(List<_Op> ops, int context) {
  final hunks = <_Hunk>[];
  var i = 0;
  while (i < ops.length) {
    // Find the next change.
    while (i < ops.length && ops[i].kind == _OpKind.equal) {
      i++;
    }
    if (i >= ops.length) break;

    final start = (i - context) < 0 ? 0 : i - context;
    var end = i;
    // Extend while changes are separated by at most 2 * context equal lines.
    while (true) {
      while (end < ops.length && ops[end].kind != _OpKind.equal) {
        end++;
      }
      var equalRun = 0;
      var probe = end;
      while (probe < ops.length && ops[probe].kind == _OpKind.equal) {
        equalRun++;
        probe++;
      }
      if (probe < ops.length && equalRun <= 2 * context) {
        end = probe;
        continue;
      }
      end = (end + context) > ops.length ? ops.length : end + context;
      break;
    }
    hunks.add(_Hunk(ops.sublist(start, end)));
    i = end;
  }
  return hunks;
}
