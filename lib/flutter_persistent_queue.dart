///
library flutter_persistent_queue;

import 'dart:async' show Completer;

import 'package:localstorage/localstorage.dart' show LocalStorage;

import './classes/queue_buffer.dart' show QueueBuffer;
import './classes/queue_event.dart' show QueueEvent, QueueEventType;
import './typedefs/typedefs.dart' show OnFlush, StorageFunc;

///
class PersistentQueue {
  ///
  factory PersistentQueue(String filename,
      {OnFlush onFlush,
      int flushAt = 100,
      int maxLength,
      bool noPersist = false,
      Duration flushTimeout = const Duration(minutes: 5)}) {
    if (_cache.containsKey(filename)) return _cache[filename];

    final persistentQueue = PersistentQueue._internal(filename,
        onFlush: onFlush,
        flushAt: flushAt,
        flushTimeout: flushTimeout,
        maxLength: maxLength,
        noPersist: noPersist);
    _cache[filename] = persistentQueue;
    return persistentQueue;
  }

  PersistentQueue._internal(this.filename,
      {this.onFlush,
      this.flushAt,
      this.flushTimeout,
      int maxLength,
      bool noPersist})
      : _maxLength = maxLength ?? flushAt * 5 {
    const type = QueueEventType.RELOAD;
    final completer = Completer<bool>();
    _ready = completer.future;
    _buffer = QueueBuffer<QueueEvent>(_onData);
    _buffer.push(QueueEvent(type, noPersist: noPersist, completer: completer));
  }

  ///
  final String filename;

  ///
  final OnFlush onFlush;

  ///
  final int flushAt;

  ///
  final Duration flushTimeout;

  // max number of queued items, either in-memory or on fs
  final int _maxLength;

  static final _cache = <String, PersistentQueue>{};

  QueueBuffer<QueueEvent> _buffer;
  Exception _errorState;
  Future<bool> _ready;
  DateTime _deadline;
  int _len = 0;

  /// the current number of elements in non-volatile storage
  int get length => _len;

  /// the current number of in-memory elements
  int get bufferLength => _buffer.length;

  ///
  Future<bool> get ready => _ready;

  ///
  Future<int> get futureLength {
    _checkErrorState();
    const type = QueueEventType.LENGTH;
    final completer = Completer<int>();
    _buffer.push(QueueEvent(type, completer: completer));
    return completer.future;
  }

  ///
  Future<void> push(Map<String, dynamic> item) {
    _checkOverflow();
    _checkErrorState();
    const type = QueueEventType.PUSH;
    final completer = Completer<void>();
    _buffer.push(QueueEvent(type, item: item, completer: completer));
    return completer.future;
  }

  /// push a flush instruction to the end of the event buffer
  Future<void> flush([OnFlush onFlush]) {
    _checkErrorState();
    const type = QueueEventType.FLUSH;
    final completer = Completer<void>();
    _buffer.push(QueueEvent(type, onFlush: onFlush, completer: completer));
    return completer.future;
  }

  ///
  Future<List<Map<String, dynamic>>> toList({bool growable = true}) {
    _checkErrorState();
    const type = QueueEventType.LIST;
    final completer = Completer<List<Map<String, dynamic>>>();
    _buffer.push(QueueEvent(type, growable: growable, completer: completer));
    return completer.future;
  }

  /// deallocates queue resources
  Future<void> destroy({bool noPersist = false}) {
    const type = QueueEventType.DESTROY;
    final completer = Completer<void>();
    _buffer.push(QueueEvent(type, noPersist: noPersist, completer: completer));
    return completer.future;
  }

