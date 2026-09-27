import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

final notifications = FlutterLocalNotificationsPlugin();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tz.initializeTimeZones();

  const androidSettings =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const initSettings = InitializationSettings(android: androidSettings);

  await notifications.initialize(initSettings);

  await notifications
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.requestNotificationsPermission();

  await AppDb.instance.database;
  runApp(const SchoolDiaryApp());
}

class SchoolDiaryApp extends StatelessWidget {
  const SchoolDiaryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Школьный дневник',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      home: const HomePage(),
    );
  }
}

class Lesson {
  final int? id;
  final int weekday;
  final int lessonNo;
  final String subject;

  const Lesson({
    this.id,
    required this.weekday,
    required this.lessonNo,
    required this.subject,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'weekday': weekday,
        'lesson_no': lessonNo,
        'subject': subject,
      };

  factory Lesson.fromMap(Map<String, Object?> map) => Lesson(
        id: map['id'] as int?,
        weekday: map['weekday'] as int,
        lessonNo: map['lesson_no'] as int,
        subject: map['subject'] as String,
      );
}

class Homework {
  final int? id;
  final String subject;
  final String text;
  final String assignedDate;
  final String dueDate;
  final int done;

  const Homework({
    this.id,
    required this.subject,
    required this.text,
    required this.assignedDate,
    required this.dueDate,
    this.done = 0,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'subject': subject,
        'text': text,
        'assigned_date': assignedDate,
        'due_date': dueDate,
        'done': done,
      };

  factory Homework.fromMap(Map<String, Object?> map) => Homework(
        id: map['id'] as int?,
        subject: map['subject'] as String,
        text: map['text'] as String,
        assignedDate: map['assigned_date'] as String,
        dueDate: map['due_date'] as String,
        done: map['done'] as int,
      );
}

class AppDb {
  AppDb._();
  static final instance = AppDb._();

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;

    final dbPath = await getDatabasesPath();

