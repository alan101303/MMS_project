import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:speech_to_text/speech_to_text.dart';

void main() {
  runApp(
    ChangeNotifierProvider(
      create: (_) => KitchenController()..loadRecipes(),
      child: const KitchenApp(),
    ),
  );
}

const _ink = Color(0xFF24332D);
const _green = Color(0xFF3C684F);
const _cream = Color(0xFFF7F5EF);

class KitchenApp extends StatelessWidget {
  const KitchenApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Küchenstimme',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: _cream,
      colorScheme: ColorScheme.fromSeed(
        seedColor: _green,
        primary: _green,
        surface: _cream,
      ),
      fontFamily: 'Roboto',
    ),
    home: const KitchenHomePage(),
  );
}

class Recipe {
  const Recipe({
    required this.name,
    required this.description,
    required this.duration,
    required this.icon,
    required this.ingredients,
    required this.steps,
  });

  final String name;
  final String description;
  final int duration;
  final String icon;
  final List<String> ingredients;
  final List<String> steps;

  factory Recipe.fromJson(Map<String, dynamic> json) => Recipe(
    name: json['name'] as String,
    description: json['description'] as String,
    duration: json['duration'] as int,
    icon: json['icon'] as String,
    ingredients: (json['ingredients'] as List<dynamic>).cast<String>(),
    steps: (json['steps'] as List<dynamic>).cast<String>(),
  );
}

class _KitchenSnapshot {
  const _KitchenSnapshot({
    required this.recipeIndex,
    required this.stepIndex,
    required this.paused,
    required this.timerSeconds,
  });

  final int recipeIndex;
  final int stepIndex;
  final bool paused;
  final int timerSeconds;
}

class KitchenController extends ChangeNotifier {
  final SpeechToText _speech = SpeechToText();
  final FlutterTts _tts = FlutterTts();
  final List<Recipe> recipes = [];
  Timer? _timer;
  _KitchenSnapshot? _undoSnapshot;
  bool _speechInitialized = false;
  bool _heardFeedback = false;
  int _recipeIndex = 0;
  int stepIndex = 0;
  int timerSeconds = 0;
  bool isListening = false;
  bool isPaused = false;
  bool isLoading = true;
  String recognizedText = '';
  String feedback = 'Sag „Weiter“ oder tippe auf das Mikrofon.';
  String selectedInput = 'Stimme';

  Recipe? get recipe => recipes.isEmpty ? null : recipes[_recipeIndex];
  bool get canUndo => _undoSnapshot != null;

  void setInputMode(String mode) {
    selectedInput = mode;
    notifyListeners();
  }

