import 'package:flutter_test/flutter_test.dart';
import 'package:xiyuan_pocket/models/todo.dart';

void main() {
  test('待办优先级序列化保持', () {
    final todo = Todo(
      id: 'p1',
      title: '交作业',
      date: DateTime(2026, 10, 30),
      priority: 2,
    );
    final restored = Todo.fromJson(todo.toJson());
    expect(restored.priority, 2);
    expect(todo.copyWith(title: '改').priority, 2);
  });
}
