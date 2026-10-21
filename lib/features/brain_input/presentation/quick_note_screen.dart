import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_speed_dial/flutter_speed_dial.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';

import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/database/note_dao.dart';
import '../../../data/embedding/similarity_engine.dart';
import '../../../core/background/background_worker.dart';
import '../../search/presentation/semantic_search_bar.dart';

enum NoteType { all, text, image, audio }

class QuickNoteScreen extends StatefulWidget {
  const QuickNoteScreen({super.key});

  @override
  State<QuickNoteScreen> createState() => _QuickNoteScreenState();
}

class _QuickNoteScreenState extends State<QuickNoteScreen> {
  final NoteDao _noteDao = NoteDao();
  final stt.SpeechToText _speech = stt.SpeechToText();
  String _lastLiveTranscription = '';
  List<Map<String, dynamic>> _allNotes = [];
  List<Map<String, dynamic>> _allConnections = [];
  String _searchQuery = '';
  String? _selectedEntityFilter;
  NoteType _selectedTypeFilter = NoteType.all;

  final AudioRecorder _audioRecorder = AudioRecorder();
  final AudioPlayer _audioPlayer = AudioPlayer();

  bool _isRecording = false;
  String? _currentlyPlayingPath;
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    _refreshNotes();
    _audioPlayer.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _isPlaying = false;
          _currentlyPlayingPath = null;
        });
      }
    });
  }

  @override
  void dispose() {
    _audioRecorder.dispose();
    _audioPlayer.dispose();
    super.dispose();
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

  NoteType _getNoteType(String content) {
    if (content.contains('[Nota Vocale Registrata]')) {
      return NoteType.audio;
    } else if (content.contains('[Scansione Immagine') ||
        content.contains('[IMG_PATH:')) {
      return NoteType.image;
    }
    return NoteType.text;
  }

  Map<String, dynamic> _parseNoteDetails(String content) {
    String? imagePath;
    String? audioPath;

    final imgMatch = RegExp(r'\[IMG_PATH:(.*?)\]').firstMatch(content);
    if (imgMatch != null) imagePath = imgMatch.group(1);

    final audioMatch = RegExp(r'\[AUDIO_PATH:(.*?)\]').firstMatch(content);
    if (audioMatch != null) audioPath = audioMatch.group(1);

    String cleanContent = content
        .replaceAll(RegExp(r'\[IMG_PATH:.*?\]'), '')
        .replaceAll(RegExp(r'\[AUDIO_PATH:.*?\]'), '')
        .replaceAll('[Nota Vocale Registrata]', '')
        .replaceAll('[Scansione Immagine / Coordinate]', '')
        .replaceAll('[Nota con Immagine allegata]', '')
        .trim();

    if (cleanContent.isEmpty) {
      cleanContent = 'Nessun testo allegato';
    }

    final lines = cleanContent.split('\n');
    final title = lines.first.trim();
    final body = lines.length > 1 ? lines.sublist(1).join('\n').trim() : '';

    return {
      'title': title,
      'body': body,
      'imagePath': imagePath,
      'audioPath': audioPath,
    };
  }

  Future<void> _handleImageCapture(ImageSource source) async {
    try {
      final picker = ImagePicker();
      final pickedFile = await picker.pickImage(
        source: source,
        imageQuality: 85,
      );
      if (pickedFile == null) return;

      if (!mounted) return;
      HapticFeedback.mediumImpact();

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Analisi visiva locale ed OCR in corso...'),
        ),
      );

      // Salvataggio sicuro dell'immagine nei documenti locali dell'app
      final appDir = await getApplicationDocumentsDirectory();
      final fileName = 'img_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final savedImage = await File(pickedFile.path)
          .copy('${appDir.path}/$fileName');

      final inputImage = InputImage.fromFilePath(savedImage.path);

      // 1. OCR Locale (Lettura Testo)
      final textRecognizer = TextRecognizer(
        script: TextRecognitionScript.latin,
      );
      final RecognizedText recognizedText = await textRecognizer.processImage(
        inputImage,
      );
      await textRecognizer.close();

      // 2. Vision AI Locale (Riconoscimento Oggetti/Scena on-device)
      final ImageLabelerOptions options = ImageLabelerOptions(
        confidenceThreshold: 0.6,
      );
      final imageLabeler = ImageLabeler(options: options);
      final List<ImageLabel> labels = await imageLabeler.processImage(
        inputImage,
      );
      await imageLabeler.close();

      final extractedText = recognizedText.text.trim();
      final detectedObjects = labels.map((l) => l.label).join(', ');

      String content = '[IMG_PATH:${savedImage.path}]\n';
      if (detectedObjects.isNotEmpty) {
        content += '[Vision AI]: $detectedObjects\n';
      }
      if (extractedText.isNotEmpty) {
        content += '[Testo Rilevato]:\n$extractedText';
      } else if (detectedObjects.isEmpty) {
        content += '[Nota con Immagine allegata]';
      }

      await _noteDao.insertQuickNote(content);
      await BackgroundWorker.processPendingNotes();
      await _refreshNotes();

      if (!mounted) return;
      ScaffoldMessenger.of(context).clearSnackBars();
    } catch (e) {
      debugPrint('Errore Vision/OCR locale: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Errore durante l\'analisi: $e')));
    }
  }

  void _showAudioRecorderSheet() {
  _lastLiveTranscription = '';
  showModalBottomSheet(
    context: context,
    isDismissible: false,
    backgroundColor: AppColors.cardSurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (ctx) {
      return StatefulBuilder(
        builder: (context, setStateModal) {
          return Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Registrazione e Trascrizione Vocale',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 16),
                Icon(
                  _isRecording ? Icons.mic_rounded : Icons.mic_none_rounded,
                  color: _isRecording ? AppColors.accentCoral : AppColors.textSecondary,
                  size: 48,
                ),
                if (_lastLiveTranscription.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    _lastLiveTranscription,
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    style: const TextStyle(
                      color: AppColors.accentCoral,
                      fontSize: 13,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (!_isRecording)
                      ElevatedButton.icon(
                        onPressed: () async {
                          bool available = await _speech.initialize();
                          if (await _audioRecorder.hasPermission()) {
                            final dir = await getApplicationDocumentsDirectory();
                            final path = '${dir.path}/audio_${DateTime.now().millisecondsSinceEpoch}.m4a';
                            await _audioRecorder.start(
                              const RecordConfig(
                                encoder: AudioEncoder.aacLc,
                                bitRate: 32000,
                                numChannels: 1,
                              ),
                              path: path,
                            );

                            if (available) {
                              _speech.listen(
                                onResult: (result) {
                                  setStateModal(() {
                                    _lastLiveTranscription = result.recognizedWords;
                                  });
                                },
                              );
                            }

                            setStateModal(() => _isRecording = true);
                            HapticFeedback.mediumImpact();
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.statusGreenBg,
                        ),
                        icon: const Icon(Icons.play_arrow, color: AppColors.statusGreen),
                        label: const Text('Avvia', style: TextStyle(color: AppColors.statusGreen)),
                      )
                    else
                      ElevatedButton.icon(
                        onPressed: () async {
                          final path = await _audioRecorder.stop();
                          await _speech.stop();
                          setStateModal(() => _isRecording = false);
                          HapticFeedback.heavyImpact();
                          if (path != null) {
                            final textContent = _lastLiveTranscription.trim().isNotEmpty
                                ? _lastLiveTranscription.trim()
                                : 'Nota Vocale Registrata';
                            await _noteDao.insertQuickNote(
                              '[AUDIO_PATH:$path]\n[Nota Vocale]\n$textContent',
                            );
                            await _refreshNotes();
                          }
                          if (ctx.mounted) Navigator.pop(ctx);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.accentCoralDark,
                        ),
                        icon: const Icon(Icons.stop, color: AppColors.accentCoral),
                        label: const Text('Salva', style: TextStyle(color: AppColors.accentCoral)),
                      ),
                  ],
                ),
              ],
            ),
          );
        },
      );
    },
  );
}
  Future<void> _toggleAudioPlayback(String audioPath) async {
    if (_isPlaying && _currentlyPlayingPath == audioPath) {
      await _audioPlayer.pause();
      setState(() => _isPlaying = false);
    } else {
      await _audioPlayer.stop();
      await _audioPlayer.play(DeviceFileSource(audioPath));
      setState(() {
        _currentlyPlayingPath = audioPath;
        _isPlaying = true;
      });
    }
  }

  /// ELIMINAZIONE NOTA CON OPZIONE "ANNULLA"
  Future<void> _deleteNoteWithUndo(Map<String, dynamic> note) async {
    final String noteId = note['id'] as String;

    setState(() {
      _allNotes.removeWhere((n) => n['id'] == noteId);
    });

    HapticFeedback.mediumImpact();
    bool undone = false;

    final snackBar = SnackBar(
      content: const Text(
        'Nota eliminata',
        style: TextStyle(color: AppColors.textPrimary),
      ),
      backgroundColor: AppColors.cardSurface,
      behavior: SnackBarBehavior.floating,
      // Il margine inferiore alza la notifica facendola fluttuare sopra la pillola di navigazione
      margin: const EdgeInsets.only(bottom: 85, left: 16, right: 16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.cardSurfaceLight),
      ),
      duration: const Duration(seconds: 4),
      action: SnackBarAction(
        label: 'ANNULLA',
        textColor: AppColors.accentCoral,
        onPressed: () {
          undone = true;
          _refreshNotes();
        },
      ),
    );

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(snackBar);

    await Future.delayed(const Duration(seconds: 4));
    if (!undone) {
      await _noteDao.deleteNote(noteId);
    }
  }

  Future<void> _openDocumentEditor({Map<String, dynamic>? existingNote}) async {
    HapticFeedback.mediumImpact();
    final isEditing = existingNote != null;
    final controller = TextEditingController(
      text: isEditing ? (existingNote['content'] as String) : '',
    );
    final String? noteId = isEditing ? (existingNote['id'] as String) : null;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (ctx) {
          return StatefulBuilder(
            builder: (context, setModalState) {
              final liveEntities = SimilarityEngine.extractEntities(
                controller.text,
              );

              return Scaffold(
                backgroundColor: AppColors.background,
                appBar: AppBar(
                  backgroundColor: AppColors.background,
                  elevation: 0,
                  leading: IconButton(
                    icon: const Icon(
                      Icons.arrow_back_ios_new_rounded,
                      color: AppColors.textPrimary,
                    ),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                  title: Text(
                    isEditing ? 'Modifica Nota' : 'Nuova Nota',
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  actions: [
                    if (isEditing)
                      IconButton(
                        icon: const Icon(
                          Icons.delete_outline_rounded,
                          color: AppColors.accentCoral,
                        ),
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
                          await BackgroundWorker.processPendingNotes();
                          if (ctx.mounted) Navigator.pop(ctx);
                          await _refreshNotes();
                        },
                        style: TextButton.styleFrom(
                          backgroundColor: AppColors.accentCoralDark,
                          foregroundColor: AppColors.accentCoral,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                        ),
                        icon: const Icon(Icons.check_rounded, size: 18),
                        label: const Text('Salva'),
                      ),
                    ),
                  ],
                ),
                body: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20.0,
                    vertical: 8.0,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (liveEntities.isNotEmpty) ...[
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              const Icon(
                                Icons.person_pin_circle_outlined,
                                size: 16,
                                color: AppColors.statusGreen,
                              ),
                              const SizedBox(width: 6),
                              ...liveEntities.map(
                                (e) => Container(
                                  margin: const EdgeInsets.only(right: 6),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.statusGreenBg,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    '#$e',
                                    style: const TextStyle(
                                      color: AppColors.statusGreen,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
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
                            hintText: 'Scrivi appunti, idee o coordinate...',
                            hintStyle: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 14,
                            ),
                            border: InputBorder.none,
                          ),
                        ),
                      ),
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
    final pendingCount = _allNotes
        .where((n) => n['status'] == 'PENDING')
        .length;
    final indexedCount = _allNotes
        .where((n) => n['status'] == 'INDEXED')
        .length;

    final entityCounts = <String, int>{};
    for (final n in _allNotes) {
      for (final ent in SimilarityEngine.extractEntities(
        n['content'] as String,
      )) {
        entityCounts[ent] = (entityCounts[ent] ?? 0) + 1;
      }
    }
    final topEntities = entityCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    List<Map<String, dynamic>> displayedNotes = [];
    for (final n in _allNotes) {
      final content = n['content'] as String;
      final type = _getNoteType(content);

      if (_selectedTypeFilter != NoteType.all && type != _selectedTypeFilter) {
        continue;
      }

      if (_selectedEntityFilter != null) {
        final ents = SimilarityEngine.extractEntities(content);
        if (!ents.any(
          (e) => e.toLowerCase() == _selectedEntityFilter!.toLowerCase(),
        )) {
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
      displayedNotes.sort(
        (a, b) => (b['_score'] as double).compareTo(a['_score'] as double),
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: SpeedDial(
        icon: Icons.add_rounded,
        activeIcon: Icons.close_rounded,
        backgroundColor: AppColors.accentCoralDark,
        foregroundColor: AppColors.accentCoral,
        activeBackgroundColor: AppColors.cardSurface,
        activeForegroundColor: AppColors.accentCoral,
        spacing: 12,
        spaceBetweenChildren: 10,
        direction: SpeedDialDirection.up,
        renderOverlay: true,
        overlayColor: Colors.black,
        overlayOpacity: 0.5,
        elevation: 4,
        animationDuration: const Duration(milliseconds: 180),
        onPress: () => _openDocumentEditor(),
        children: [
          SpeedDialChild(
            child: const Icon(
              Icons.edit_note_rounded,
              color: AppColors.accentCoral,
            ),
            backgroundColor: AppColors.cardSurface,
            label: 'Nota Testuale',
            labelStyle: const TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
            labelBackgroundColor: AppColors.cardSurface,
            onTap: () {
              HapticFeedback.mediumImpact();
              _openDocumentEditor();
            },
          ),
          SpeedDialChild(
            child: const Icon(
              Icons.camera_alt_outlined,
              color: AppColors.statusGreen,
            ),
            backgroundColor: AppColors.cardSurface,
            label: 'Scatta Foto / OCR',
            labelStyle: const TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
            labelBackgroundColor: AppColors.cardSurface,
            onTap: () {
              HapticFeedback.mediumImpact();
              _handleImageCapture(ImageSource.camera);
            },
          ),
          SpeedDialChild(
            child: const Icon(
              Icons.image_outlined,
              color: AppColors.statusGreen,
            ),
            backgroundColor: AppColors.cardSurface,
            label: 'Da Galleria',
            labelStyle: const TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
            labelBackgroundColor: AppColors.cardSurface,
            onTap: () {
              HapticFeedback.mediumImpact();
              _handleImageCapture(ImageSource.gallery);
            },
          ),
          SpeedDialChild(
            child: const Icon(
              Icons.mic_none_rounded,
              color: AppColors.accentCoral,
            ),
            backgroundColor: AppColors.cardSurface,
            label: 'Nota Vocale',
            labelStyle: const TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
            labelBackgroundColor: AppColors.cardSurface,
            onTap: () {
              HapticFeedback.mediumImpact();
              _showAudioRecorderSheet();
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
                      const Icon(
                        Icons.bolt,
                        color: AppColors.statusGreen,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'In coda: $pendingCount • Connessioni: ${_allConnections.length}',
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
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 5,
                      ),
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
            SemanticSearchBar(
              onSearchChanged: (val) => setState(() => _searchQuery = val),
            ),
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _buildTypeChip('Tutte', NoteType.all, Icons.notes_rounded),
                  _buildTypeChip(
                    'Testo',
                    NoteType.text,
                    Icons.description_outlined,
                  ),
                  _buildTypeChip(
                    'Immagini',
                    NoteType.image,
                    Icons.image_outlined,
                  ),
                  _buildTypeChip(
                    'Vocali',
                    NoteType.audio,
                    Icons.mic_none_rounded,
                  ),
                ],
              ),
            ),
            if (topEntities.isNotEmpty) ...[
              const SizedBox(height: 8),
              SizedBox(
                height: 30,
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
                        margin: const EdgeInsets.only(right: 6),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? AppColors.accentCoralDark
                              : AppColors.cardSurface,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: isSelected
                                ? AppColors.accentCoral
                                : AppColors.cardSurfaceLight,
                          ),
                        ),
                        child: Text(
                          '#$ent ($count)',
                          style: TextStyle(
                            color: isSelected
                                ? AppColors.accentCoral
                                : AppColors.textSecondary,
                            fontSize: 11,
                            fontWeight: isSelected
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
            const SizedBox(height: 12),
            Expanded(
              child: displayedNotes.isEmpty
                  ? Center(
                      child: Text(
                        _searchQuery.isEmpty
                            ? 'Nessuna memoria presente.\nTocca "+" per aggiungere una nota.'
                            : 'Nessun risultato trovato.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 13,
                        ),
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
                        final entities = SimilarityEngine.extractEntities(
                          content,
                        );

                        final noteType = _getNoteType(content);
                        final parsed = _parseNoteDetails(content);

                        return Dismissible(
                          key: ValueKey(noteId),
                          direction: DismissDirection.horizontal,
                          onDismissed: (_) => _deleteNoteWithUndo(note),
                          background: Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            alignment: Alignment.centerLeft,
                            decoration: BoxDecoration(
                              color: AppColors.accentCoralDark,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Icon(
                              Icons.delete_sweep_outlined,
                              color: AppColors.accentCoral,
                            ),
                          ),
                          secondaryBackground: Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            alignment: Alignment.centerRight,
                            decoration: BoxDecoration(
                              color: AppColors.accentCoralDark,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Icon(
                              Icons.delete_sweep_outlined,
                              color: AppColors.accentCoral,
                            ),
                          ),
                          child: GestureDetector(
                            onTap: () =>
                                _openDocumentEditor(existingNote: note),
                            child: _buildKeepCard(
                              type: noteType,
                              title: parsed['title']!,
                              body: parsed['body']!,
                              imagePath: parsed['imagePath'],
                              audioPath: parsed['audioPath'],
                              snippet: snippet,
                              matchScore: matchScore,
                              entities: entities,
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

  Widget _buildTypeChip(String label, NoteType type, IconData icon) {
    final isSelected = _selectedTypeFilter == type;
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() => _selectedTypeFilter = type);
      },
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.accentCoralDark : AppColors.cardSurface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected
                ? AppColors.accentCoral
                : AppColors.cardSurfaceLight,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 14,
              color: isSelected
                  ? AppColors.accentCoral
                  : AppColors.textSecondary,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: isSelected
                    ? AppColors.accentCoral
                    : AppColors.textSecondary,
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildKeepCard({
    required NoteType type,
    required String title,
    required String body,
    required String? imagePath,
    required String? audioPath,
    required String? snippet,
    required double? matchScore,
    required List<String> entities,
  }) {
    IconData typeIcon;
    Color accentColor;

    switch (type) {
      case NoteType.audio:
        typeIcon = Icons.mic_none_rounded;
        accentColor = AppColors.accentCoral;
        break;
      case NoteType.image:
        typeIcon = Icons.camera_alt_outlined;
        accentColor = AppColors.statusGreen;
        break;
      case NoteType.text:
      default:
        typeIcon = Icons.article_outlined;
        accentColor = AppColors.textSecondary;
        break;
    }

    final bool isThisAudioPlaying =
        _isPlaying && _currentlyPlayingPath == audioPath;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cardSurface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: snippet != null
              ? AppColors.accentCoral.withOpacity(0.5)
              : AppColors.cardSurfaceLight,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(typeIcon, size: 16, color: accentColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
              ),
              if (matchScore != null && _searchQuery.isNotEmpty)
                Text(
                  '${(matchScore * 100).clamp(1, 99).toInt()}%',
                  style: const TextStyle(
                    color: AppColors.accentCoral,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
            ],
          ),
          if (imagePath != null && File(imagePath).existsSync()) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.file(
                File(imagePath),
                height: 160,
                width: double.infinity,
                fit: BoxFit.cover,
              ),
            ),
          ],
          if (audioPath != null && File(audioPath).existsSync()) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(
                      isThisAudioPlaying
                          ? Icons.pause_circle_filled_rounded
                          : Icons.play_circle_fill_rounded,
                      color: AppColors.accentCoral,
                      size: 32,
                    ),
                    onPressed: () => _toggleAudioPlayback(audioPath),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isThisAudioPlaying
                              ? 'In riproduzione...'
                              : 'Nota Vocale',
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        LinearProgressIndicator(
                          value: isThisAudioPlaying ? null : 0.0,
                          backgroundColor: AppColors.cardSurfaceLight,
                          color: AppColors.accentCoral,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (snippet != null && _searchQuery.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.accentCoralDark.withOpacity(0.4),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                snippet,
                style: const TextStyle(
                  color: AppColors.accentCoral,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
          if (body.isNotEmpty && body != 'Nessun testo allegato') ...[
            const SizedBox(height: 8),
            Text(
              body,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ],
          if (entities.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: entities.take(4).map((e) {
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
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
          ],
        ],
      ),
    );
  }
}
