import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/database/note_dao.dart';
import '../../../data/embedding/similarity_engine.dart';
import '../../../core/background/background_worker.dart';
import '../../search/presentation/semantic_search_bar.dart';

class QuickNoteScreen extends StatefulWidget {
  const QuickNoteScreen({super.key});

  @override
  State<QuickNoteScreen> createState() => _QuickNoteScreenState();
}

class _QuickNoteScreenState extends State<QuickNoteScreen> {
  final NoteDao _noteDao = NoteDao();
  List<Map<String, dynamic>> _allNotes = [];
  List<Map<String, dynamic>> _allConnections = [];
  String _searchQuery = '';
  String? _selectedEntityFilter;

  @override
  void initState() {
    super.initState();
    _refreshNotes();
  }

  Future<void> _refreshNotes() async {
    final notes = await _noteDao.getAllNotes();
    final connections = await _noteDao.getAllConnections();
    if (mounted) {
      setState(() {
        _allNotes = notes;
        _allConnections = connections;
      });
    }
  }

  /// Apre un editor completo stile Obsidian per scrivere o modificare documenti lunghi
  Future<void> _openDocumentEditor({Map<String, dynamic>? existingNote}) async {
    HapticFeedback.mediumImpact();
    final isEditing = existingNote != null;
    final controller = TextEditingController(
      text: isEditing ? (existingNote['content'] as String) : '',
    );
    final String? noteId = isEditing ? (existingNote['id'] as String) : null;

    // Trova le note collegate a questo documento (Backlinks stile Obsidian)
    final connectedNotes = <Map<String, dynamic>>[];
    if (isEditing) {
      for (final conn in _allConnections) {
        String? linkedId;
        if (conn['source_id'] == noteId) linkedId = conn['target_id'] as String;
        if (conn['target_id'] == noteId) linkedId = conn['source_id'] as String;
        if (linkedId != null) {
          final match = _allNotes.where((n) => n['id'] == linkedId);
          if (match.isNotEmpty && !connectedNotes.any((e) => e['id'] == linkedId)) {
            connectedNotes.add({...match.first, '_sim': conn['similarity_score']});
          }
        }
      }
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (ctx) {
          return StatefulBuilder(
            builder: (context, setModalState) {
              final liveEntities = SimilarityEngine.extractEntities(controller.text);

              return Scaffold(
                backgroundColor: AppColors.background,
                appBar: AppBar(
                  backgroundColor: AppColors.background,
                  elevation: 0,
                  leading: IconButton(
                    icon: const Icon(Icons.arrow_back_ios_new_rounded, color: AppColors.textPrimary),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                  title: Text(
                    isEditing ? 'Documento' : 'Nuovo Documento',
                    style: const TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  actions: [
                    if (isEditing)
                      IconButton(
                        icon: const Icon(Icons.delete_outline_rounded, color: AppColors.accentCoral),
                        onPressed: () async {
                          HapticFeedback.heavyImpact();
                          await _noteDao.deleteNote(noteId!);
                          if (ctx.mounted) Navigator.pop(ctx);
                          await _refreshNotes();
                        },
                      ),
                    Padding(
                      padding: const EdgeInsets.only(right: 12.0),
                      child: TextButton.icon(
                        onPressed: () async {
                          final text = controller.text.trim();
                          if (text.isEmpty) return;
                          HapticFeedback.mediumImpact();
                          if (isEditing) {
                            await _noteDao.updateNote(noteId!, text);
                          } else {
                            await _noteDao.insertQuickNote(text);
                          }
                          // Indicizza subito per rendere attivi i link e la ricerca naturale
                          await BackgroundWorker.processPendingNotes();
                          if (ctx.mounted) Navigator.pop(ctx);
                          await _refreshNotes();
                        },
                        style: TextButton.styleFrom(
                          backgroundColor: AppColors.accentCoralDark,
                          foregroundColor: AppColors.accentCoral,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                        ),
                        icon: const Icon(Icons.check_rounded, size: 18),
                        label: const Text('Salva'),
                      ),
                    ),
                  ],
                ),
                body: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 8.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Soggetti / Entità estratti dal testo in tempo reale
                      if (liveEntities.isNotEmpty) ...[
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              const Icon(Icons.person_pin_circle_outlined, size: 16, color: AppColors.statusGreen),
                              const SizedBox(width: 6),
                              ...liveEntities.map(
                                (e) => Container(
                                  margin: const EdgeInsets.only(right: 6),
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: AppColors.statusGreenBg,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    '#$e',
                                    style: const TextStyle(color: AppColors.statusGreen, fontSize: 12, fontWeight: FontWeight.w600),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],

                      // Area di testo libera per documenti lunghi, liste o appunti strutturati
                      Expanded(
                        child: TextField(
                          controller: controller,
                          autofocus: !isEditing,
                          maxLines: null,
                          expands: true,
                          onChanged: (_) => setModalState(() {}),
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 15,
                            height: 1.5,
                          ),
                          decoration: const InputDecoration(
                            hintText: 'Scrivi liberamente una nota lunga, una lista o pensieri su persone e progetti...\n\nI soggetti e i collegamenti vengono riconosciuti in automatico.',
                            hintStyle: TextStyle(color: AppColors.textSecondary, fontSize: 14),
                            border: InputBorder.none,
                          ),
                        ),
                      ),

                      // Backlinks stile Obsidian (Note collegate automaticamente)
                      if (connectedNotes.isNotEmpty) ...[
                        const Divider(color: AppColors.cardSurfaceLight),
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 6.0),
                          child: Text(
                            'CONCETTI E MEMORIE COLLEGATE',
                            style: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.8,
                            ),
                          ),
                        ),
                        SizedBox(
                          height: 75,
                          child: ListView.builder(
                            scrollDirection: Axis.horizontal,
                            itemCount: connectedNotes.length,
                            itemBuilder: (context, idx) {
                              final linked = connectedNotes[idx];
                              return GestureDetector(
                                onTap: () {
                                  Navigator.pop(ctx);
                                  _openDocumentEditor(existingNote: linked);
                                },
                                child: Container(
                                  width: 200,
                                  margin: const EdgeInsets.only(right: 10),
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: AppColors.cardSurface,
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(color: AppColors.statusGreen.withOpacity(0.4)),
                                  ),
                                  child: Text(
                                    linked['content'] as String,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(color: AppColors.textPrimary, fontSize: 12),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pendingCount = _allNotes.where((n) => n['status'] == 'PENDING').length;
    final indexedCount = _allNotes.where((n) => n['status'] == 'INDEXED').length;

    // Raccoglie tutti i soggetti/persone ricorrenti nel tuo secondo cervello
    final entityCounts = <String, int>{};
    for (final n in _allNotes) {
      for (final ent in SimilarityEngine.extractEntities(n['content'] as String)) {
        entityCounts[ent] = (entityCounts[ent] ?? 0) + 1;
      }
    }
    final topEntities = entityCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    // Interrogazione in linguaggio naturale
    List<Map<String, dynamic>> displayedNotes = [];
    for (final n in _allNotes) {
      final content = n['content'] as String;

      // Filtro per Soggetto/Persona cliccato
      if (_selectedEntityFilter != null) {
        final ents = SimilarityEngine.extractEntities(content);
        if (!ents.any((e) => e.toLowerCase() == _selectedEntityFilter!.toLowerCase())) {
          continue;
        }
      }

      if (_searchQuery.trim().isEmpty) {
        displayedNotes.add(n);
      } else {
        final res = SimilarityEngine.queryDocument(
          _searchQuery,
          content,
          n['vector_json'] as String?,
        );
        final double score = res['score'] as double;
        if (score >= 0.15) {
          displayedNotes.add({
            ...n,
            '_score': score,
            '_snippet': res['snippet'],
          });
        }
      }
    }

    if (_searchQuery.trim().isNotEmpty) {
      displayedNotes.sort((a, b) => (b['_score'] as double).compareTo(a['_score'] as double));
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openDocumentEditor(),
        backgroundColor: AppColors.accentCoralDark,
        foregroundColor: AppColors.accentCoral,
        elevation: 2,
        icon: const Icon(Icons.note_add_outlined),
        label: const Text('Nuova Pagina', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Banner Stato Coda + Forza Sync
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.statusGreenBg,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.bolt, color: AppColors.statusGreen, size: 18),
                      const SizedBox(width: 8),
                      Text(
                        'In coda: $pendingCount • Collegamenti: ${_allConnections.length}',
                        style: const TextStyle(
                          color: AppColors.statusGreen,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                  GestureDetector(
                    onTap: () async {
                      HapticFeedback.mediumImpact();
                      await BackgroundWorker.processPendingNotes();
                      await _refreshNotes();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                      decoration: BoxDecoration(
                        color: AppColors.statusGreen.withOpacity(0.25),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(
                        'Sync ($indexedCount)',
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),

            // Barra di ricerca a linguaggio naturale
            SemanticSearchBar(
              onSearchChanged: (val) => setState(() => _searchQuery = val),
            ),

            // Barra dei Soggetti / Persone riconosciute automaticamente
            if (topEntities.isNotEmpty) ...[
              const SizedBox(height: 10),
              SizedBox(
                height: 32,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: topEntities.length,
                  itemBuilder: (context, idx) {
                    final ent = topEntities[idx].key;
                    final count = topEntities[idx].value;
                    final isSelected = _selectedEntityFilter == ent;
                    return GestureDetector(
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() {
                          _selectedEntityFilter = isSelected ? null : ent;
                        });
                      },
                      child: Container(
                        margin: const EdgeInsets.only(right: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: isSelected ? AppColors.accentCoralDark : AppColors.cardSurface,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: isSelected ? AppColors.accentCoral : AppColors.cardSurfaceLight,
                          ),
                        ),
                        child: Text(
                          '$ent ($count)',
                          style: TextStyle(
                            color: isSelected ? AppColors.accentCoral : AppColors.textSecondary,
                            fontSize: 12,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
            const SizedBox(height: 12),

            // Lista Documenti (Swipe sia a destra che a sinistra per eliminare)
            Expanded(
              child: displayedNotes.isEmpty
                  ? Center(
                      child: Text(
                        _searchQuery.isEmpty
                            ? 'Il tuo archivio è vuoto.\nTocca "Nuova Pagina" per iniziare.'
                            : 'Nessuna risposta trovata per questa domanda.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 80),
                      itemCount: displayedNotes.length,
                      itemBuilder: (context, index) {
                        final note = displayedNotes[index];
                        final String noteId = note['id'] as String;
                        final String content = note['content'] as String;
                        final double? matchScore = note['_score'] as double?;
                        final String? snippet = note['_snippet'] as String?;
                        final entities = SimilarityEngine.extractEntities(content);

                        // Conta quanti link ha questa nota
                        final linkCount = _allConnections.where(
                          (c) => c['source_id'] == noteId || c['target_id'] == noteId,
                        ).length;

                        return Dismissible(
                          key: ValueKey(noteId),
                          direction: DismissDirection.horizontal, // Swipe da entrambi i lati!
                          onDismissed: (_) async {
                            HapticFeedback.heavyImpact();
                            await _noteDao.deleteNote(noteId);
                            await _refreshNotes();
                          },
                          background: Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            alignment: Alignment.centerLeft,
                            decoration: BoxDecoration(
                              color: AppColors.accentCoralDark,
                              borderRadius: BorderRadius.circular(22),
                            ),
                            child: const Icon(Icons.delete_sweep_outlined, color: AppColors.accentCoral),
                          ),
                          secondaryBackground: Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            alignment: Alignment.centerRight,
                            decoration: BoxDecoration(
                              color: AppColors.accentCoralDark,
                              borderRadius: BorderRadius.circular(22),
                            ),
                            child: const Icon(Icons.delete_sweep_outlined, color: AppColors.accentCoral),
                          ),
                          child: GestureDetector(
                            onTap: () => _openDocumentEditor(existingNote: note),
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 12),
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: AppColors.cardSurface,
                                borderRadius: BorderRadius.circular(22),
                                border: Border.all(
                                  color: snippet != null
                                      ? AppColors.accentCoral.withOpacity(0.5)
                                      : Colors.transparent,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Risposta estratta in evidenza quando fai una domanda
                                  if (snippet != null && _searchQuery.isNotEmpty) ...[
                                    Container(
                                      width: double.infinity,
                                      margin: const EdgeInsets.only(bottom: 10),
                                      padding: const EdgeInsets.all(10),
                                      decoration: BoxDecoration(
                                        color: AppColors.accentCoralDark.withOpacity(0.45),
                                        borderRadius: BorderRadius.circular(14),
                                      ),
                                      child: Row(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          const Icon(Icons.auto_awesome, color: AppColors.accentCoral, size: 16),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              snippet,
                                              style: const TextStyle(
                                                color: AppColors.accentCoral,
                                                fontWeight: FontWeight.w600,
                                                fontSize: 13,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],

                                  // Anteprima del documento (anche se molto lungo)
                                  Text(
                                    content,
                                    maxLines: 4,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: AppColors.textPrimary,
                                      fontSize: 14,
                                      height: 1.4,
                                    ),
                                  ),
                                  const SizedBox(height: 10),

                                  // Footer card: Soggetti estratti + Numero di collegamenti
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Expanded(
                                        child: Wrap(
                                          spacing: 6,
                                          runSpacing: 4,
                                          children: entities.take(3).map((e) {
                                            return Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                              decoration: BoxDecoration(
                                                color: AppColors.cardSurfaceLight,
                                                borderRadius: BorderRadius.circular(8),
                                              ),
                                              child: Text(
                                                '#$e',
                                                style: const TextStyle(
                                                  color: AppColors.textSecondary,
                                                  fontSize: 11,
                                                ),
                                              ),
                                            );
                                          }).toList(),
                                        ),
                                      ),
                                      Row(
                                        children: [
                                          if (linkCount > 0) ...[
                                            const Icon(Icons.hub_outlined, size: 14, color: AppColors.statusGreen),
                                            const SizedBox(width: 4),
                                            Text(
                                              '$linkCount link',
                                              style: const TextStyle(color: AppColors.statusGreen, fontSize: 11),
                                            ),
                                          ],
                                          if (matchScore != null && _searchQuery.isNotEmpty) ...[
                                            const SizedBox(width: 8),
                                            Text(
                                              '${(matchScore * 100).clamp(1, 99).toInt()}%',
                                              style: const TextStyle(
                                                color: AppColors.accentCoral,
                                                fontSize: 11,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}