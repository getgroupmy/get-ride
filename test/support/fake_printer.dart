import 'package:get_ride/src/data/printer/printer_service.dart';

/// A printer that keeps what it was sent, or refuses the connection.
class FakePrinter implements PrinterSink {
  FakePrinter({this.refuse = false});
  bool refuse;
  final jobs = <String>[];
  bool open = false;

  @override
  Future<void> connect() async {
    if (refuse) throw const PrinterUnreachable();
    open = true;
  }

  @override
  Future<void> write(String payload) async => jobs.add(payload);

  @override
  Future<void> close() async => open = false;
}

class PrinterUnreachable implements Exception {
  const PrinterUnreachable();
  @override
  String toString() => 'Connection refused';
}