  Future<void> loadRecipes() async {
    try {
      final json = await rootBundle.loadString('assets/recipes.json');
      final decoded = jsonDecode(json) as List<dynamic>;
      recipes
        ..clear()
        ..addAll(
          decoded.map((item) => Recipe.fromJson(item as Map<String, dynamic>)),
        );
      if (recipes.isEmpty) {
        feedback = 'Keine Rezepte gefunden.';
      }
    } on FormatException catch (error) {
      feedback = 'Die Rezeptdaten sind ungültig: ${error.message}';
    } on FlutterError catch (error) {
      feedback =
          'Die Rezeptdaten konnten nicht geladen werden: ${error.message}';
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _configureSpeech() async {
    if (_speechInitialized) return;

    final granted = await Permission.microphone.request();
    if (!granted.isGranted) {
      feedback = granted.isPermanentlyDenied
          ? 'Mikrofonzugriff fehlt. Bitte erlaube ihn in den Einstellungen.'
          : 'Für die Sprachsteuerung wird Mikrofonzugriff benötigt.';
      notifyListeners();
      return;
    }

    _speechInitialized = await _speech.initialize(
      onStatus: (status) {
        isListening = status == 'listening';
        notifyListeners();
      },
      onError: (error) {
        isListening = false;
        feedback = 'Spracherkennung: ${error.errorMsg}';
        notifyListeners();
      },
    );
    if (!_speechInitialized) {
      feedback = 'Spracherkennung nicht verfügbar. Bitte prüfe die Spracheinstellungen.';
      notifyListeners();
    }
  }

  Future<void> toggleListening({
    Future<void> Function(String text, double confidence)? onFinalResult,
  }) async {
    if (isListening) {
      await _speech.stop();
      return;
    }

    await _configureSpeech();
    if (!_speechInitialized) return;
    recognizedText = '';
    _heardFeedback = false;
    feedback = 'Ich höre zu …';
    notifyListeners();
    await _speech.listen(
      listenOptions: SpeechListenOptions(
        localeId: 'de_DE',
        listenFor: const Duration(seconds: 20),
        pauseFor: const Duration(seconds: 3),
      ),
      onResult: (result) {
        recognizedText = result.recognizedWords;
        if (recognizedText.trim().isNotEmpty && !_heardFeedback) {
          _heardFeedback = true;
          unawaited(SystemSound.play(SystemSoundType.click));
        }
        if (result.finalResult && recognizedText.trim().isNotEmpty) {
          unawaited(
            (onFinalResult ?? handleCommand)(recognizedText, result.confidence),
          );
        }
        notifyListeners();
      },
    );
  }

  Future<bool> selectRecipeFromSpeech(String text, double confidence) async {
    recognizedText = text;
    final normalized = text.toLowerCase().trim();

    if (confidence > 0 && confidence < 0.35) {
      feedback =
          'Ich bin nicht sicher. Bitte sage den Rezeptnamen noch einmal.';
      notifyListeners();
      await _speak(feedback);
      return false;
    }

    final index = _findRecipeIndex(normalized);
    if (index == null) {
      feedback = 'Ich habe das Rezept nicht erkannt. Sage zum Beispiel „Cremige Tomatenpasta“.';
      notifyListeners();
      await _speak(feedback);
      return false;
    }

    openRecipe(index);
    feedback = '${recipes[index].name} ausgewählt.';
    notifyListeners();
    return true;
  }

  void _saveUndo() {
    _undoSnapshot = _KitchenSnapshot(
      recipeIndex: _recipeIndex,
      stepIndex: stepIndex,
      paused: isPaused,
      timerSeconds: timerSeconds,
    );
  }

  Future<void> undo() async {
    final snapshot = _undoSnapshot;
    if (snapshot == null) return;
    _timer?.cancel();
    _recipeIndex = snapshot.recipeIndex;
    stepIndex = snapshot.stepIndex;
    isPaused = snapshot.paused;
    timerSeconds = snapshot.timerSeconds;
    _undoSnapshot = null;
    if (timerSeconds > 0) _startTimerTicker();
    feedback = 'Letzte Aktion rückgängig gemacht.';
    notifyListeners();
    await _readCurrentStep();
  }

  Future<void> selectRecipe(int index) async {
    if (index < 0 || index >= recipes.length || index == _recipeIndex) return;
    _saveUndo();
    _recipeIndex = index;
    stepIndex = 0;
    isPaused = false;
    ingredientsVisible = false;
    feedback = 'Rezept ausgewählt.';
    notifyListeners();
    await _readCurrentStep();
  }

  void openRecipe(int index) {
    if (index < 0 || index >= recipes.length) return;
    _saveUndo();
    _recipeIndex = index;
    stepIndex = 0;
    isPaused = true;
    ingredientsVisible = false;
    feedback = 'Tippe auf Start, wenn du bereit bist.';
    notifyListeners();
  }

  Future<void> nextStep() async {
    final current = recipe;
    if (current == null) return;
    if (stepIndex >= current.steps.length - 1) {
      feedback = 'Das war der letzte Schritt. Guten Appetit!';
      await _speak(feedback);
      notifyListeners();
      return;
    }
    _saveUndo();
    stepIndex++;
    isPaused = false;
    feedback = 'Schritt ${stepIndex + 1} von ${current.steps.length}';
    notifyListeners();
    await _readCurrentStep();
  }

  Future<void> previousStep() async {
    if (stepIndex == 0) {
      feedback = 'Du bist schon beim ersten Schritt.';
      notifyListeners();
      return;
    }
    _saveUndo();
    stepIndex--;
    isPaused = false;
    feedback = 'Schritt ${stepIndex + 1} von ${recipe!.steps.length}';
    notifyListeners();
    await _readCurrentStep();
  }

  Future<void> repeatStep() async {
    isPaused = false;
    feedback = 'Ich wiederhole den Schritt.';
    notifyListeners();
    await _readCurrentStep();
  }

  Future<void> togglePause() async {
    _saveUndo();
    isPaused = !isPaused;
    if (isPaused) {
      feedback = 'Anleitung pausiert.';
      notifyListeners();
      await _tts.stop();
    } else {
      feedback = 'Weiter geht’s.';
      notifyListeners();
      await _readCurrentStep();
    }
    notifyListeners();
  }

  void showIngredients() {
    ingredientsVisible = true;
    feedback = 'Zutaten für ${recipe?.name ?? 'das Rezept'}';
    notifyListeners();
  }

  bool ingredientsVisible = false;

  Future<void> startTimer(int minutes) async {
    if (minutes < 1 || minutes > 240) {
      feedback = 'Bitte nenne eine Zeit zwischen 1 und 240 Minuten.';
      notifyListeners();
      return;
    }
    _saveUndo();
    _timer?.cancel();
    timerSeconds = minutes * 60;
    feedback = 'Timer auf $minutes Minuten gestellt.';
    _startTimerTicker();
    notifyListeners();
    await _speak(feedback);
  }

  void _startTimerTicker() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (timerSeconds <= 1) {
        timerSeconds = 0;
        timer.cancel();
        feedback = 'Der Timer ist abgelaufen.';
        unawaited(SystemSound.play(SystemSoundType.alert));
        unawaited(_speak(feedback));
      } else {
        timerSeconds--;
      }
      notifyListeners();
    });
  }

  Future<void> _readCurrentStep() async {
    final current = recipe;
    if (current == null || current.steps.isEmpty) return;
    await _speak('Schritt ${stepIndex + 1}. ${current.steps[stepIndex]}');
  }

  Future<void> _speak(String text) async {
    await _tts.setLanguage('de-DE');
    await _tts.setSpeechRate(0.48);
    await _tts.speak(text);
  }

  Future<void> handleCommand(String text, double confidence) async {
    final command = text.toLowerCase().trim();
    if (command.isEmpty) return;
    recognizedText = text;

    if (confidence > 0 && confidence < 0.35) {
      feedback =
          'Meintest du „Zurück“? Sag bitte noch einmal, was ich tun soll.';
      notifyListeners();
      await _speak(feedback);
      return;
    }

    if (command.contains('zurück') ||
        command.contains('zurueck') ||
        command.contains('vorher')) {
      await previousStep();
    } else if (command.contains('wiederhol') ||
        command.contains('nochmal') ||
        command.contains('noch einmal')) {
      await repeatStep();
    } else if (command.contains('zutat') ||
        command.contains('einkauf') ||
        command.contains('was brauche')) {
      showIngredients();
      final ingredients = recipe?.ingredients.join(', ');
      if (ingredients != null) {
        await _speak('Die Zutaten sind: $ingredients.');
      }
    } else if (command.contains('timer')) {
      final minutes = _parseMinutes(command);
      if (minutes == null) {
        feedback = 'Wie viele Minuten soll der Timer laufen?';
        notifyListeners();
        await _speak(feedback);
      } else {
        await startTimer(minutes);
      }
    } else if (command.contains('pause') ||
        command.contains('stopp') ||
        command.contains('stop')) {
      if (!isPaused) await togglePause();
    } else if (command.contains('fortsetzen') || command.contains('weiter')) {
      if (isPaused) {
        await togglePause();
      } else {
        await nextStep();
      }
    } else if (await _selectRecipeFromCommand(command)) {
      return;
    } else {
      feedback = 'Das habe ich nicht verstanden. Sag zum Beispiel „Weiter“, „Zurück“ oder „Timer fünf Minuten“. ';
      notifyListeners();
      await _speak(feedback);
      return;
    }
  }

  Future<bool> _selectRecipeFromCommand(String command) async {
    final index = _findRecipeIndex(command);
    if (index == null) return false;
    await selectRecipe(index);
    return true;
  }

  int? _findRecipeIndex(String command) {
    for (var index = 0; index < recipes.length; index++) {
      final number = switch (index + 1) {
        1 => 'eins',
        2 => 'zwei',
        3 => 'drei',
        _ => '${index + 1}',
      };
      if (command.contains(recipes[index].name.toLowerCase()) ||
          command.contains('rezept $number') ||
          command.contains('rezept ${index + 1}')) {
        return index;
      }
    }
    return null;
  }

  int? _parseMinutes(String command) {
    final digit = RegExp(r'\d+').firstMatch(command);
    if (digit != null) return int.tryParse(digit.group(0)!);
    const numbers = <String, int>{
      'eine': 1,
      'einer': 1,
      'ein': 1,
      'zwei': 2,
      'drei': 3,
      'vier': 4,
      'fünf': 5,
      'fuenf': 5,
      'sechs': 6,
      'sieben': 7,
      'acht': 8,
      'neun': 9,
      'zehn': 10,
      'elf': 11,
      'zwölf': 12,
      'zwoelf': 12,
      'fünfzehn': 15,
      'fuenfzehn': 15,
      'zwanzig': 20,
      'dreißig': 30,
      'dreissig': 30,
    };
    for (final entry in numbers.entries) {
      if (command.contains(entry.key)) return entry.value;
    }
    return null;
  }

  String get formattedTimer {
    final minutes = (timerSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (timerSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_speech.cancel());
    unawaited(_tts.stop());
    super.dispose();
  }
}

