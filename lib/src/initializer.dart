/// This file is a part of libmpv.dart (https://github.com/alexmercerind/libmpv.dart).
///
/// Copyright (c) 2022, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.

import 'dart:ffi';
import 'dart:async';
import 'dart:isolate';

import 'package:libmpv/generated/bindings.dart';

/// Late initialized [MPV] object from ffigen.
late MPV mpv;

/// Runs on separate isolate.
/// Calls [MPV.mpv_create] & [MPV.mpv_initialize] to create a new [mpv_handle].
/// Uses [MPV.mpv_wait_event] to wait for the next event & notifies through the passed [SendPort] as the argument.
///
/// First value sent through the [SendPort] is [SendPort] of the internal [ReceivePort].
/// Second value sent through the [SendPort] is raw address of the [Pointer] to [mpv_handle] created by the isolate.
/// Subsequent sent values are [Pointer] to [mpv_event].
///
void mainloop(SendPort port) async {
  /// Used to ensure that the last [mpv_event] is NOT reset to [mpv_event_id.MPV_EVENT_NONE] after waiting using [MPV.mpv_wait_event] again in the continuously running while loop.
  var completer = Completer();

  /// Used to x the confirmation messages from the main thread about successful receive of the sent event through [SendPort].
  /// Upon confirmation, the [Completer] is completed & we jump to next iteration of the while loop waiting with [MPV.mpv_wait_event].
  var receiver = ReceivePort();

  /// Send the [SendPort] of internal [ReceivePort].
  port.send(receiver.sendPort);

  /// Separately creating [MPV] object since isolates don't share variables.
  late MPV mpv;
  receiver.listen((message) {
    if (message is String) {
      /// Initializing the local [MPV] object.
      mpv = MPV(DynamicLibrary.open(message));
    }

    /// Notifying about the successful sending of the event & move onto next [MPV.mpv_wait_event] after completing the [Completer].
    completer.complete();
  });

  /// Waiting for [MPV] to be late initialized.
  await completer.future;

  /// Creating & initializing [mpv_handle].
  var handle = mpv.mpv_create();
  mpv.mpv_initialize(handle);

  /// Sending the address of the created [mpv_handle] & the [SendPort] of the [receivePort].
  /// Raw address is sent as [int] since we cannot transfer objects through Native Ports, only primatives.
  port.send(handle.address);

  /// Lookup for events & send to main thread through [SendPort].
  /// Ensuring the successful sending of the last event before moving to next [MPV.mpv_wait_event].
  while (true) {
    completer = Completer();
    Pointer<mpv_event> event = mpv.mpv_wait_event(handle, -1);

    /// Sending raw address of [mpv_event].
    port.send(event.address);

    /// Ensuring that the last [mpv_event] (which is at the same address) is NOT reset to [mpv_event_id.MPV_EVENT_NONE] after next [MPV.mpv_wait_event] in the loop.
    await completer.future;
    if (event.ref.event_id == mpv_event_id.MPV_EVENT_SHUTDOWN) {
      break;
    }
  }
}

/// Creates & returns [Pointer] to [mpv_handle] whose event loop is running on separate isolate.
///
/// Pass [path] to libmpv dynamic library & [callback] to receive event callbacks as [Pointer] to [mpv_event].
Future<Pointer<mpv_handle>> create(
  String path,
  Future<void> Function(Pointer<mpv_event> event) callback,
) async {
  /// Initializing global [MPV] object.
  mpv = MPV(DynamicLibrary.open(path));

  /// Used to wait for retrieval of [Pointer] to [mpv_handle] from the running isolate.
  var completer = Completer();

  /// Used to receive events from the separate isolate.
  var receiver = ReceivePort();

  /// Late initialized [mpv_handle] & [SendPort] of the [ReceievePort] inside the separate isolate.
  late Pointer<mpv_handle> handle;
  late SendPort port;

  /// Run mainloop in the separate isolate.
  Isolate.spawn(
    mainloop,
    receiver.sendPort,
  );

  receiver.listen((message) {
    /// Receiving [SendPort] of the [ReceivePort] inside the separate isolate to send the path to [DynamicLibrary].
    if (!completer.isCompleted && message is SendPort) {
      port = message;
      port.send(path);
    }

    /// Receiving [Pointer] to [mpv_handle] created by separate isolate.
    else if (!completer.isCompleted && message is int) {
      handle = Pointer.fromAddress(message);
      completer.complete();
    }

    /// Receiving event callbacks.
    else {
      Pointer<mpv_event> event = Pointer.fromAddress(message);
      callback(event).then((value) {
        /// Sending the confirmation.
        port.send(null);
      });
    }
  });

  /// Awaiting the retrieval of [Pointer] to [mpv_handle].
  await completer.future;
  return handle;
}