    _db = await openDatabase(
      p.join(dbPath, 'school_diary.db'),
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE lessons(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            weekday INTEGER NOT NULL,
            lesson_no INTEGER NOT NULL,
            subject TEXT NOT NULL
          )
        ''');

        await db.execute('''
          CREATE TABLE homework(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            subject TEXT NOT NULL,
            text TEXT NOT NULL,
            assigned_date TEXT NOT NULL,
            due_date TEXT NOT NULL,
            done INTEGER NOT NULL DEFAULT 0
          )
        ''');
      },
    );

    return _db!;
  }

  Future<List<Lesson>> lessonsForWeekday(int weekday) async {
    final db = await database;
    final rows = await db.query(
      'lessons',
      where: 'weekday = ?',
      whereArgs: [weekday],
      orderBy: 'lesson_no ASC',
    );
    return rows.map(Lesson.fromMap).toList();
  }

  Future<List<Lesson>> allLessons() async {
    final db = await database;
    final rows = await db.query('lessons', orderBy: 'weekday, lesson_no');
    return rows.map(Lesson.fromMap).toList();
  }

  Future<void> upsertLesson({
    required int weekday,
    required int lessonNo,
    required String subject,
  }) async {
    final db = await database;

    final existing = await db.query(
      'lessons',
      where: 'weekday = ? AND lesson_no = ?',
      whereArgs: [weekday, lessonNo],
      limit: 1,
    );

    if (subject.trim().isEmpty) {
      await db.delete(
        'lessons',
        where: 'weekday = ? AND lesson_no = ?',
        whereArgs: [weekday, lessonNo],
      );
      return;
    }

    if (existing.isEmpty) {
      final data = Lesson(
        weekday: weekday,
        lessonNo: lessonNo,
        subject: subject.trim(),
      ).toMap()
        ..remove('id');
      await db.insert('lessons', data);
    } else {
      await db.update(
        'lessons',
        {'subject': subject.trim()},
        where: 'weekday = ? AND lesson_no = ?',
        whereArgs: [weekday, lessonNo],
      );
    }
  }

  Future<DateTime?> nextLessonDate({
    required String subject,
    required DateTime from,
  }) async {
    final lessons = await allLessons();

    final weekdays = lessons
        .where(
          (lesson) =>
              lesson.subject.trim().toLowerCase() ==
              subject.trim().toLowerCase(),
        )
        .map((lesson) => lesson.weekday)
        .toSet();

    if (weekdays.isEmpty) return null;

    for (int offset = 1; offset <= 14; offset++) {
      final candidate = DateTime(from.year, from.month, from.day)
          .add(Duration(days: offset));
      if (weekdays.contains(candidate.weekday)) return candidate;
    }

    return null;
  }

  Future<int> addHomework(Homework homework) async {
    final db = await database;
    final data = homework.toMap()..remove('id');
    return db.insert('homework', data);
  }

  Future<List<Homework>> homeworkForDate(DateTime date) async {
    final db = await database;
    final rows = await db.query(
      'homework',
      where: 'due_date = ?',
      whereArgs: [_dateKey(date)],
      orderBy: 'subject',
    );
    return rows.map(Homework.fromMap).toList();
  }

  Future<void> toggleHomework(Homework homework, bool done) async {
    final db = await database;
    await db.update(
      'homework',
      {'done': done ? 1 : 0},
      where: 'id = ?',
      whereArgs: [homework.id],
    );

    if (done && homework.id != null) {
      await notifications.cancel(10000 + homework.id!);
    }
  }

  static String _dateKey(DateTime date) =>
      DateFormat('yyyy-MM-dd').format(date);
}

String weekdayName(int weekday) {
  const names = {
    1: 'Понедельник',
    2: 'Вторник',
    3: 'Среда',
    4: 'Четверг',
    5: 'Пятница',
    6: 'Суббота',
    7: 'Воскресенье',
  };
  return names[weekday]!;
}

String prettyDate(DateTime date) => DateFormat('dd.MM.yyyy').format(date);

bool sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  DateTime selectedDate = DateTime.now();

  void refresh() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final date = DateTime(
      selectedDate.year,
      selectedDate.month,
      selectedDate.day,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Школьный дневник'),
        actions: [
          IconButton(
            tooltip: 'Расписание',
            icon: const Icon(Icons.calendar_month),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SchedulePage()),
              );
              refresh();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          DateStrip(
            selected: date,
            onChanged: (newDate) {
              setState(() => selectedDate = newDate);
            },
          ),
          Expanded(
            child: FutureBuilder<List<Lesson>>(
              future: AppDb.instance.lessonsForWeekday(date.weekday),
              builder: (context, lessonSnapshot) {
                if (!lessonSnapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                final lessons = lessonSnapshot.data!;

                if (lessons.isEmpty) {
                  return Center(
                    child: FilledButton.icon(
                      onPressed: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const SchedulePage(),
                          ),
                        );
                        refresh();
                      },
                      icon: const Icon(Icons.edit_calendar),
                      label: const Text('Заполнить расписание'),
                    ),
                  );
                }

                return FutureBuilder<List<Homework>>(
                  future: AppDb.instance.homeworkForDate(date),
                  builder: (context, homeworkSnapshot) {
                    final homework =
                        homeworkSnapshot.data ?? const <Homework>[];

                    return ListView(
                      padding: const EdgeInsets.all(12),
                      children: [
                        Text(
                          '${weekdayName(date.weekday)}, ${prettyDate(date)}',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 12),
                        ...lessons.map((lesson) {
                          final subjectHomework = homework
                              .where(
                                (item) =>
                                    item.subject.trim().toLowerCase() ==
                                    lesson.subject.trim().toLowerCase(),
                              )
                              .toList();

                          return LessonCard(
                            lesson: lesson,
                            date: date,
                            homework: subjectHomework,
                            onChanged: refresh,
                          );
                        }),
                      ],
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class LessonCard extends StatelessWidget {
  final Lesson lesson;
  final DateTime date;
  final List<Homework> homework;
  final VoidCallback onChanged;

  const LessonCard({
    super.key,
    required this.lesson,
    required this.date,
    required this.homework,
    required this.onChanged,
  });

  Future<void> addHomework(BuildContext context) async {
    final nextDate = await AppDb.instance.nextLessonDate(
      subject: lesson.subject,
      from: date,
    );

    if (!context.mounted) return;

    if (nextDate == null) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Следующий урок не найден'),
          content: Text(
            'Добавь предмет "${lesson.subject}" в расписание на другой день.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('ОК'),
            ),
          ],
        ),
      );
      return;
    }

    final controller = TextEditingController();

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${lesson.subject}: домашнее задание'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Следующий урок: ${weekdayName(nextDate.weekday)}, '
              '${prettyDate(nextDate)}',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Домашнее задание',
                hintText: 'Например: стр. 42, № 5–8',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton.icon(
            onPressed: () {
              final text = controller.text.trim();
              if (text.isNotEmpty) {
                Navigator.pop(context, text);
              }
            },
            icon: const Icon(Icons.save),
            label: const Text('Сохранить'),
          ),
        ],
      ),
    );

    controller.dispose();

    if (result == null || result.trim().isEmpty) return;

    final id = await AppDb.instance.addHomework(
      Homework(
        subject: lesson.subject,
        text: result.trim(),
        assignedDate: AppDb._dateKey(date),
        dueDate: AppDb._dateKey(nextDate),
      ),
    );

    await scheduleReminder(
      id: id,
      subject: lesson.subject,
      text: result.trim(),
      dueDate: nextDate,
    );

    onChanged();

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Домашнее задание сохранено на ${prettyDate(nextDate)}',
          ),
        ),
      );
    }
  }

  Future<void> finishLesson(BuildContext context) async {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${lesson.subject}: урок отмечен как завершённый',
        ),
      ),
    );
  }

  Future<void> scheduleReminder({
    required int id,
    required String subject,
    required String text,
    required DateTime dueDate,
  }) async {
    final reminderDate = DateTime(
      dueDate.year,
      dueDate.month,
      dueDate.day,
      18,
    ).subtract(const Duration(days: 1));

    if (reminderDate.isBefore(DateTime.now())) return;

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'homework_channel',
        'Домашние задания',
        channelDescription: 'Напоминания о домашних заданиях',
        importance: Importance.high,
        priority: Priority.high,
      ),
    );

    await notifications.zonedSchedule(
      10000 + id,
      'Завтра $subject',
      text,
      tz.TZDateTime.from(reminderDate, tz.local),
      details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isToday = sameDay(date, DateTime.now());

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(child: Text('${lesson.lessonNo}')),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    lesson.subject,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => addHomework(context),
                icon: const Icon(Icons.edit_note),
                label: const Text('Записать домашнее задание'),
              ),
            ),
            if (isToday) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => finishLesson(context),
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('Урок окончен'),
                ),
              ),
            ],
            if (homework.isNotEmpty) ...[
              const SizedBox(height: 14),
              const Divider(),
              const SizedBox(height: 4),
              const Text(
                'Домашнее задание:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              ...homework.map(
                (item) => CheckboxListTile(
                  value: item.done == 1,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(
                    item.text,
                    style: TextStyle(
                      decoration: item.done == 1
                          ? TextDecoration.lineThrough
                          : null,
                    ),
                  ),
                  subtitle: const Text('К этому уроку'),
                  onChanged: (value) async {
                    await AppDb.instance.toggleHomework(
                      item,
                      value ?? false,
                    );
                    onChanged();
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class DateStrip extends StatelessWidget {
  final DateTime selected;
  final ValueChanged<DateTime> onChanged;

  const DateStrip({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final monday = selected.subtract(
      Duration(days: selected.weekday - 1),
    );

    return SizedBox(
      height: 88,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(8),
        itemCount: 7,
        itemBuilder: (context, index) {
          final day = monday.add(Duration(days: index));
          final active = sameDay(day, selected);

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ChoiceChip(
              selected: active,
              onSelected: (_) => onChanged(day),
              label: SizedBox(
                width: 54,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(weekdayName(day.weekday).substring(0, 2)),
                    Text(
                      '${day.day}',
                      style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class SchedulePage extends StatefulWidget {
  const SchedulePage({super.key});

  @override
  State<SchedulePage> createState() => _SchedulePageState();
}

class _SchedulePageState extends State<SchedulePage> {
  int weekday = DateTime.monday;
  static const lessonCount = 8;

  final controllers = List.generate(
    lessonCount,
    (_) => TextEditingController(),
  );

  @override
  void initState() {
    super.initState();
    loadDay();
  }

  Future<void> loadDay() async {
    final lessons = await AppDb.instance.lessonsForWeekday(weekday);

    for (final controller in controllers) {
      controller.clear();
    }

    for (final lesson in lessons) {
      if (lesson.lessonNo >= 1 && lesson.lessonNo <= lessonCount) {
        controllers[lesson.lessonNo - 1].text = lesson.subject;
      }
    }

    if (mounted) setState(() {});
  }

  Future<void> saveDay() async {
    for (int i = 0; i < lessonCount; i++) {
      await AppDb.instance.upsertLesson(
        weekday: weekday,
        lessonNo: i + 1,
        subject: controllers[i].text,
      );
    }

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Расписание сохранено')),
    );
  }

  @override
  void dispose() {
    for (final controller in controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Расписание'),
        actions: [
          IconButton(
            onPressed: saveDay,
            icon: const Icon(Icons.save),
          ),
        ],
      ),
      body: Column(
        children: [
          SizedBox(
            height: 58,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(8),
              children: [
                for (int day = 1; day <= 7; day++)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: ChoiceChip(
                      selected: weekday == day,
                      label: Text(weekdayName(day).substring(0, 2)),
                      onSelected: (_) async {
                        setState(() => weekday = day);
                        await loadDay();
                      },
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: lessonCount,
              itemBuilder: (context, index) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: TextField(
                    controller: controllers[index],
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      labelText: '${index + 1} урок',
                      hintText: 'Название предмета',
                    ),
                  ),
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: saveDay,
                  icon: const Icon(Icons.save),
                  label: const Text('Сохранить расписание'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