class KitchenHomePage extends StatelessWidget {
  const KitchenHomePage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Consumer<KitchenController>(
        builder: (context, kitchen, _) {
          if (kitchen.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }
          return CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                    Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: const Color(0xFFE7EBDD),
                            borderRadius: BorderRadius.circular(15),
                          ),
                          child: const Icon(
                            Icons.restaurant_menu,
                            color: _green,
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Text(
                          'Küchenstimme',
                          style: TextStyle(
                            color: _ink,
                            fontSize: 21,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          tooltip: 'Hilfe und Sprachbefehle',
                          onPressed: () {
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const SpeechHelpPage(),
                              ),
                            );
                          },
                          icon: const Icon(Icons.help_outline_rounded),
                          color: _green,
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.white,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 30),
                    const Text(
                      'Was kochen wir?',
                      style: TextStyle(
                        color: _ink,
                        fontSize: 29,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.8,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Wähle ein Rezept und lass dich Schritt für Schritt begleiten.',
                      style: TextStyle(
                        color: Color(0xFF71766F),
                        fontSize: 14,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 18),
                    _HomeVoiceCard(
                      kitchen: kitchen,
                      onFinalResult: (text, confidence) async {
                        final selected = await kitchen.selectRecipeFromSpeech(
                          text,
                          confidence,
                        );
                        if (selected && context.mounted) {
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const RecipeCookingPage(),
                            ),
                          );
                        }
                      },
                    ),
                    const SizedBox(height: 22),
                    ...List.generate(
                      kitchen.recipes.length,
                      (index) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _RecipeListTile(
                          recipe: kitchen.recipes[index],
                          onTap: () {
                            kitchen.openRecipe(index);
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const RecipeCookingPage(),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ]),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

class _HomeVoiceCard extends StatelessWidget {
  const _HomeVoiceCard({required this.kitchen, required this.onFinalResult});

  final KitchenController kitchen;
  final Future<void> Function(String text, double confidence) onFinalResult;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
    decoration: BoxDecoration(
      color: const Color(0xFFE9EDE3),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                kitchen.isListening ? 'Ich höre zu …' : 'Rezept ansagen',
                style: const TextStyle(
                  color: _ink,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                kitchen.recognizedText.isNotEmpty
                    ? '„${kitchen.recognizedText}“'
                    : 'Zum Beispiel: „Cremige Tomatenpasta“',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF687168),
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filled(
          tooltip: kitchen.isListening
              ? 'Spracherkennung beenden'
              : 'Rezept per Sprache auswählen',
          onPressed: () =>
              kitchen.toggleListening(onFinalResult: onFinalResult),
          icon: Icon(kitchen.isListening ? Icons.mic : Icons.mic_none_rounded),
          style: IconButton.styleFrom(
            backgroundColor: kitchen.isListening
                ? const Color(0xFFBB5747)
                : _green,
            foregroundColor: Colors.white,
          ),
        ),
      ],
    ),
  );
}

class _RecipeListTile extends StatelessWidget {
  const _RecipeListTile({required this.recipe, required this.onTap});

