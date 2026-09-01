import 'package:flutter/material.dart';

/// A user-defined parent grouping for spend categories (e.g. Needs, Wants,
/// Leisure). Which categories belong to a group is not stored here — the
/// provider keeps a categoryId → groupId assignment map, so built-in (const)
/// categories can be grouped with the same mechanism as custom ones.
class CategoryGroup {
  final String id;
  final String label;
  final Color color;

  const CategoryGroup({
    required this.id,
    required this.label,
    required this.color,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'color': color.toARGB32(),
  };

  factory CategoryGroup.fromJson(Map<String, dynamic> json) => CategoryGroup(
    id: json['id'] as String,
    label: json['label'] as String,
    color: Color(json['color'] as int),
  );
}
