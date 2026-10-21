import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../../../core/background/background_worker.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/database/note_dao.dart';
import '../../../data/embedding/similarity_engine.dart';
import '../../search/presentation/semantic_search_bar.dart';

enum NoteTypeFilter { all, text, image, audio }

class QuickNoteScreen extends StatefulWidget {
  const QuickNoteScreen({super.key});

  @override
  State<QuickNoteScreen> createState() => _QuickNoteScreenState();
}

class _QuickNoteScreenState extends State<QuickNoteScreen> {
  final NoteDao _noteDao = NoteDao();
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  List<Map<String, dynamic>> _allNotes = [];
  List<Map<String, dynamic>> _allConnections = [];

  String _searchQuery = '';
  String? _selectedEntityFilter;
  NoteTypeFilter _selectedTypeFilter = NoteTypeFilter.all;
  String? _geminiApiKey;

  final AudioRecorder _audioRecorder = AudioRecorder();
  final AudioPlayer _audioPlayer = AudioPlayer();
  final stt.SpeechToText _speech = stt.SpeechToText();
  String? _currentlyPlayingPath;
  bool _isPlaying = false;

  static const Map<String, String> _visionLabelTranslations = {
    'Person': 'Persona',
    'Smile': 'Sorriso',
    'Selfie': 'Selfie',
    'Cat': 'Gatto',
    'Dog': 'Cane',
    'Pet': 'Animale',
    'Plant': 'Pianta',
    'Flower': 'Fiore',
    'Food': 'Cibo',
    'Dish': 'Piatto',
    'Coffee': 'Caffè',
    'Pizza': 'Pizza',
    'Building': 'Edificio',
    'Room': 'Stanza',
    'Furniture': 'Arredamento',
    'Table': 'Scrivania',
    'Computer': 'Computer',
    'Laptop': 'Portatile',
    'Mobile phone': 'Smartphone',
    'Screen': 'Schermo',
    'Text': 'Documento',
    'Paper': 'Appunti',
    'Book': 'Libro',
    'Toy': 'Modellino',
    'Lego': 'Lego',
    'Robot': 'Robot',
  };

  // Etichette ML Kit troppo generiche/fuorvianti da ignorare su piccoli oggetti
  static const Set<String> _noisyLabels = {'car', 'vehicle', 'motor vehicle', 'automotive design'};