  final Recipe recipe;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    borderRadius: BorderRadius.circular(20),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Row(
          children: [
            Container(
              width: 66,
              height: 66,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xFFF4F1E9),
                borderRadius: BorderRadius.circular(17),
              ),
              child: Text(recipe.icon, style: const TextStyle(fontSize: 34)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    recipe.name,
                    style: const TextStyle(
                      color: _ink,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    recipe.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF777D74),
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    '${recipe.duration} Min. · ${recipe.steps.length} Schritte',
                    style: const TextStyle(
                      color: _green,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right_rounded, color: _green),
          ],
        ),
      ),
    ),
  );
}

class SpeechHelpPage extends StatelessWidget {
  const SpeechHelpPage({super.key});

  static const _commands = <(IconData, String, String)>[
    (
      Icons.restaurant_menu_rounded,
      'Rezept auswählen',
      'Sage den Rezeptnamen, zum Beispiel „Cremige Tomatenpasta“, oder „Rezept zwei“.',
    ),
    (
      Icons.arrow_forward_rounded,
      'Weiter',
      'Zum nächsten Zubereitungsschritt.',
    ),
    (Icons.arrow_back_rounded, 'Zurück', 'Zum vorherigen Zubereitungsschritt.'),
    (
      Icons.replay_rounded,
      'Nochmal',
      'Liest den aktuellen Schritt erneut vor.',
    ),
    (
      Icons.menu_book_rounded,
      'Zutaten',
      'Zeigt die Zutaten des ausgewählten Rezepts.',
    ),
    (
      Icons.timer_outlined,
      'Timer fünf Minuten',
      'Startet einen Timer. Die Zeit kann zwischen 1 und 240 Minuten liegen.',
    ),
    (
      Icons.pause_rounded,
      'Pause',
      'Pausiert die gesprochene Anleitung. Mit „Weiter“ geht es weiter.',
    ),
  ];

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: IconButton(
        tooltip: 'Zurück',
        onPressed: () => Navigator.of(context).pop(),
        icon: const Icon(Icons.arrow_back_rounded),
      ),
      title: const Text('Hilfe und Sprachbefehle'),
      titleTextStyle: const TextStyle(
        color: _ink,
        fontSize: 18,
        fontWeight: FontWeight.w800,
      ),
      backgroundColor: _cream,
    ),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      children: [
        const Text(
          'Sag einfach, was du brauchst.',
          style: TextStyle(
            color: _ink,
            fontSize: 23,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 7),
        const Text(
          'Tippe auf das Mikrofon und nenne einen Befehl. Auf der Startseite '
          'kannst du ein Rezept per Namen oder Nummer auswählen.',
          style: TextStyle(
            color: Color(0xFF71766F),
            fontSize: 14,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 18),
        ..._commands.map(
          (command) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Container(
              padding: const EdgeInsets.all(15),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(17),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(command.$1, color: _green, size: 22),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          command.$2,
                          style: const TextStyle(
                            color: _ink,
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          command.$3,
                          style: const TextStyle(
                            color: Color(0xFF71766F),
                            fontSize: 12,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            color: const Color(0xFFE9EDE3),
            borderRadius: BorderRadius.circular(17),
          ),
          child: const Text(
            'Du kannst alle Funktionen auch jederzeit über die Symbole in der '
            'Kochansicht bedienen. Die Spracherkennung benötigt '
            'Mikrofonzugriff und eine deutsche Spracherkennung auf deinem Gerät.',
            style: TextStyle(
              color: Color(0xFF59645A),
              fontSize: 12,
              height: 1.45,
            ),
          ),
        ),
      ],
    ),
  );
}

class RecipeCookingPage extends StatelessWidget {
  const RecipeCookingPage({super.key});

  @override
  Widget build(BuildContext context) => Consumer<KitchenController>(
    builder: (context, kitchen, _) {
      final recipe = kitchen.recipe;
      if (recipe == null) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }

      return Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 18, 8),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Zur Rezeptliste',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.arrow_back_rounded),
                      color: _ink,
                    ),
                    Expanded(
                      child: Text(
                        recipe.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: _ink,
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Letzte Aktion rückgängig',
                      onPressed: kitchen.canUndo ? kitchen.undo : null,
                      icon: const Icon(Icons.undo_rounded),
                      color: _green,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                  children: [
                    Row(
                      children: [
                        Text(
                          'SCHRITT ${kitchen.stepIndex + 1}',
                          style: const TextStyle(
                            color: _green,
                            fontSize: 11,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.3,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '${kitchen.stepIndex + 1} / ${recipe.steps.length}',
                          style: const TextStyle(
                            color: Color(0xFF888C83),
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(24),
                      child: LinearProgressIndicator(
                        value: (kitchen.stepIndex + 1) / recipe.steps.length,
                        minHeight: 5,
                        backgroundColor: const Color(0xFFE6E8E1),
                        color: _green,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(22),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x0C27362D),
                            blurRadius: 18,
                            offset: Offset(0, 7),
                          ),
                        ],
                      ),
                      child: Text(
                        recipe.steps[kitchen.stepIndex],
                        style: const TextStyle(
                          color: _ink,
                          fontSize: 20,
                          height: 1.55,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (kitchen.timerSeconds > 0) ...[
                      const SizedBox(height: 16),
                      _TimerCard(kitchen: kitchen),
                    ],
                    if (kitchen.ingredientsVisible) ...[
                      const SizedBox(height: 16),
                      _InlineIngredients(recipe: recipe),
                    ],
                    const SizedBox(height: 26),
                    _CookingControls(kitchen: kitchen),
                  ],
                ),
              ),
              _MicrophoneDock(kitchen: kitchen),
            ],
          ),
        ),
      );
    },
  );
}

