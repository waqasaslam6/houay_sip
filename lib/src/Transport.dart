import 'Socket.dart' as Socket;
import 'Exceptions.dart' as Exceptions;
import 'Utils.dart';
import 'Timers.dart';
import 'logger.dart';

final logger = Logger('Transport');
debug(msg) => logger.debug(msg);
debugerror(error) => logger.error(error);

/**
 * Constants
 */
class C {
  // Transport status.
  static const STATUS_CONNECTED = 0;
  static const STATUS_CONNECTING = 1;
  static const STATUS_DISCONNECTED = 2;

  // Socket status.
  static const SOCKET_STATUS_READY = 0;
  static const SOCKET_STATUS_ERROR = 1;

  // Recovery options.
  static const recovery_options = {
    'min_interval': 2, // minimum interval in seconds between recover attempts
    'max_interval': 30 // maximum interval in seconds between recover attempts
  };
}

/*
 * Manages one or multiple JsSIP.Socket instances.
 * Is reponsible for transport recovery logic among all socket instances.
 *
 * @socket JsSIP::Socket instance
 */
class Transport {
  var status;
  var socket;
  var sockets;
  var recovery_options;
  var recover_attempts;
  var recovery_timer;
  var close_requested;

  dynamic onconnecting;
  dynamic ondisconnect;
  dynamic onconnect;
  dynamic ondata;

  Transport(sockets, [recovery_options = C.recovery_options]) {
    debug('new()');

    this.status = C.STATUS_DISCONNECTED;

    // Current socket.
    this.socket = null;

    // Socket collection.
    this.sockets = [];

    this.recovery_options = recovery_options;
    this.recover_attempts = 0;
    this.recovery_timer = null;

    this.close_requested = false;

    if (sockets == null) {
      throw new Exceptions.TypeError(
          'Invalid argument.' + ' null \'sockets\' argument');
    }

    if (sockets is! List) {
      sockets = [sockets];
    }

    sockets.forEach((socket) {
      if (!Socket.isSocket(socket)) {
        throw new Exceptions.TypeError(
            'Invalid argument.' + ' invalid \'JsSIP.Socket\' instance');
      }

      if (socket.weight != null && socket.weight is! num) {
        throw new Exceptions.TypeError(
            'Invalid argument.' + ' \'weight\' attribute is not a number');
      }

      this.sockets.add({
        'socket': socket,
        'weight': socket.weight ?? 0,
        'status': C.SOCKET_STATUS_READY
      });
    });

    // Get the socket with higher weight.
    this._getSocket();
  }

  /**
   * Instance Methods
   */

  get via_transport => this.socket.via_transport;

  get url => this.socket.url;

  get sip_uri => this.socket.sip_uri;

  connect(){
    debug('connect()');

    if (this.isConnected()) {
      debug('Transport is already connected');

      return;
    } else if (this.isConnecting()) {
      debug('Transport is connecting');

      return;
    }

    this.close_requested = false;
    this.status = C.STATUS_CONNECTING;
    this.onconnecting(
        {'socket': this.socket, 'attempts': this.recover_attempts});

    if (!this.close_requested) {
      // Bind socket event callbacks.
      this.socket.onconnect = this._onConnect;
      this.socket.ondisconnect = this._onDisconnect;
      this.socket.ondata = this._onData;
      this.socket.connect();
    }
    return;
  }

  disconnect() {
    debug('close()');

    this.close_requested = true;
    this.recover_attempts = 0;
    this.status = C.STATUS_DISCONNECTED;

    // Clear recovery_timer.
    if (this.recovery_timer != null) {
      clearTimeout(this.recovery_timer);
      this.recovery_timer = null;
    }

    // Unbind socket event callbacks.
    this.socket.onconnect = () => {};
    this.socket.ondisconnect = (data) => {};
    this.socket.ondata = (data) => {};

    this.socket.disconnect();
    this.ondisconnect({'socket': this.socket, 'error': false});
  }

  send(data) {
    debug('send()');

    if (!this.isConnected()) {
      debugerror('unable to send message, transport is not connected');
      return false;
    }

    var message = data.toString();
    debug('sending message:\n\n${message}\n');
    return this.socket.send(message);
  }

  isConnected() {
    return this.status == C.STATUS_CONNECTED;
  }

  isConnecting() {
    return this.status == C.STATUS_CONNECTING;
  }

  /**
   * Private API.
   */

  _reconnect(error) {
    this.recover_attempts += 1;

    var k =
        Math.floor((Math.randomDouble() * Math.pow(2, this.recover_attempts)) + 1);

    if (k < this.recovery_options['min_interval']) {
      k = this.recovery_options['min_interval'];
    } else if (k > this.recovery_options['max_interval']) {
      k = this.recovery_options['max_interval'];
    }

    debug(
        'reconnection attempt: ${this.recover_attempts}. next connection attempt in ${k} seconds');

    this.recovery_timer = setTimeout(() {
      if (!this.close_requested &&
          !(this.isConnected() || this.isConnecting())) {
        // Get the next available socket with higher weight.
        this._getSocket();
        // Connect the socket.
        this.connect();
      }
    }, k * 1000);
  }

  /**
   * get the next available socket with higher weight
   */
  _getSocket() {
    var candidates = [];

    this.sockets.forEach((socket) {
      if (socket['status'] == C.SOCKET_STATUS_ERROR) {
        return; // continue the array iteration
      } else if (candidates.length == 0) {
        candidates.add(socket);
      } else if (socket['weight'] > candidates[0]['weight']) {
        candidates = [socket];
      } else if (socket['weight'] == candidates[0]['weight']) {
        candidates.add(socket);
      }
    });

    if (candidates.length == 0) {
      // All sockets have failed. reset sockets status.
      this.sockets.forEach((socket) {
        socket['status'] = C.SOCKET_STATUS_READY;
      });
      // Get next available socket.
      this._getSocket();
      return;
    }

    var idx = Math.floor((Math.randomDouble() * candidates.length));

    this.socket = candidates[idx]['socket'];
  }

  /**
   * Socket Event Handlers
   */

  _onConnect() {
    this.recover_attempts = 0;
    this.status = C.STATUS_CONNECTED;

    // Clear recovery_timer.
    if (this.recovery_timer != null) {
      clearTimeout(this.recovery_timer);
      this.recovery_timer = null;
    }
    this.onconnect({'socket': this});
  }

  _onDisconnect(data) {
    this.status = C.STATUS_DISCONNECTED;
    this.ondisconnect(data);

    if (this.close_requested) {
      return;
    }
    // Update socket status.
    else {
      this.sockets.forEach((socket) {
        if (this.socket == socket['socket']) {
          socket['status'] = C.SOCKET_STATUS_ERROR;
        }
      });
    }

    this._reconnect(data['error']);
  }

  _onData(data) {
    // CRLF Keep Alive response from server. Ignore it.
    if (data == '\r\n') {
      debug('received message with CRLF Keep Alive response');
      return;
    }
    // Binary message.
    else if (data is! String) {
      try {
        data = new String.fromCharCodes(data);
      } catch (evt) {
        debug('received binary message failed to be converted into string,' +
            ' message discarded');
        return;
      }

      debug('received binary message:\n\n${data}\n');
    }

    // Text message.
    else {
      debug('received text message:\n\n${data}\n');
    }

    this.ondata({'transport': this, 'message': data});
  }
}