  @override
  void initState() {
    super.initState();
    _initAndRefresh();
    _audioPlayer.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _isPlaying = false;
          _currentlyPlayingPath = null;
        });
      }
    });
  }

  Future<void> _initAndRefresh() async {
    _geminiApiKey = await _secureStorage.read(key: 'gemini_api_key');
    await BackgroundWorker.processPendingNotes();
    await _refreshNotes();
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

  Future<void> _saveAndIndexNote(String content, {String? existingId}) async {
    if (content.trim().isEmpty) return;
    if (existingId != null) {
      await _noteDao.updateNote(existingId, content.trim());
    } else {
      await _noteDao.insertQuickNote(content.trim());
    }
    await BackgroundWorker.processPendingNotes();
    await _refreshNotes();
  }

  List<Map<String, dynamic>> _getLinkedNotesFor(String noteId) {
    final linkedIds = <String>{};
    for (final c in _allConnections) {
      if (c['source_id'] == noteId) linkedIds.add(c['target_id'] as String);
      if (c['target_id'] == noteId) linkedIds.add(c['source_id'] as String);
    }
    return _allNotes.where((n) => linkedIds.contains(n['id'])).toList();
  }

  String? _extractImagePath(String content) {
    final match = RegExp(r'\[\[IMG:([^\]]+)\]\]').firstMatch(content);
    return match?.group(1);
  }

  String? _extractAudioPath(String content) {
    final match = RegExp(r'\[\[AUDIO:([^\]]+)\]\]').firstMatch(content);
    return match?.group(1);
  }

  bool _isImageNote(String content) => _extractImagePath(content) != null;
  bool _isAudioNote(String content) => _extractAudioPath(content) != null;

  /// Menu che si apre TENENDO PREMUTO il pulsante "+ Nuova Nota"
  void _showLongPressCreationMenu() {
    HapticFeedback.heavyImpact();
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.cardSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(left: 12, bottom: 12),
                  child: Text(
                    'Inserimento Avanzato Multimodal',
                    style: TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.camera_alt_outlined, color: AppColors.statusGreen),
                  title: const Text('Scatta Foto (Vision AI + OCR)', style: TextStyle(color: AppColors.textPrimary)),
                  subtitle: Text(
                    _geminiApiKey != null && _geminiApiKey!.isNotEmpty
                        ? 'AI Cloud Attiva (Riconoscimento preciso via Internet)'
                        : 'Modalità Offline Locale (Configura AI Cloud per più precisione)',
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 11.5),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _handleImageCapture(ImageSource.camera);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.photo_library_outlined, color: AppColors.statusGreen),
                  title: const Text('Scegli Foto dalla Galleria', style: TextStyle(color: AppColors.textPrimary)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _handleImageCapture(ImageSource.gallery);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.mic_rounded, color: AppColors.accentCoral),
                  title: const Text('Registra Nota Vocale', style: TextStyle(color: AppColors.textPrimary)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showAudioRecorderSheet();
                  },
                ),
                const Divider(color: AppColors.cardSurfaceLight),
                ListTile(
                  leading: const Icon(Icons.auto_awesome_rounded, color: AppColors.accentCoral),
                  title: const Text('Imposta AI Cloud (Gemini API Gratuita)', style: TextStyle(color: AppColors.textPrimary)),
                  subtitle: const Text(
                    'Permette di riconoscere oggetti specifici (es. Wall-E, modelli, libri) via Internet',
                    style: TextStyle(color: AppColors.textSecondary, fontSize: 11.5),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showCloudAiSettingsDialog();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Finestra per inserire la chiave API gratuita di Google Gemini (per Vision AI precisa via Internet)
  Future<void> _showCloudAiSettingsDialog() async {
    final keyController = TextEditingController(text: _geminiApiKey ?? '');
    await showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: AppColors.cardSurface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          title: const Row(
            children: [
              Icon(Icons.auto_awesome, color: AppColors.accentCoral, size: 20),
              SizedBox(width: 8),
              Text('Vision AI via Internet', style: TextStyle(color: AppColors.textPrimary, fontSize: 16)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Inserisci una API Key gratuita di Google AI Studio (Gemini 2.5 Flash) per riconoscere con precisione qualsiasi oggetto nelle foto (es. personaggi, LEGO, piatti, schemi) quando sei connesso a Internet.\nSe sei offline, l\'app userà automaticamente ML Kit locale.',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5, height: 1.4),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: keyController,
                style: const TextStyle(color: AppColors.textPrimary, fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'AIzaSy...',
                  hintStyle: const TextStyle(color: AppColors.textSecondary),
                  filled: true,
                  fillColor: AppColors.background,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Annulla', style: TextStyle(color: AppColors.textSecondary)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accentCoralDark,
                foregroundColor: AppColors.accentCoral,
              ),
              onPressed: () async {
                final newKey = keyController.text.trim();
                await _secureStorage.write(key: 'gemini_api_key', value: newKey);
                setState(() => _geminiApiKey = newKey);
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Salva Chiave'),
            ),
          ],
        );
      },
    );
  }

  /// Chiama Gemini 2.5 Flash via Internet se la chiave è presente; altrimenti ritorna null e usa il fallback offline
  Future<String?> _analyzeImageWithCloudAi(File imageFile) async {
    if (_geminiApiKey == null || _geminiApiKey!.trim().isEmpty) return null;
    try {
      final bytes = await imageFile.readAsBytes();
      final base64Image = base64Encode(bytes);

      final url = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${_geminiApiKey!.trim()}',
      );

      final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
      final request = await client.postUrl(url);
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json; charset=UTF-8');

      final payload = jsonEncode({
        'contents': [
          {
            'parts': [
              {
                'text':
                    'Descrivi in italiano in modo conciso ma preciso cosa vedi in questa foto (identifica il soggetto specifico, es. personaggio, modello LEGO, documento, coordinate o oggetto) e concludi con 3 o 4 hashtag pertinenti in italiano (es. #WallE #Lego #Robot). Non usare markdown.'
              },
              {
                'inline_data': {
                  'mime_type': 'image/jpeg',
                  'data': base64Image,
                }
              }
            ]
          }
        ]
      });

      request.add(utf8.encode(payload));
      final response = await request.close();
      if (response.statusCode == 200) {
        final responseBody = await response.transform(utf8.decoder).join();
        final decoded = jsonDecode(responseBody);
        final text = decoded['candidates']?[0]?['content']?['parts']?[0]?['text'] as String?;
        return text?.trim();
      }
    } catch (_) {
      // Nessuna connessione internet o errore API -> passa silenziosamente all'OCR/Vision locale
    }
    return null;
  }

  Future<void> _handleImageCapture(ImageSource source) async {
    try {
      final picker = ImagePicker();
      final pickedFile = await picker.pickImage(source: source, maxWidth: 1280, imageQuality: 80);
      if (pickedFile == null) return;

      HapticFeedback.mediumImpact();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            (_geminiApiKey != null && _geminiApiKey!.isNotEmpty)
                ? 'Analisi intelligente AI + OCR in corso...'
                : 'Scansione OCR e Vision locale in corso...',
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.cardSurfaceLight,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          duration: const Duration(seconds: 2),
        ),
      );

      final appDir = await getApplicationDocumentsDirectory();
      final fileName = 'img_${DateTime.now().millisecondsSinceEpoch}${p.extension(pickedFile.path)}';
      final savedImage = await File(pickedFile.path).copy('${appDir.path}/$fileName');

      // 1. Prova prima con l'AI Cloud (se configurata e connesso a Internet)
      String? cloudDescription = await _analyzeImageWithCloudAi(savedImage);

      String suggestedText = '';
      if (cloudDescription != null && cloudDescription.isNotEmpty) {
        suggestedText = cloudDescription;
      } else {
        // 2. Fallback 100% Offline (OCR + ML Kit filtrato dai falsi positivi come Car/Vehicle)
        final inputImage = InputImage.fromFilePath(savedImage.path);

        final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
        final RecognizedText recognizedText = await textRecognizer.processImage(inputImage);
        await textRecognizer.close();
        final ocrText = recognizedText.text.trim();

        final imageLabeler = ImageLabeler(options: ImageLabelerOptions(confidenceThreshold: 0.62));
        final List<ImageLabel> labels = await imageLabeler.processImage(inputImage);
        await imageLabeler.close();

        final cleanTags = <String>{};
        for (final l in labels) {
          if (_noisyLabels.contains(l.label.toLowerCase())) continue;
          final itName = _visionLabelTranslations[l.label] ?? l.label;
          final tag = itName.replaceAll(RegExp(r'[^\wàèéìòùÀÈÉÌÒÙ]'), '');
          if (tag.length >= 3) cleanTags.add('#$tag');
        }

        final buf = StringBuffer();
        if (ocrText.isNotEmpty) {
          buf.writeln(ocrText);
        }
        if (cleanTags.isNotEmpty) {
          buf.write(cleanTags.take(3).join(' '));
        }
        suggestedText = buf.toString().trim();
      }

      // 3. Apre subito l'editor con la foto e la descrizione precompilata, così puoi verificare/personalizzare (es. scrivere "Walle")!
      if (mounted) {
        await _openDocumentEditor(
          initialImagePath: savedImage.path,
          initialText: suggestedText,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Errore scansione foto: $e')),
        );
      }
    }
  }

  void _showAudioRecorderSheet() {
    bool isRecordingAudio = false;
    bool isListeningStt = false;
    String? recordedFilePath;
    double currentDbLevel = 0.0;
    int elapsedSeconds = 0;
    Timer? recordTimer;
    StreamSubscription<Amplitude>? ampSub;
    final transcriptController = TextEditingController();

    showModalBottomSheet(
      context: context,
      isDismissible: false,
      isScrollControlled: true,
      backgroundColor: AppColors.cardSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setStateModal) {
            Future<void> stopEverything() async {
              recordTimer?.cancel();
              await ampSub?.cancel();
              if (isListeningStt) {
                await _speech.stop();
                isListeningStt = false;
              }
              if (isRecordingAudio) {
                final path = await _audioRecorder.stop();
                if (path != null) recordedFilePath = path;
                isRecordingAudio = false;
              }
            }

            String formatDuration(int sec) {
              final m = (sec ~/ 60).toString().padLeft(2, '0');
              final s = (sec % 60).toString().padLeft(2, '0');
              return '$m:$s';
            }

            return Padding(
              padding: EdgeInsets.only(
                left: 24,
                right: 24,
                top: 24,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 28,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Nuova Nota Vocale',
                        style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded, color: AppColors.textSecondary),
                        onPressed: () async {
                          await stopEverything();
                          if (ctx.mounted) Navigator.pop(ctx);
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 100),
                    padding: EdgeInsets.all(18 + (currentDbLevel * 14)),
                    decoration: BoxDecoration(
                      color: isRecordingAudio
                          ? AppColors.accentCoralDark.withOpacity(0.4 + (currentDbLevel * 0.4))
                          : (recordedFilePath != null ? AppColors.statusGreenBg : AppColors.background),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      isRecordingAudio
                          ? Icons.mic_rounded
                          : (recordedFilePath != null ? Icons.check_circle_outline_rounded : Icons.mic_none_rounded),
                      color: isRecordingAudio
                          ? AppColors.accentCoral
                          : (recordedFilePath != null ? AppColors.statusGreen : AppColors.textSecondary),
                      size: 40,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    isRecordingAudio
                        ? 'Registrazione in corso: ${formatDuration(elapsedSeconds)}'
                        : (recordedFilePath != null
                            ? 'Audio registrato (${formatDuration(elapsedSeconds)})'
                            : 'Premi "Registra Audio" per parlare'),
                    style: TextStyle(
                      color: isRecordingAudio ? AppColors.accentCoral : AppColors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (isRecordingAudio) ...[
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        value: currentDbLevel.clamp(0.06, 1.0),
                        minHeight: 6,
                        backgroundColor: AppColors.background,
                        valueColor: const AlwaysStoppedAnimation<Color>(AppColors.accentCoral),
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (!isRecordingAudio)
                        ElevatedButton.icon(
                          onPressed: () async {
                            if (isListeningStt) {
                              await _speech.stop();
                              setStateModal(() => isListeningStt = false);
                            }
                            if (await _audioRecorder.hasPermission()) {
                              HapticFeedback.mediumImpact();
                              final dir = await getApplicationDocumentsDirectory();
                              final path = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';

                              await _audioRecorder.start(
                                const RecordConfig(
                                  encoder: AudioEncoder.aacLc,
                                  bitRate: 64000,
                                  sampleRate: 44100,
                                  numChannels: 1,
                                ),
                                path: path,
                              );

                              elapsedSeconds = 0;
                              recordTimer?.cancel();
                              recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
                                if (ctx.mounted) setStateModal(() => elapsedSeconds++);
                              });

                              ampSub?.cancel();
                              ampSub = _audioRecorder
                                  .onAmplitudeChanged(const Duration(milliseconds: 120))
                                  .listen((amp) {
                                final norm = ((amp.current + 50) / 50).clamp(0.0, 1.0);
                                if (ctx.mounted) setStateModal(() => currentDbLevel = norm);
                              });

                              setStateModal(() {
                                isRecordingAudio = true;
                                recordedFilePath = path;
                              });
                            }
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.statusGreenBg,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                          ),
                          icon: const Icon(Icons.fiber_manual_record_rounded, color: AppColors.statusGreen),
                          label: Text(
                            recordedFilePath == null ? 'Registra Audio' : 'Riregistra',
                            style: const TextStyle(color: AppColors.statusGreen, fontWeight: FontWeight.bold),
                          ),
                        )
                      else
                        ElevatedButton.icon(
                          onPressed: () async {
                            HapticFeedback.heavyImpact();
                            recordTimer?.cancel();
                            await ampSub?.cancel();
                            final path = await _audioRecorder.stop();
                            setStateModal(() {
                              isRecordingAudio = false;
                              currentDbLevel = 0.0;
                              if (path != null) recordedFilePath = path;
                            });
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.accentCoralDark,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                          ),
                          icon: const Icon(Icons.stop_rounded, color: AppColors.accentCoral),
                          label: const Text(
                            'Ferma Audio',
                            style: TextStyle(color: AppColors.accentCoral, fontWeight: FontWeight.bold),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: transcriptController,
                    maxLines: 3,
                    minLines: 2,
                    enabled: !isRecordingAudio,
                    style: const TextStyle(color: AppColors.textPrimary, fontSize: 14),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: AppColors.background,
                      hintText: isRecordingAudio
                          ? 'Ferma prima l\'audio se vuoi dettare o scrivere il testo...'
                          : 'Scrivi o premi l\'icona a destra per dettare il contenuto...',
                      hintStyle: const TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                      suffixIcon: IconButton(
                        icon: Icon(
                          isListeningStt ? Icons.mic_off_rounded : Icons.record_voice_over_rounded,
                          color: isListeningStt ? AppColors.accentCoral : AppColors.statusGreen,
                        ),
                        onPressed: isRecordingAudio
                            ? null
                            : () async {
                                if (isListeningStt) {
                                  await _speech.stop();
                                  setStateModal(() => isListeningStt = false);
                                } else {
                                  bool available = await _speech.initialize(
                                    onStatus: (status) {
                                      if (status == 'done' || status == 'notListening') {
                                        if (ctx.mounted) setStateModal(() => isListeningStt = false);
                                      }
                                    },
                                  );
                                  if (available) {
                                    HapticFeedback.selectionClick();
                                    final prefix = transcriptController.text.trim();
                                    setStateModal(() => isListeningStt = true);
                                    await _speech.listen(
                                      localeId: 'it_IT',
                                      listenFor: const Duration(minutes: 2),
                                      pauseFor: const Duration(seconds: 10),
                                      onResult: (val) {
                                        if (ctx.mounted) {
                                          setStateModal(() {
                                            transcriptController.text = prefix.isEmpty
                                                ? val.recognizedWords
                                                : '$prefix ${val.recognizedWords}';
                                          });
                                        }
                                      },
                                    );
                                  }
                                }
                              },
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: (isRecordingAudio ||
                              (recordedFilePath == null && transcriptController.text.trim().isEmpty))
                          ? null
                          : () async {
                              HapticFeedback.mediumImpact();
                              await stopEverything();
                              final textPart = transcriptController.text.trim().isNotEmpty
                                  ? transcriptController.text.trim()
                                  : 'Nota vocale (${formatDuration(elapsedSeconds)}) #Vocale';

                              final buffer = StringBuffer();
                              if (recordedFilePath != null && File(recordedFilePath!).existsSync()) {
                                buffer.writeln('[[AUDIO:$recordedFilePath]]');
                              }
                              buffer.write(textPart);

                              await _saveAndIndexNote(buffer.toString());
                              if (ctx.mounted) Navigator.pop(ctx);
                            },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.accentCoralDark,
                        foregroundColor: AppColors.accentCoral,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                      ),
                      icon: const Icon(Icons.check_rounded),
                      label: const Text('Salva Nota Vocale', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _toggleAudioPlayback(String path) async {
    HapticFeedback.selectionClick();
    if (!File(path).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('File audio non trovato.')),
      );
      return;
    }
    if (_isPlaying && _currentlyPlayingPath == path) {
      await _audioPlayer.stop();
      setState(() {
        _isPlaying = false;
        _currentlyPlayingPath = null;
      });
    } else {
      await _audioPlayer.stop();
      await _audioPlayer.play(DeviceFileSource(path));
      setState(() {
        _isPlaying = true;
        _currentlyPlayingPath = path;
      });
    }
  }

  Future<void> _deleteNoteWithUndo(Map<String, dynamic> note) async {
    final String noteId = note['id'] as String;
    final backupNote = Map<String, dynamic>.from(note);

    HapticFeedback.heavyImpact();
    await _noteDao.deleteNote(noteId);
    await BackgroundWorker.processPendingNotes();
    await _refreshNotes();

    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        backgroundColor: AppColors.cardSurfaceLight,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        duration: const Duration(seconds: 4),
        content: const Text('Memoria eliminata', style: TextStyle(color: AppColors.textPrimary)),
        action: SnackBarAction(
          label: 'ANNULLA',
          textColor: AppColors.accentCoral,
          onPressed: () async {
            HapticFeedback.mediumImpact();
            await _noteDao.restoreNote(backupNote);
            await BackgroundWorker.processPendingNotes();
            await _refreshNotes();
          },
        ),
      ),
    );
  }

  Future<void> _openDocumentEditor({
    Map<String, dynamic>? existingNote,
    String? initialImagePath,
    String? initialText,
  }) async {
    HapticFeedback.mediumImpact();
    final isEditing = existingNote != null;
    final String rawExisting = isEditing ? (existingNote['content'] as String) : '';
    final String? imgPath = initialImagePath ?? _extractImagePath(rawExisting);
    final String? audioPath = _extractAudioPath(rawExisting);

    final controller = TextEditingController(
      text: initialText ?? SimilarityEngine.stripMediaMarkers(rawExisting),
    );
    final String? noteId = isEditing ? (existingNote['id'] as String) : null;
    final linkedNotes = isEditing ? _getLinkedNotesFor(noteId!) : <Map<String, dynamic>>[];

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (ctx) {
          return StatefulBuilder(
            builder: (context, setModalState) {
              final liveEntities = SimilarityEngine.extractEntities(controller.text);

              Future<void> saveFromEditor() async {
                final text = controller.text.trim();
                if (text.isEmpty && imgPath == null && audioPath == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Scrivi qualcosa prima di salvare!')),
                  );
                  return;
                }
                HapticFeedback.mediumImpact();

                final buffer = StringBuffer();
                if (imgPath != null) buffer.writeln('[[IMG:$imgPath]]');
                if (audioPath != null) buffer.writeln('[[AUDIO:$audioPath]]');
                buffer.write(text);

                await _saveAndIndexNote(buffer.toString(), existingId: noteId);
                if (ctx.mounted) Navigator.pop(ctx);
              }

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
                    isEditing ? 'Modifica Memoria' : 'Nuova Memoria',
                    style: const TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  actions: [
                    if (isEditing)
                      IconButton(
                        icon: const Icon(Icons.delete_outline_rounded, color: AppColors.accentCoral),
                        onPressed: () async {
                          Navigator.pop(ctx);
                          await _deleteNoteWithUndo(existingNote);
                        },
                      ),
                    Padding(
                      padding: const EdgeInsets.only(right: 12.0),
                      child: TextButton.icon(
                        onPressed: saveFromEditor,
                        style: TextButton.styleFrom(
                          backgroundColor: AppColors.accentCoralDark,
                          foregroundColor: AppColors.accentCoral,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                        ),
                        icon: const Icon(Icons.check_rounded, size: 18),
                        label: const Text('Salva', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
                body: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 8.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (imgPath != null && File(imgPath).existsSync()) ...[
                        Stack(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(18),
                              child: Image.file(
                                File(imgPath),
                                height: 180,
                                width: double.infinity,
                                fit: BoxFit.cover,
                              ),
                            ),
                            Positioned(
                              bottom: 8,
                              right: 8,
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.cardSurface.withOpacity(0.9),
                                  foregroundColor: AppColors.accentCoral,
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                ),
                                icon: const Icon(Icons.auto_awesome, size: 16),
                                label: const Text('Analizza con AI Cloud', style: TextStyle(fontSize: 12)),
                                onPressed: () async {
                                  if (_geminiApiKey == null || _geminiApiKey!.isEmpty) {
                                    await _showCloudAiSettingsDialog();
                                  }
                                  if (_geminiApiKey != null && _geminiApiKey!.isNotEmpty) {
                                    final desc = await _analyzeImageWithCloudAi(File(imgPath));
                                    if (desc != null) {
                                      setModalState(() {
                                        controller.text = desc;
                                      });
                                    }
                                  }
                                },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (liveEntities.isNotEmpty) ...[
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              const Icon(Icons.hub_outlined, size: 16, color: AppColors.statusGreen),
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
                          autofocus: !isEditing && imgPath == null,
                          maxLines: null,
                          expands: true,
                          onChanged: (_) => setModalState(() {}),
                          style: const TextStyle(color: AppColors.textPrimary, fontSize: 15, height: 1.5),
                          decoration: const InputDecoration(
                            hintText: 'Scrivi un fatto, un ricordo o un #Tag (es. "Alla Manu piace la cioccolata")...',
                            hintStyle: TextStyle(color: AppColors.textSecondary, fontSize: 14),
                            border: InputBorder.none,
                          ),
                        ),
                      ),
                      if (linkedNotes.isNotEmpty) ...[
                        const Divider(color: AppColors.cardSurfaceLight),
                        const Padding(
                          padding: EdgeInsets.only(bottom: 6.0),
                          child: Text(
                            'MEMORIE COLLEGATE AUTOMATICAMENTE:',
                            style: TextStyle(
                              color: AppColors.accentCoral,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ),
                        SizedBox(
                          height: 64,
                          child: ListView.builder(
                            scrollDirection: Axis.horizontal,
                            itemCount: linkedNotes.length,
                            itemBuilder: (context, idx) {
                              final ln = linkedNotes[idx];
                              final lnText = SimilarityEngine.stripMediaMarkers(ln['content'] as String);
                              return GestureDetector(
                                onTap: () {
                                  Navigator.pop(ctx);
                                  _openDocumentEditor(existingNote: ln);
                                },
                                child: Container(
                                  width: 210,
                                  margin: const EdgeInsets.only(right: 10, bottom: 8),
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: AppColors.cardSurface,
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(color: AppColors.statusGreen.withOpacity(0.4)),
                                  ),
                                  child: Text(
                                    lnText,
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
    final indexedCount = _allNotes.where((n) => n['status'] == 'INDEXED').length;

    final entityCounts = <String, int>{};
    for (final n in _allNotes) {
      for (final ent in SimilarityEngine.extractEntities(n['content'] as String)) {
        entityCounts[ent] = (entityCounts[ent] ?? 0) + 1;
      }
    }
    final topEntities = entityCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    List<Map<String, dynamic>> displayedNotes = [];
    for (final n in _allNotes) {
      final content = n['content'] as String;

      if (_selectedTypeFilter == NoteTypeFilter.image && !_isImageNote(content)) continue;
      if (_selectedTypeFilter == NoteTypeFilter.audio && !_isAudioNote(content)) continue;
      if (_selectedTypeFilter == NoteTypeFilter.text && (_isImageNote(content) || _isAudioNote(content))) continue;

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
        if (score >= 0.22) {
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
      // UNICO TASTO PULITO:
      // - Click singolo (onTap) -> Apre subito l'editor di testo!
      // - Tenuto premuto (onLongPress) -> Apre il menu Fotocamera / Galleria / Audio!
      floatingActionButton: GestureDetector(
        onLongPress: _showLongPressCreationMenu,
        child: FloatingActionButton.extended(
          heroTag: 'btn_unified_add',
          onPressed: () => _openDocumentEditor(),
          backgroundColor: AppColors.accentCoralDark,
          foregroundColor: AppColors.accentCoral,
          icon: const Icon(Icons.add_rounded),
          label: const Text('Nuova Nota', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
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
                      const Icon(Icons.hub_rounded, color: AppColors.statusGreen, size: 18),
                      const SizedBox(width: 8),
                      Text(
                        'Memorie: $indexedCount • Collegamenti: ${_allConnections.length}',
                        style: const TextStyle(color: AppColors.statusGreen, fontWeight: FontWeight.w600, fontSize: 12.5),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      GestureDetector(
                        onTap: _showCloudAiSettingsDialog,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 8.0),
                          child: Icon(
                            Icons.auto_awesome,
                            size: 18,
                            color: (_geminiApiKey != null && _geminiApiKey!.isNotEmpty)
                                ? AppColors.accentCoral
                                : AppColors.textSecondary,
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: () async {
                          HapticFeedback.mediumImpact();
                          await BackgroundWorker.processPendingNotes();
                          await _refreshNotes();
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppColors.statusGreen.withOpacity(0.25),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Text(
                            'Ricalcola',
                            style: TextStyle(color: AppColors.textPrimary, fontSize: 11, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                    ],
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
                  _buildTypeFilterChip(NoteTypeFilter.all, 'Tutte', Icons.grid_view_rounded),
                  _buildTypeFilterChip(NoteTypeFilter.text, 'Testo', Icons.notes_rounded),
                  _buildTypeFilterChip(NoteTypeFilter.image, 'Immagini', Icons.image_outlined),
                  _buildTypeFilterChip(NoteTypeFilter.audio, 'Vocali', Icons.graphic_eq_rounded),
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
                        margin: const EdgeInsets.only(right: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                        decoration: BoxDecoration(
                          color: isSelected ? AppColors.accentCoralDark : AppColors.cardSurface,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: isSelected ? AppColors.accentCoral : AppColors.cardSurfaceLight,
                          ),
                        ),
                        child: Text(
                          '#$ent ($count)',
                          style: TextStyle(
                            color: isSelected ? AppColors.accentCoral : AppColors.textSecondary,
                            fontSize: 11.5,
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

            if (_searchQuery.trim().isNotEmpty && displayedNotes.isNotEmpty)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.accentCoralDark.withOpacity(0.38),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppColors.accentCoral.withOpacity(0.6)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.psychology_rounded, color: AppColors.accentCoral, size: 18),
                        SizedBox(width: 6),
                        Text(
                          'RISPOSTA DALLA TUA MEMORIA:',
                          style: TextStyle(
                            color: AppColors.accentCoral,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.6,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ...displayedNotes.take(2).map((dn) {
                      final ans = (dn['_snippet'] as String?) ??
                          SimilarityEngine.stripMediaMarkers(dn['content'] as String);
                      return Padding(
                        padding: const EdgeInsets.only(top: 4.0),
                        child: Text(
                          '• $ans',
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ),

            Expanded(
              child: displayedNotes.isEmpty
                  ? Center(
                      child: Text(
                        _searchQuery.isEmpty
                            ? 'Nessuna nota presente.\nTocca "+ Nuova Nota" per scrivere o tieni premuto per Foto/Audio.'
                            : 'Nessuna informazione trovata per "$_searchQuery".',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 90),
                      itemCount: displayedNotes.length,
                      itemBuilder: (context, index) {
                        final note = displayedNotes[index];
                        final String noteId = note['id'] as String;
                        final String rawContent = note['content'] as String;
                        final String cleanContent = SimilarityEngine.stripMediaMarkers(rawContent);
                        final String? imgPath = _extractImagePath(rawContent);
                        final String? audioPath = _extractAudioPath(rawContent);
                        final double? matchScore = note['_score'] as double?;
                        final entities = SimilarityEngine.extractEntities(rawContent);
                        final linkedNotes = _getLinkedNotesFor(noteId);

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
                                  color: matchScore != null
                                      ? AppColors.accentCoral.withOpacity(0.5)
                                      : Colors.transparent,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (imgPath != null && File(imgPath).existsSync()) ...[
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(14),
                                      child: Image.file(
                                        File(imgPath),
                                        height: 160,
                                        width: double.infinity,
                                        fit: BoxFit.cover,
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                  ],
                                  if (audioPath != null) ...[
                                    GestureDetector(
                                      onTap: () => _toggleAudioPlayback(audioPath),
                                      child: Container(
                                        margin: const EdgeInsets.only(bottom: 10),
                                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                        decoration: BoxDecoration(
                                          color: (_isPlaying && _currentlyPlayingPath == audioPath)
                                              ? AppColors.accentCoralDark.withOpacity(0.6)
                                              : AppColors.background,
                                          borderRadius: BorderRadius.circular(14),
                                          border: Border.all(
                                            color: (_isPlaying && _currentlyPlayingPath == audioPath)
                                                ? AppColors.accentCoral
                                                : AppColors.cardSurfaceLight,
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              (_isPlaying && _currentlyPlayingPath == audioPath)
                                                  ? Icons.stop_circle_rounded
                                                  : Icons.play_circle_fill_rounded,
                                              color: AppColors.accentCoral,
                                              size: 24,
                                            ),
                                            const SizedBox(width: 8),
                                            Text(
                                              (_isPlaying && _currentlyPlayingPath == audioPath)
                                                  ? 'In riproduzione... (Tocca per fermare)'
                                                  : 'Ascolta Nota Vocale',
                                              style: const TextStyle(
                                                color: AppColors.textPrimary,
                                                fontSize: 12.5,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                  if (cleanContent.isNotEmpty)
                                    Text(
                                      cleanContent,
                                      maxLines: 5,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(color: AppColors.textPrimary, fontSize: 14, height: 1.4),
                                    ),
                                  const SizedBox(height: 10),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Expanded(
                                        child: Wrap(
                                          spacing: 6,
                                          runSpacing: 4,
                                          children: [
                                            ...entities.take(3).map((e) {
                                              return Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                                decoration: BoxDecoration(
                                                  color: AppColors.cardSurfaceLight,
                                                  borderRadius: BorderRadius.circular(8),
                                                ),
                                                child: Text(
                                                  '#$e',
                                                  style: const TextStyle(
                                                    color: AppColors.accentCoral,
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                              );
                                            }),
                                            if (linkedNotes.isNotEmpty)
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                                decoration: BoxDecoration(
                                                  color: AppColors.statusGreenBg,
                                                  borderRadius: BorderRadius.circular(8),
                                                ),
                                                child: Text(
                                                  '🔗 ${linkedNotes.length} collegate',
                                                  style: const TextStyle(
                                                    color: AppColors.statusGreen,
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                              ),
                                          ],
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

  Widget _buildTypeFilterChip(NoteTypeFilter filter, String label, IconData icon) {
    final isSelected = _selectedTypeFilter == filter;
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() => _selectedTypeFilter = filter);
      },
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.statusGreenBg : AppColors.cardSurface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? AppColors.statusGreen : AppColors.cardSurfaceLight,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: isSelected ? AppColors.statusGreen : AppColors.textSecondary,
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? AppColors.statusGreen : AppColors.textSecondary,
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}