class _CookingControls extends StatelessWidget {
  const _CookingControls({required this.kitchen});

  final KitchenController kitchen;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      _IconControl(
        icon: Icons.arrow_back_rounded,
        label: 'Vorheriger Schritt',
        onPressed: kitchen.previousStep,
      ),
      _IconControl(
        icon: kitchen.isPaused ? Icons.play_arrow_rounded : Icons.stop_rounded,
        label: kitchen.isPaused ? 'Anleitung starten' : 'Anleitung stoppen',
        prominent: true,
        onPressed: kitchen.togglePause,
      ),
      _IconControl(
        icon: Icons.arrow_forward_rounded,
        label: 'Nächster Schritt',
        onPressed: kitchen.nextStep,
      ),
      _IconControl(
        icon: Icons.replay_rounded,
        label: 'Schritt wiederholen',
        onPressed: kitchen.repeatStep,
      ),
      _IconControl(
        icon: Icons.timer_outlined,
        label: 'Timer einstellen',
        onPressed: () => _showTimerDialog(context, kitchen),
      ),
      _IconControl(
        icon: Icons.menu_book_rounded,
        label: 'Zutaten anzeigen',
        onPressed: kitchen.showIngredients,
      ),
    ],
  );
}

class _IconControl extends StatelessWidget {
  const _IconControl({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.prominent = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool prominent;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: IconButton(
        tooltip: label,
        onPressed: onPressed,
        icon: Icon(icon),
        iconSize: 21,
        style: IconButton.styleFrom(
          backgroundColor: prominent ? _green : Colors.white,
          foregroundColor: prominent ? Colors.white : _ink,
          minimumSize: const Size(44, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
          ),
        ),
      ),
    ),
  );
}

