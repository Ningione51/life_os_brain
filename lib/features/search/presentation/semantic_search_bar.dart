import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/theme/app_colors.dart';

class SemanticSearchBar extends StatefulWidget {
  final ValueChanged<String> onSearchChanged;

  const SemanticSearchBar({super.key, required this.onSearchChanged});

  @override
  State<SemanticSearchBar> createState() => _SemanticSearchBarState();
}

class _SemanticSearchBarState extends State<SemanticSearchBar> {
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.cardSurface,
        borderRadius: BorderRadius.circular(24),
      ),
      child: TextField(
        controller: _searchController,
        onChanged: (val) {
          setState(() {});
          widget.onSearchChanged(val);
        },
        style: const TextStyle(color: AppColors.textPrimary, fontSize: 14),
        decoration: InputDecoration(
          icon: const Icon(Icons.psychology_outlined, color: AppColors.accentCoral, size: 22),
          hintText: 'Fai una domanda (es. "Cosa piace a Manu?")',
          hintStyle: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
          border: InputBorder.none,
          suffixIcon: _searchController.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.close, color: AppColors.textSecondary, size: 18),
                  onPressed: () {
                    HapticFeedback.selectionClick();
                    _searchController.clear();
                    setState(() {});
                    widget.onSearchChanged('');
                  },
                )
              : null,
        ),
      ),
    );
  }
}