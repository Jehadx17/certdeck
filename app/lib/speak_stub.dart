import 'package:flutter/material.dart';

/// Phones: no speaker (word pronunciation is web only for now).
void play(String? url, String word) {}

Widget button(String label, void Function() onTap) => IconButton(tooltip: label, icon: const Icon(Icons.volume_up), onPressed: onTap);

bool online() => true;