class _MicrophoneDock extends StatelessWidget {
  const _MicrophoneDock({required this.kitchen});

  final KitchenController kitchen;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(18, 8, 18, 14),
    decoration: const BoxDecoration(
      color: _cream,
      border: Border(top: BorderSide(color: Color(0xFFE9E7DF))),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          kitchen.recognizedText.isNotEmpty
              ? '„${kitchen.recognizedText}“'
              : kitchen.isListening
              ? 'Ich höre zu …'
              : kitchen.feedback,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Color(0xFF71766F), fontSize: 12),
        ),
        const SizedBox(height: 8),
        IconButton.filled(
          tooltip: kitchen.isListening
              ? 'Spracherkennung beenden'
              : 'Sprachbefehl geben',
          onPressed: kitchen.toggleListening,
          icon: Icon(kitchen.isListening ? Icons.mic : Icons.mic_none_rounded),
          iconSize: 28,
          style: IconButton.styleFrom(
            backgroundColor: kitchen.isListening
                ? const Color(0xFFBB5747)
                : _green,
            foregroundColor: Colors.white,
            fixedSize: const Size(62, 62),
          ),
        ),
      ],
    ),
  );
}

class _InlineIngredients extends StatelessWidget {
  const _InlineIngredients({required this.recipe});

  final Recipe recipe;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: const Color(0xFFE9EDE3),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Zutaten für ${recipe.name}',
          style: const TextStyle(
            color: _ink,
            fontSize: 15,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 8),
        ...recipe.ingredients.map(
          (ingredient) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Text(
              '·  $ingredient',
              style: const TextStyle(color: Color(0xFF59645A), fontSize: 13),
            ),
          ),
        ),
      ],
    ),
  );
}

