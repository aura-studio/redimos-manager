import 'package:flutter/material.dart';

/// Shared accent palette for the v1.2 restyle (matches the design mockups).
/// Deliberately theme-neutral hues that read on both light and dark surfaces.
class Accents {
  static const teal = Color(0xFF17B6A6); // endpoints · brand · JS active · LOCAL
  static const indigo = Color(0xFF6366F1); // primary action · selection · Run
  static const amber = Color(0xFFD9982E); // instances · AWS badge · degraded backend
  // Success/affordance green: the start icon and the playground's success chip
  // and done footer. NOT process status — that goes through goGreen(), which is
  // brightness-adaptive (greenAccent reads on dark, too pale on light) where
  // this is a fixed hue.
  static const green = Color(0xFF3FBF6B);
}
