import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// RGBA バッファを複数 isolate で並列 PNG エンコードするプール。
///
/// タイル描画のホットパス (`MapViewModel.getTile`) で使う想定。
/// - 圧縮レベル 0（非圧縮）で CPU 時間を最小化
/// - spawn コストを償却するため worker はアイドル時も生かしたまま
/// - zero-copy を狙って `TransferableTypedData` で受け渡し
class PngEncoderPool {
  PngEncoderPool._();
  static final PngEncoderPool instance = PngEncoderPool._();

  static const int _workerCount = 3;

  final List<_Worker> _workers = <_Worker>[];
  int _rrIndex = 0;
  Future<void>? _initFuture;

  Future<void> _ensureInit() {
    final existing = _initFuture;
    if (existing != null) return existing;
    final future = _spawnAll();
    _initFuture = future;
    return future;
  }

  Future<void> _spawnAll() async {
    for (int i = 0; i < _workerCount; i++) {
      final worker = await _Worker.spawn();
      _workers.add(worker);
    }
  }

  /// RGBA (straight alpha) バッファを PNG バイト列に変換する。
  Future<Uint8List> encode(Uint8List rgba, int width, int height) async {
    await _ensureInit();
    final worker = _workers[_rrIndex];
    _rrIndex = (_rrIndex + 1) % _workers.length;
    return worker.encode(rgba, width, height);
  }
}

class _Worker {
  _Worker._(this._sendPort, this._responses);

  final SendPort _sendPort;
  final Stream<dynamic> _responses;

  int _nextId = 0;
  final Map<int, Completer<Uint8List>> _pending = <int, Completer<Uint8List>>{};

  static Future<_Worker> spawn() async {
    final receivePort = ReceivePort();
    await Isolate.spawn(_entryPoint, receivePort.sendPort);
    final broadcast = receivePort.asBroadcastStream();
    final sendPort = await broadcast.first as SendPort;
    final worker = _Worker._(sendPort, broadcast);
    worker._listen();
    return worker;
  }

  void _listen() {
    _responses.listen((dynamic message) {
      if (message is _EncodedResponse) {
        final completer = _pending.remove(message.id);
        if (completer != null) {
          if (message.error != null) {
            completer.completeError(message.error!);
          } else {
            completer.complete(message.png!);
          }
        }
      }
    });
  }

  Future<Uint8List> encode(Uint8List rgba, int width, int height) {
    final id = _nextId++;
    final completer = Completer<Uint8List>();
    _pending[id] = completer;
    final transferable = TransferableTypedData.fromList(<Uint8List>[rgba]);
    _sendPort.send(_EncodeRequest(
      id: id,
      transferable: transferable,
      width: width,
      height: height,
    ));
    return completer.future;
  }
}

class _EncodeRequest {
  const _EncodeRequest({
    required this.id,
    required this.transferable,
    required this.width,
    required this.height,
  });

  final int id;
  final TransferableTypedData transferable;
  final int width;
  final int height;
}

class _EncodedResponse {
  const _EncodedResponse._({
    required this.id,
    this.png,
    this.error,
  });

  factory _EncodedResponse.success(int id, Uint8List png) =>
      _EncodedResponse._(id: id, png: png);
  factory _EncodedResponse.failure(int id, Object error) =>
      _EncodedResponse._(id: id, error: error);

  final int id;
  final Uint8List? png;
  final Object? error;
}

void _entryPoint(SendPort mainSendPort) {
  final port = ReceivePort();
  mainSendPort.send(port.sendPort);
  port.listen((dynamic message) {
    if (message is _EncodeRequest) {
      try {
        final bytes = message.transferable.materialize().asUint8List();
        final image = img.Image.fromBytes(
          width: message.width,
          height: message.height,
          bytes: bytes.buffer,
          bytesOffset: bytes.offsetInBytes,
          order: img.ChannelOrder.rgba,
          numChannels: 4,
        );
        final png = img.encodePng(image, level: 0);
        mainSendPort.send(
          _EncodedResponse.success(message.id, Uint8List.fromList(png)),
        );
      } catch (e) {
        mainSendPort.send(_EncodedResponse.failure(message.id, e));
      }
    }
  });
}