  // buffer calls onData every time it's ready to process a new [_Event] and
  // then an event handler method gets executed according to [_Event.type]
  Future<void> _onData(QueueEvent event) async {
    if (event.type == QueueEventType.FLUSH) {
      await _onFlush(event);
    } else if (event.type == QueueEventType.DESTROY) {
      await _onDestroy(event);
    } else if (event.type == QueueEventType.LENGTH) {
      _onLength(event);
    } else if (event.type == QueueEventType.LIST) {
      await _onList(event);
    } else if (event.type == QueueEventType.PUSH) {
      await _onPush(event);
    } else if (event.type == QueueEventType.RELOAD) {
      await _onReload(event);
    }
  }

  Future<void> _onPush(QueueEvent event) async {
    try {
      await _write(event.item);
      if (_len >= flushAt || _expiredTimeout()) {
        await _onFlush(event);
      } else {
        event.completer.complete();
      }
    } catch (e, s) {
      event.completer.completeError(e, s);
    }
  }

  // should only be scheduled once at construction-time, first event to run
  Future<void> _onReload(QueueEvent event) async {
    try {
      _errorState = null;
      _len = 0;
      if (event.noPersist) {
        await _reset();
      } else {
        await _file((LocalStorage storage) async {
          while (await storage.getItem('$_len') != null) ++_len;
        });
      }
      event.completer.complete(true);
    } catch (e) {
      _errorState = Exception(e.toString());
      event.completer.complete(false);
    }
  }

  Future<void> _onList(QueueEvent event) async {
    try {
      List<Map<String, dynamic>> list = await _toList();
      if (event.growable) {
        list = List<Map<String, dynamic>>.from(list, growable: true);
      }
      event.completer.complete(list);
    } catch (e, s) {
      event.completer.completeError(e, s);
    }
  }

  Future<void> _onFlush(QueueEvent event) async {
    try {
      // run optional flush action
      final OnFlush _onFlush = event.onFlush ?? onFlush;
      if (_onFlush != null) await _onFlush(await _toList());

      // clear on success
      await _reset();

      // acknowledge
      event.completer.complete();
    } catch (e, s) {
      event.completer.completeError(e, s);
    }
  }

  Future<void> _onDestroy(QueueEvent event) async {
    try {
      if (event.noPersist) await _reset();
      await _buffer.destroy();
      _cache.remove(filename);
      _errorState = Exception('Queue Destroyed');
      event.completer.complete();
    } catch (e, s) {
      print(e.toString());
      event.completer.completeError(e, s);
    }
  }

  void _onLength(QueueEvent event) => event.completer.complete(_len);

  // should only be called by _onFlush, _onList, _onDestroy
  Future<List<Map<String, dynamic>>> _toList() async {
    if (_len == null || _len < 1) return [];
    final li = List<Map<String, dynamic>>(_len);
    await _file((LocalStorage storage) async {
      for (int k = 0; k < _len; ++k) {
        li[k] = await storage.getItem('$k') as Map<String, dynamic>;
      }
    });
    return li;
  }

  // should only be called by _onFlush, _onDestroy
  Future<void> _reset() async {
    await _file((LocalStorage storage) async {
      await storage.clear(); // hard clear a bit slow!!
      _len = 0;
    });
  }

  // should only be called by _onPush
  Future<void> _write(Map<String, dynamic> value) async {
    await _file((LocalStorage storage) async {
      await storage.setItem('$_len', value);
      if (++_len == 1) _resetDeadline();
    });
  }

  Future<void> _file(StorageFunc inputFunc) async {
    final storage = LocalStorage(filename);
    await storage.ready;
    await inputFunc(storage);
  }

  void _checkErrorState() {
    if (_errorState == null) return;
    throw Exception(_errorState);
  }

  void _checkOverflow() {
    if (_len + _buffer.length - 1 <= _maxLength) return;
    throw Exception('QueueOverflow');
  }

  void _resetDeadline() => _deadline = _nowUtc().add(flushTimeout);
  bool _expiredTimeout() => _deadline != null && _nowUtc().isAfter(_deadline);
  DateTime _nowUtc() => DateTime.now().toUtc();
}
