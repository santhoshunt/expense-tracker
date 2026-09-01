/// What an [ImportRule] does when its pattern matches an SMS body.
enum ImportRuleKind {
  /// The message is not a transaction — never imported.
  ignore,

  /// The message imports, but flagged for individual review (suspected spam).
  spamSignal,
}

/// User-editable import criterion: a case-insensitive substring checked
/// against every scanned SMS body. Defaults are seeded from
/// `kDefaultIgnorePhrases` / `kDefaultSpamSignals` (ids prefixed `builtin_`)
/// and are just as editable and deletable as user-created rules.
class ImportRule {
  final String id;
  final String pattern;
  final ImportRuleKind kind;

  const ImportRule({
    required this.id,
    required this.pattern,
    required this.kind,
  });

  /// Seeded from the built-in defaults rather than created by the user.
  bool get isBuiltIn => id.startsWith('builtin_');

  bool matches(String text) =>
      pattern.isNotEmpty && text.toLowerCase().contains(pattern.toLowerCase());

  ImportRule copyWith({String? pattern, ImportRuleKind? kind}) => ImportRule(
    id: id,
    pattern: pattern ?? this.pattern,
    kind: kind ?? this.kind,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'pattern': pattern,
    'kind': kind.name,
  };

  factory ImportRule.fromJson(Map<String, dynamic> json) => ImportRule(
    id: json['id'] as String,
    pattern: json['pattern'] as String,
    kind: ImportRuleKind.values.byName(json['kind'] as String),
  );
}