class _TimerCard extends StatelessWidget {
  const _TimerCard({required this.kitchen});

  final KitchenController kitchen;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 14),
    decoration: BoxDecoration(
      color: const Color(0xFFF4E9DD),
      borderRadius: BorderRadius.circular(18),
    ),
    child: Row(
      children: [
        const Icon(Icons.timer_outlined, color: Color(0xFFAA7043)),
        const SizedBox(width: 11),
        const Expanded(
          child: Text(
            'Küchentimer',
            style: TextStyle(
              color: _ink,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Text(
          kitchen.formattedTimer,
          style: const TextStyle(
            color: _ink,
            fontFeatures: [FontFeature.tabularFigures()],
            fontSize: 20,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    ),
  );
}

Future<void> _showTimerDialog(
  BuildContext context,
  KitchenController kitchen,
) async {
  final minutes = await showDialog<int>(
    context: context,
    builder: (_) => const _TimerDialog(),
  );
  if (minutes != null) await kitchen.startTimer(minutes);
}

class _TimerDialog extends StatefulWidget {
  const _TimerDialog();

  @override
  State<_TimerDialog> createState() => _TimerDialogState();
}

class _TimerDialogState extends State<_TimerDialog> {
  final TextEditingController _minutesController = TextEditingController();
  String? _errorText;

  void _startTimer() {
    final minutes = int.tryParse(_minutesController.text);
    if (minutes == null || minutes < 1 || minutes > 240) {
      setState(() {
        _errorText = 'Bitte gib eine Zeit zwischen 1 und 240 Minuten ein.';
      });
      return;
    }
    Navigator.of(context).pop(minutes);
  }

  @override
  void dispose() {
    _minutesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Timer einstellen'),
    content: TextField(
      controller: _minutesController,
      autofocus: true,
      keyboardType: TextInputType.number,
      onChanged: (_) {
        if (_errorText != null) setState(() => _errorText = null);
      },
      decoration: InputDecoration(
        labelText: 'Minuten',
        hintText: 'z. B. 5',
        suffixText: 'Min.',
        errorText: _errorText,
      ),
    ),
    actions: [
      IconButton(
        tooltip: 'Abbrechen',
        onPressed: () => Navigator.of(context).pop(),
        icon: const Icon(Icons.close_rounded),
      ),
      IconButton.filled(
        tooltip: 'Timer starten',
        onPressed: _startTimer,
        icon: const Icon(Icons.play_arrow_rounded),
      ),
    ],
  );
}
