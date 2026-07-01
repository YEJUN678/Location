// main.dart
// Live Location app (integrated full version)
// - Real-time location sharing with Google Maps
// - Chat with history, unread badge, chat modal/page
// - ClientId persistence and register_user for server-side ban enforcement
// - Admin dashboard (responsive) with admin gate (localStorage token)
// - Admin actions (ban/force logout/search) via REST endpoints (requires server support)
// - Path tracking (polylines), accuracy circles, friend list, and more
//
// Notes:
// - Requires dependencies in pubspec.yaml: google_maps_flutter, geolocator, socket_io_client, http, uuid, etc.
// - For web builds, dart:html is used for admin session storage and clientId persistence; if you need pure multi-platform,
//   replace dart:html usage with conditional imports or a cross-platform storage solution.
// - Server must implement endpoints and socket events: register_user, update_location, join_room, chat_message,
//   room_state, location_changed, user_left, request_rooms, register_admin, /api/chat/:roomId, /admin/* endpoints.

import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

// Web-only import guarded by kIsWeb usage
// ignore: uri_does_not_exist
import 'dart:html' as html; // used only when kIsWeb is true

/// Configuration via --dart-define
const String configuredSocketServerUrl = String.fromEnvironment('SOCKET_SERVER_URL');
const String configuredUserId = String.fromEnvironment('USER_ID');
const String configuredDisplayName = String.fromEnvironment('DISPLAY_NAME');
const String configuredRoomId = String.fromEnvironment('ROOM_ID', defaultValue: 'meetup_room_1004');
const bool isAdminMode = bool.fromEnvironment('IS_ADMIN', defaultValue: false);

/// Marker hues and friend colors used across the app
const List<double> markerHues = [
  BitmapDescriptor.hueRed,
  BitmapDescriptor.hueOrange,
  BitmapDescriptor.hueYellow,
  BitmapDescriptor.hueGreen,
  BitmapDescriptor.hueCyan,
  BitmapDescriptor.hueAzure,
  BitmapDescriptor.hueViolet,
  BitmapDescriptor.hueRose,
];

const List<Color> friendColors = [
  Color(0xFFE5484D),
  Color(0xFFFF8A00),
  Color(0xFFE2B203),
  Color(0xFF2F9E44),
  Color(0xFF0891B2),
  Color(0xFF2563EB),
  Color(0xFF7C3AED),
  Color(0xFFDB2777),
];

/// Data models
class FriendLocation {
  const FriendLocation({
    required this.position,
    required this.displayName,
    required this.accuracy,
    required this.address,
    required this.updatedAt,
    required this.isOnline,
  });

  final LatLng position;
  final String displayName;
  final double? accuracy;
  final String address;
  final DateTime updatedAt;
  final bool isOnline;

  FriendLocation copyWith({
    LatLng? position,
    String? displayName,
    double? accuracy,
    String? address,
    DateTime? updatedAt,
    bool? isOnline,
  }) {
    return FriendLocation(
      position: position ?? this.position,
      displayName: displayName ?? this.displayName,
      accuracy: accuracy ?? this.accuracy,
      address: address ?? this.address,
      updatedAt: updatedAt ?? this.updatedAt,
      isOnline: isOnline ?? this.isOnline,
    );
  }
}

class ActivityLog {
  ActivityLog({
    required this.event,
    required this.userId,
    required this.displayName,
    this.latitude,
    this.longitude,
    required this.timestamp,
    this.roomId,
  });

  final String event;
  final String userId;
  final String displayName;
  final double? latitude;
  final double? longitude;
  final DateTime timestamp;
  final String? roomId;
}

class ChatMessage {
  final String id;
  final String userId;
  final String displayName;
  final String message;
  final DateTime timestamp;
  ChatMessage(this.id, this.userId, this.displayName, this.message, this.timestamp);
}

/// App entry
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

/// Utility: get or create persistent clientId (web localStorage or fallback)
String getOrCreateClientId() {
  try {
    if (kIsWeb) {
      final storage = html.window.localStorage;
      var cid = storage['clientId'];
      if (cid == null || cid.isEmpty) {
        cid = const Uuid().v4();
        storage['clientId'] = cid;
      }
      return cid;
    }
  } catch (_) {}
  // Non-web fallback: generate a UUID each run (not persistent)
  return const Uuid().v4();
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Live Location',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2563EB), brightness: Brightness.light),
        scaffoldBackgroundColor: const Color(0xFFF5F7FA),
        useMaterial3: true,
      ),
      initialRoute: '/',
      routes: {
        '/': (_) => const LocationShareScreen(),
        '/admin': (_) => AdminGate(child: const AdminDashboardScreen()),
      },
      home: isAdminMode ? const AdminDashboardScreen() : null,
    );
  }
}

/// ---------------------------
/// LocationShareScreen (User view)
/// - shows map, friends list, chat quick input, chat modal/page, unread badge
/// - tracks own location and emits to server
/// - registers clientId on connect for ban enforcement
/// ---------------------------
class LocationShareScreen extends StatefulWidget {
  const LocationShareScreen({super.key});
  @override
  State<LocationShareScreen> createState() => _LocationShareScreenState();
}

class _LocationShareScreenState extends State<LocationShareScreen> {
  late final io.Socket socket;
  late final TextEditingController displayNameController;
  late final TextEditingController roomController;

  GoogleMapController? mapController;

  final String clientId = getOrCreateClientId();
  final String userId = configuredUserId.isNotEmpty
      ? configuredUserId
      : 'User_${DateTime.now().millisecondsSinceEpoch % 100000}';

  late String displayName;
  late String roomId;
  LatLng? myCurrentLatLng;
  double? myAccuracy;
  bool followMyLocation = true;
  final Map<String, FriendLocation> friendsLocations = {};
  String connectionStatus = 'Waiting for server...';

  // Chat and path tracking
  final Map<String, List<LatLng>> friendPaths = {};
  final List<ChatMessage> chatMessages = [];
  final TextEditingController chatController = TextEditingController();

  // Unread badge and chat open state
  int unreadChatCount = 0;
  bool isChatOpen = false;

  // For typing indicator (optional)
  final Map<String, bool> typingUsers = {};

  @override
  void initState() {
    super.initState();
    displayName = configuredDisplayName.isNotEmpty ? configuredDisplayName : userId;
    roomId = _initialRoomId();
    displayNameController = TextEditingController(text: displayName);
    roomController = TextEditingController(text: roomId);
    initServerConnection();
    startLocationTracking();
  }

  String _initialRoomId() {
    final linkedRoom = Uri.base.queryParameters['room']?.trim();
    if (linkedRoom != null && linkedRoom.isNotEmpty) return linkedRoom;
    return configuredRoomId;
  }

  String get _socketServerUrl {
    if (configuredSocketServerUrl.isNotEmpty) return configuredSocketServerUrl;
    if (kIsWeb) {
      final baseUri = Uri.base;
      return '${baseUri.scheme}://${baseUri.host}${baseUri.hasPort ? ':${baseUri.port}' : ''}';
    }
    return 'http://localhost:3000';
  }

  void initServerConnection() {
    socket = io.io(
      _socketServerUrl,
      io.OptionBuilder().setTransports(['websocket']).disableAutoConnect().build(),
    );

    socket.connect();

    socket.onConnect((_) {
      setState(() {
        connectionStatus = 'Connected';
      });
      // Register clientId and userId for server-side ban enforcement and mapping
      socket.emit('register_user', {'clientId': clientId, 'userId': userId, 'token': null});
      _joinRoom(roomId, clearFriends: false);
    });

    socket.onConnectError((data) {
      setState(() {
        connectionStatus = 'Connection failed';
      });
    });

    socket.onDisconnect((_) {
      setState(() {
        connectionStatus = 'Disconnected';
      });
    });

    socket.on('location_changed', (data) {
      _upsertFriendLocation(data);
    });

    socket.on('room_state', (data) {
      final users = data['users'];
      if (users is! List) return;
      for (final user in users) {
        if (user is Map) {
          _upsertFriendLocation(Map<String, dynamic>.from(user));
        }
      }
    });

    socket.on('user_left', (data) {
      final friendId = data['userId'] as String?;
      if (friendId == null || friendId == userId) return;
      setState(() {
        final current = friendsLocations[friendId];
        if (current != null) {
          friendsLocations[friendId] = current.copyWith(isOnline: false);
        }
      });
    });

    // Chat handler: append message and increment unread if chat closed
    socket.on('chat_message', (data) {
      if (data is Map) {
        final msg = ChatMessage(
          data['id']?.toString() ?? '${DateTime.now().millisecondsSinceEpoch}',
          data['userId']?.toString() ?? 'unknown',
          data['displayName']?.toString() ?? data['userId']?.toString() ?? 'unknown',
          data['message']?.toString() ?? '',
          DateTime.fromMillisecondsSinceEpoch((data['ts'] as int?) ?? DateTime.now().millisecondsSinceEpoch),
        );
        setState(() {
          chatMessages.insert(0, msg);
          if (!isChatOpen) {
            unreadChatCount = (unreadChatCount + 1).clamp(0, 999);
          }
        });
      }
    });

    // Typing indicator
    socket.on('typing', (data) {
      if (data is Map) {
        final uid = data['userId']?.toString();
        final typing = data['typing'] == true;
        if (uid != null) {
          setState(() {
            typingUsers[uid] = typing;
          });
          // clear after a timeout if typing false not received
          if (typing) {
            Future.delayed(const Duration(seconds: 3), () {
              if (typingUsers[uid] == true) {
                setState(() => typingUsers.remove(uid));
              }
            });
          }
        }
      }
    });

    // Force logout from admin or ban
    socket.on('force_logout', (data) {
      final reason = data?['reason']?.toString() ?? 'admin action';
      if (mounted) {
        showDialog(context: context, builder: (_) => AlertDialog(
          title: const Text('Logged out'),
          content: Text('You have been logged out: $reason'),
          actions: [ TextButton(onPressed: () { Navigator.of(context).pop(); }, child: const Text('OK')) ],
        ));
      }
      try {
        if (kIsWeb) html.window.localStorage.remove('auth_token');
      } catch (_) {}
      socket.disconnect();
    });
  }

  void _upsertFriendLocation(Map<String, dynamic> data) {
    if (data['userId'] == userId) return;

    final friendId = data['userId'] as String?;
    if (friendId == null) return;

    final friendName = (data['displayName'] as String?)?.trim();
    final address = (data['address'] as String?)?.trim();
    final latitude = data['latitude'];
    final longitude = data['longitude'];
    if (latitude is! num || longitude is! num) return;

    final pos = LatLng(latitude.toDouble(), longitude.toDouble());

    setState(() {
      friendsLocations[friendId] = FriendLocation(
        displayName: friendName?.isNotEmpty == true ? friendName! : friendId,
        position: pos,
        accuracy: (data['accuracy'] as num?)?.toDouble(),
        address: address?.isNotEmpty == true ? address! : 'Address unavailable',
        updatedAt: DateTime.now(),
        isOnline: true,
      );

      // Append to path history
      friendPaths.putIfAbsent(friendId, () => []).add(pos);
    });
  }

  void _saveDisplayName() {
    final nextName = displayNameController.text.trim();
    if (nextName.isEmpty) {
      displayNameController.text = displayName;
      return;
    }
    setState(() {
      displayName = nextName;
    });
    _emitCurrentLocation();
  }

  void _saveRoom() {
    final nextRoom = roomController.text.trim();
    if (nextRoom.isEmpty) {
      roomController.text = roomId;
      return;
    }
    _joinRoom(nextRoom);
  }

  Future<void> _joinRoom(String nextRoom, {bool clearFriends = true}) async {
    setState(() {
      roomId = nextRoom;
      roomController.text = nextRoom;
      if (clearFriends) {
        friendsLocations.clear();
        friendPaths.clear();
        chatMessages.clear();
      }
    });

    socket.emit('join_room', nextRoom);

    // load chat history from server
    try {
      final base = _socketServerUrl.replaceAll(RegExp(r'/+$'), '');
      final uri = Uri.parse('$base/api/chat/$nextRoom?limit=200');
      final resp = await http.get(uri);
      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body);
        final msgs = (body['messages'] as List<dynamic>).map((m) {
          return ChatMessage(
            m['id']?.toString() ?? '${DateTime.now().millisecondsSinceEpoch}',
            m['userId']?.toString() ?? '',
            m['displayName']?.toString() ?? '',
            m['message']?.toString() ?? '',
            DateTime.fromMillisecondsSinceEpoch(m['ts'] ?? DateTime.now().millisecondsSinceEpoch),
          );
        }).toList();
        setState(() {
          chatMessages.clear();
          chatMessages.addAll(msgs);
        });
      }
    } catch (e) {
      // ignore
    }

    _emitCurrentLocation();
  }

  Future<void> _copyRoomLink() async {
    final currentUri = Uri.base;
    final shareUri = currentUri.replace(
      queryParameters: {
        ...currentUri.queryParameters,
        'room': roomId,
      },
    );

    await Clipboard.setData(ClipboardData(text: shareUri.toString()));
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Room link copied')),
    );
  }

  void _emitCurrentLocation() {
    final current = myCurrentLatLng;
    if (current == null) return;

    socket.emit('update_location', {
      'roomId': roomId,
      'userId': userId,
      'displayName': displayName,
      'latitude': current.latitude,
      'longitude': current.longitude,
      'accuracy': myAccuracy,
    });

    // Add to own path
    friendPaths.putIfAbsent(userId, () => []).add(current);
  }

  // Local send chat helper used by quick input and ChatScreen
  void _sendChatFromController(String msg) {
    if (msg.trim().isEmpty) return;
    final payload = {
      'roomId': roomId,
      'userId': userId,
      'displayName': displayName,
      'message': msg.trim(),
    };
    socket.emit('chat_message', payload);
    setState(() {
      chatMessages.insert(0, ChatMessage('${DateTime.now().millisecondsSinceEpoch}', userId, displayName, msg.trim(), DateTime.now()));
    });
  }

  void _sendChat() {
    final msg = chatController.text.trim();
    if (msg.isEmpty) return;
    _sendChatFromController(msg);
    chatController.clear();
  }

  Future<void> startLocationTracking() async {
    final permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      setState(() {
        myCurrentLatLng = const LatLng(37.5559, 126.9723);
        myAccuracy = 1000;
        connectionStatus = 'Location permission denied';
      });
      _emitCurrentLocation();
      return;
    }

    setState(() {
      myCurrentLatLng = const LatLng(37.2939, 127.0163);
      myAccuracy = 250;
    });

    try {
      final currentPosition = await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.high));
      setState(() {
        myCurrentLatLng = LatLng(currentPosition.latitude, currentPosition.longitude);
        myAccuracy = currentPosition.accuracy;
      });
      _emitCurrentLocation();
    } catch (_) {
      _emitCurrentLocation();
    }

    Geolocator.getPositionStream(locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 10))
      .listen((position) {
        final newLatLng = LatLng(position.latitude, position.longitude);
        setState(() {
          myCurrentLatLng = newLatLng;
          myAccuracy = position.accuracy;
        });
        if (followMyLocation) {
          mapController?.animateCamera(CameraUpdate.newLatLng(newLatLng));
        }
        _emitCurrentLocation();
      });
  }

  double _calculateDistance(LatLng pos1, LatLng pos2) {
    const p = 0.017453292519943295;
    final c = math.cos;
    final a = 0.5 -
        c((pos2.latitude - pos1.latitude) * p) / 2 +
        c(pos1.latitude * p) *
            c(pos2.latitude * p) *
            (1 - c((pos2.longitude - pos1.longitude) * p)) /
            2;
    return 12742 * math.asin(math.sqrt(a));
  }

  int _calculateWalkingTime(double distanceInKm) {
    const speedKmPerHour = 4.8;
    final timeInHours = distanceInKm / speedKmPerHour;
    return (timeInHours * 60).round();
  }

  int _friendColorIndex(String id) {
    return id.codeUnits.fold<int>(0, (sum, code) => sum + code) % friendColors.length;
  }

  String _formatDistance(double distanceInKm) {
    if (distanceInKm < 1) {
      return '${(distanceInKm * 1000).round()} m';
    }
    return '${distanceInKm.toStringAsFixed(2)} km';
  }

  String _formatAccuracy(double? accuracy) {
    if (accuracy == null) return 'accuracy unknown';
    return 'accuracy +/- ${accuracy.round()} m';
  }

  Set<Marker> _createMarkers() {
    final markers = <Marker>{};

    if (myCurrentLatLng != null) {
      markers.add(
        Marker(
          markerId: const MarkerId('my_location'),
          position: myCurrentLatLng!,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
          infoWindow: InfoWindow(
            title: 'Me ($displayName)',
            snippet: _formatAccuracy(myAccuracy),
          ),
        ),
      );
    }

    friendsLocations.forEach((friendId, friendLocation) {
      var distance = 0.0;
      var walkingMinutes = 0;

      if (myCurrentLatLng != null) {
        distance = _calculateDistance(myCurrentLatLng!, friendLocation.position);
        walkingMinutes = _calculateWalkingTime(distance);
      }

      final colorIndex = _friendColorIndex(friendId);

      markers.add(
        Marker(
          markerId: MarkerId(friendId),
          position: friendLocation.position,
          alpha: friendLocation.isOnline ? 1 : 0.45,
          icon: BitmapDescriptor.defaultMarkerWithHue(markerHues[colorIndex]),
          infoWindow: InfoWindow(
            title: friendLocation.displayName,
            snippet: '${_formatDistance(distance)}, about $walkingMinutes min walk',
          ),
        ),
      );
    });

    return markers;
  }

  Set<Circle> _createAccuracyCircles() {
    final circles = <Circle>{};

    if (myCurrentLatLng != null && myAccuracy != null) {
      circles.add(
        Circle(
          circleId: const CircleId('my_accuracy'),
          center: myCurrentLatLng!,
          radius: myAccuracy!,
          fillColor: const Color(0x332563EB),
          strokeColor: const Color(0xFF2563EB),
          strokeWidth: 1,
        ),
      );
    }

    friendsLocations.forEach((friendId, friendLocation) {
      final accuracy = friendLocation.accuracy;
      if (accuracy == null) return;

      final color = friendColors[_friendColorIndex(friendId)];
      circles.add(
        Circle(
          circleId: CircleId('accuracy_$friendId'),
          center: friendLocation.position,
          radius: accuracy,
          fillColor: color.withValues(
            alpha: friendLocation.isOnline ? 0.16 : 0.07,
          ),
          strokeColor: color.withValues(
            alpha: friendLocation.isOnline ? 0.75 : 0.25,
          ),
          strokeWidth: 1,
        ),
      );
    });

    return circles;
  }

  /// Polylines for friend paths
  Set<Polyline> _createPolylines() {
    final polylines = <Polyline>{};
    friendPaths.forEach((fid, path) {
      if (path.length > 1) {
        polylines.add(Polyline(
          polylineId: PolylineId('path_$fid'),
          points: path,
          color: fid == userId ? Colors.blue : Colors.red,
          width: 3,
        ));
      }
    });
    return polylines;
  }

  void _focusFriend(FriendLocation friend) {
    followMyLocation = false;
    mapController?.animateCamera(CameraUpdate.newLatLngZoom(friend.position, 16));
  }

  void _recenterOnMe() {
    final current = myCurrentLatLng;
    if (current == null) return;
    setState(() {
      followMyLocation = true;
    });
    mapController?.animateCamera(CameraUpdate.newLatLngZoom(current, 16));
  }

  // Open chat: modal on desktop, full page on mobile
  void _openChat(BuildContext context) async {
    setState(() {
      isChatOpen = true;
      unreadChatCount = 0;
    });

    final isMobile = MediaQuery.of(context).size.width < 700;
    if (isMobile) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            roomId: roomId,
            userId: userId,
            displayName: displayName,
            socket: socket,
            messages: chatMessages,
            onClose: () {
              setState(() => isChatOpen = false);
            },
          ),
        ),
      );
    } else {
      await showDialog(
        context: context,
        builder: (_) => Dialog(
          insetPadding: const EdgeInsets.all(24),
          child: SizedBox(
            width: 520,
            height: 560,
            child: ChatScreen(
              roomId: roomId,
              userId: userId,
              displayName: displayName,
              socket: socket,
              messages: chatMessages,
              onClose: () {
                Navigator.of(context).pop();
                setState(() => isChatOpen = false);
              },
            ),
          ),
        ),
      );
    }

    setState(() {
      isChatOpen = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isConnected = connectionStatus == 'Connected';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Live Location'),
        centerTitle: false,
        elevation: 0,
        backgroundColor: const Color(0xFFF5F7FA),
        foregroundColor: const Color(0xFF172033),
        actions: [
          // Chat button with unread badge
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                IconButton(
                  tooltip: 'Open Chat',
                  icon: const Icon(Icons.chat_bubble_outline),
                  onPressed: () => _openChat(context),
                ),
                if (unreadChatCount > 0)
                  Positioned(
                    right: -4,
                    top: -6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.red,
                        borderRadius: BorderRadius.circular(999),
                        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2))],
                      ),
                      constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                      child: Center(
                        child: Text(
                          unreadChatCount > 99 ? '99+' : unreadChatCount.toString(),
                          style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Open Admin Dashboard',
            icon: const Icon(Icons.admin_panel_settings),
            onPressed: () {
              Navigator.pushNamed(context, '/admin');
            },
          ),
        ],
      ),
      body: Column(
        children: [
          _buildHeader(isConnected),
          Expanded(flex: 3, child: _buildMapPane()),
          Expanded(
            flex: 2,
            child: Column(
              children: [
                Expanded(child: _buildFriendsPanel()),
                // Quick chat input (keeps friends list visible)
                Container(
                  width: double.infinity,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    border: Border(top: BorderSide(color: Color(0xFFE4E8F0))),
                  ),
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: chatController,
                          decoration: const InputDecoration(
                            hintText: 'Enter message',
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                          onSubmitted: (_) => _sendChat(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: _sendChat,
                        child: const Text('Send'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(bool isConnected) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFE4E8F0))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: displayNameController,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _saveDisplayName(),
                  decoration: _inputDecoration(label: 'My name', icon: Icons.person_outline),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 48,
                width: 48,
                child: IconButton.filled(
                  onPressed: _saveDisplayName,
                  icon: const Icon(Icons.check),
                  tooltip: 'Save name',
                  style: IconButton.styleFrom(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: roomController,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _saveRoom(),
                  decoration: _inputDecoration(label: 'Room', icon: Icons.meeting_room_outlined),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 48,
                width: 48,
                child: IconButton.outlined(
                  onPressed: _saveRoom,
                  icon: const Icon(Icons.login),
                  tooltip: 'Join room',
                  style: IconButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 48,
                width: 48,
                child: IconButton.outlined(
                  onPressed: _copyRoomLink,
                  icon: const Icon(Icons.link),
                  tooltip: 'Copy room link',
                  style: IconButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _InfoPill(
                icon: isConnected ? Icons.wifi : Icons.wifi_off,
                label: connectionStatus,
                color: isConnected ? const Color(0xFF12805C) : const Color(0xFFB42318),
              ),
              _InfoPill(
                icon: followMyLocation ? Icons.my_location : Icons.pan_tool,
                label: followMyLocation ? 'Following me' : 'Manual map',
                color: const Color(0xFF2563EB),
              ),
              _InfoPill(
                icon: Icons.badge_outlined,
                label: userId,
                color: const Color(0xFF6B4E16),
              ),
            ],
          ),
        ],
      ),
    );
  }

  InputDecoration _inputDecoration({required String label, required IconData icon}) {
    return InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon),
      filled: true,
      fillColor: const Color(0xFFF7F9FC),
      isDense: true,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFD7DDE8))),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFD7DDE8))),
    );
  }

  Widget _buildMapPane() {
    if (!kIsWeb) {
      return const Center(child: Text('Google Map is shown on web.'));
    }

    if (myCurrentLatLng == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Stack(
      children: [
        GoogleMap(
          onMapCreated: (controller) {
            mapController = controller;
          },
          onCameraMoveStarted: () {
            if (followMyLocation) {
              setState(() {
                followMyLocation = false;
              });
            }
          },
          initialCameraPosition: CameraPosition(target: myCurrentLatLng!, zoom: 14),
          markers: _createMarkers(),
          circles: _createAccuracyCircles(),
          polylines: _createPolylines(),
          myLocationEnabled: false,
          myLocationButtonEnabled: false,
        ),
        Positioned(
          left: 16,
          top: 16,
          child: DecoratedBox(
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), boxShadow: const [
              BoxShadow(color: Color(0x22000000), blurRadius: 10, offset: Offset(0, 4)),
            ]),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.near_me, size: 18, color: Color(0xFF2563EB)),
                const SizedBox(width: 8),
                Text(displayName, style: const TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF172033))),
              ]),
            ),
          ),
        ),
        Positioned(
          right: 16,
          bottom: 16,
          child: FloatingActionButton.small(
            onPressed: _recenterOnMe,
            tooltip: 'Follow my location',
            child: Icon(followMyLocation ? Icons.my_location : Icons.location_searching),
          ),
        ),
      ],
    );
  }

  Widget _buildFriendsPanel() {
    final onlineCount = friendsLocations.values.where((friend) => friend.isOnline).length;

    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: Color(0xFFE4E8F0)))),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(
              children: [
                const Icon(Icons.route, color: Color(0xFF2563EB)),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Friends nearby', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Color(0xFF172033))),
                ),
                Text('$onlineCount/${friendsLocations.length}', style: const TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF2563EB))),
              ],
            ),
          ),
          Expanded(
            child: friendsLocations.isEmpty
                ? const Center(
                    child: Text('Share this room link with a friend to see them here.', textAlign: TextAlign.center, style: TextStyle(color: Color(0xFF687386))),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    itemCount: friendsLocations.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final entry = friendsLocations.entries.elementAt(index);
                      final friend = entry.value;
                      final distance = myCurrentLatLng != null ? _calculateDistance(myCurrentLatLng!, friend.position) : 0.0;
                      final walkTime = _calculateWalkingTime(distance);
                      final color = friendColors[_friendColorIndex(entry.key)];

                      return Opacity(
                        opacity: friend.isOnline ? 1 : 0.48,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: const Color(0xFFF8FAFD),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: friend.isOnline ? color.withValues(alpha: 0.35) : const Color(0xFFE4E8F0)),
                          ),
                          child: ListTile(
                            onTap: () => _focusFriend(friend),
                            leading: CircleAvatar(
                              backgroundColor: color.withValues(alpha: 0.16),
                              foregroundColor: color,
                              child: Text(friend.displayName.characters.first.toUpperCase()),
                            ),
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(friend.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF172033))),
                                ),
                                const SizedBox(width: 8),
                                Text(friend.isOnline ? 'Online' : 'Offline', style: TextStyle(color: friend.isOnline ? const Color(0xFF12805C) : const Color(0xFF687386), fontSize: 12, fontWeight: FontWeight.w800)),
                              ],
                            ),
                            subtitle: Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                '${friend.address}\n${_formatDistance(distance)} away, $walkTime min walk\n${_formatAccuracy(friend.accuracy)}',
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Color(0xFF687386), height: 1.25),
                              ),
                            ),
                            trailing: const Icon(Icons.chevron_right, color: Color(0xFF687386)),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    try {
      socket.disconnect();
    } catch (_) {}
    displayNameController.dispose();
    roomController.dispose();
    chatController.dispose();
    mapController?.dispose();
    super.dispose();
  }
}

/// ---------------------------
/// ChatScreen widget (modal/page)
/// - receives socket and displays messages in real-time
/// - sends messages via socket.emit('chat_message', {...})
/// ---------------------------
class ChatScreen extends StatefulWidget {
  final String roomId;
  final String userId;
  final String displayName;
  final io.Socket socket;
  final List<ChatMessage> messages;
  final VoidCallback? onClose;

  final void Function(String)? onSend;

  const ChatScreen({
    required this.roomId,
    required this.userId,
    required this.displayName,
    required this.socket,
    required this.messages,
    this.onClose,
    this.onSend,
    super.key,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scroll = ScrollController();
  late List<ChatMessage> _localMessages;
  Timer? _typingTimer;

  @override
  void initState() {
    super.initState();
    _localMessages = List<ChatMessage>.from(widget.messages);
    widget.socket.on('chat_message', _onIncoming);
    widget.socket.on('typing', _onTyping);
  }

  void _onIncoming(dynamic data) {
    if (data is Map) {
      final msg = ChatMessage(
        data['id']?.toString() ?? '${DateTime.now().millisecondsSinceEpoch}',
        data['userId']?.toString() ?? 'unknown',
        data['displayName']?.toString() ?? 'unknown',
        data['message']?.toString() ?? '',
        DateTime.fromMillisecondsSinceEpoch((data['ts'] as int?) ?? DateTime.now().millisecondsSinceEpoch),
      );
      setState(() {
        _localMessages.insert(0, msg);
      });
    }
  }

  void _onTyping(dynamic data) {
    // optional: show typing indicator
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    final payload = {
      'roomId': widget.roomId,
      'userId': widget.userId,
      'displayName': widget.displayName,
      'message': text,
    };
    widget.socket.emit('chat_message', payload);
    setState(() {
      _localMessages.insert(0, ChatMessage('${DateTime.now().millisecondsSinceEpoch}', widget.userId, widget.displayName, text, DateTime.now()));
    });
    _controller.clear();
    widget.onSend?.call(text);
  }

  void _onInputChanged(String v) {
    widget.socket.emit('typing', {'roomId': widget.roomId, 'userId': widget.userId, 'typing': true});
    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(seconds: 2), () {
      widget.socket.emit('typing', {'roomId': widget.roomId, 'userId': widget.userId, 'typing': false});
    });
  }

  @override
  void dispose() {
    widget.socket.off('chat_message', _onIncoming);
    widget.socket.off('typing', _onTyping);
    _controller.dispose();
    _scroll.dispose();
    _typingTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chat'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () {
            widget.onClose?.call();
            Navigator.of(context).maybePop();
          },
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: _localMessages.isEmpty
                ? const Center(child: Text('No messages yet'))
                : ListView.builder(
                    reverse: true,
                    controller: _scroll,
                    itemCount: _localMessages.length,
                    itemBuilder: (context, index) {
                      final m = _localMessages[index];
                      final mine = m.userId == widget.userId;
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        child: Align(
                          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                          child: Container(
                            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.7),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: mine ? Colors.blue.shade600 : Colors.grey.shade200,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (!mine) Text(m.displayName, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                                const SizedBox(height: 4),
                                Text(m.message, style: TextStyle(color: mine ? Colors.white : Colors.black87)),
                                const SizedBox(height: 4),
                                Text('${m.timestamp.hour.toString().padLeft(2, '0')}:${m.timestamp.minute.toString().padLeft(2, '0')}', style: TextStyle(fontSize: 10, color: mine ? Colors.white70 : Colors.black45)),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      decoration: const InputDecoration(hintText: 'Type a message', border: OutlineInputBorder(), isDense: true),
                      onSubmitted: (_) => _send(),
                      onChanged: _onInputChanged,
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(onPressed: _send, child: const Text('Send')),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// ---------------------------
/// AdminDashboardScreen (responsive)
/// - Desktop: complex three-column layout (rooms | map | logs)
/// - Mobile: tabbed simplified layout (Map / Rooms / Logs)
/// ---------------------------
class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});
  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  late final io.Socket socket;
  final Map<String, FriendLocation> monitoredLocations = {};
  final List<ActivityLog> activityLogs = [];
  String connectionStatus = 'Waiting for server...';
  GoogleMapController? mapController;
  String filterRoom = configuredRoomId;

  // rooms: roomId -> set of userIds currently seen in that room
  final Map<String, Set<String>> rooms = {};

  // UI state
  String roomSearch = '';
  bool sortByCountDesc = true;

  String get _socketServerUrl {
    if (configuredSocketServerUrl.isNotEmpty) return configuredSocketServerUrl;
    if (kIsWeb) {
      final baseUri = Uri.base;
      return '${baseUri.scheme}://${baseUri.host}${baseUri.hasPort ? ':${baseUri.port}' : ''}';
    }
    return 'http://localhost:3000';
  }

  @override
  void initState() {
    super.initState();
    _initAdminSocket();
  }

  void _initAdminSocket() {
    socket = io.io(_socketServerUrl, io.OptionBuilder().setTransports(['websocket']).disableAutoConnect().build());
    socket.connect();

    socket.onConnect((_) {
      setState(() {
        connectionStatus = 'Connected';
      });
      socket.emit('join_room', filterRoom);
      socket.emit('register_admin');
    });

    socket.onConnectError((_) {
      setState(() {
        connectionStatus = 'Connection failed';
      });
    });

    socket.onDisconnect((_) {
      setState(() {
        connectionStatus = 'Disconnected';
      });
    });

    socket.on('room_state', (data) {
      final users = data['users'];
      final roomIdFromEvent = (data['roomId'] as String?)?.trim();
      if (users is List) {
        for (final user in users) {
          if (user is Map) {
            final mapUser = Map<String, dynamic>.from(user);
            final roomFromUser = (mapUser['roomId'] as String?)?.trim();
            final roomToUse = roomFromUser ?? roomIdFromEvent;
            _handleLocationData(mapUser, event: 'room_state', roomId: roomToUse);
          }
        }
      }
    });

    socket.on('location_changed', (data) {
      if (data is Map) {
        _handleLocationData(Map<String, dynamic>.from(data), event: 'location_changed');
      }
    });

    socket.on('user_left', (data) {
      if (data is Map) {
        final friendId = data['userId'] as String?;
        final room = (data['roomId'] as String?)?.trim();
        if (friendId != null) {
          setState(() {
            final current = monitoredLocations[friendId];
            if (current != null) {
              monitoredLocations[friendId] = current.copyWith(isOnline: false);
            }
            if (room != null && rooms.containsKey(room)) {
              rooms[room]!.remove(friendId);
              if (rooms[room]!.isEmpty) rooms.remove(room);
            }
            activityLogs.insert(0, ActivityLog(event: 'user_left', userId: friendId, displayName: data['displayName'] ?? friendId, latitude: null, longitude: null, timestamp: DateTime.now(), roomId: room));
          });
        }
      }
    });

    socket.on('user_joined', (data) {
      if (data is Map) {
        _handleLocationData(Map<String, dynamic>.from(data), event: 'user_joined');
      }
    });

    socket.on('rooms_list', (data) {
      if (data is Map) {
        setState(() {
          rooms.clear();
          data.forEach((key, value) {
            if (value is List) {
              rooms[key] = Set<String>.from(value.map((e) => e.toString()));
            }
          });
        });
      }
    });

    socket.on('chat_message', (data) {
      if (data is Map) {
        activityLogs.insert(0, ActivityLog(event: 'chat_message', userId: data['userId']?.toString() ?? '', displayName: data['displayName']?.toString() ?? '', latitude: null, longitude: null, timestamp: DateTime.now(), roomId: data['roomId']?.toString()));
      }
    });
  }

  void _handleLocationData(Map<String, dynamic> data, {required String event, String? roomId}) {
    final friendId = data['userId'] as String?;
    if (friendId == null) return;

    final displayName = (data['displayName'] as String?)?.trim() ?? friendId;
    final latitude = data['latitude'];
    final longitude = data['longitude'];
    final accuracy = (data['accuracy'] as num?)?.toDouble();
    final address = (data['address'] as String?)?.trim() ?? 'Address unavailable';
    final room = (data['roomId'] as String?)?.trim() ?? roomId;

    if (room != null && room.isNotEmpty) {
      rooms.putIfAbsent(room, () => <String>{});
      rooms[room]!.add(friendId);
    }

    if (latitude is num && longitude is num) {
      final pos = LatLng(latitude.toDouble(), longitude.toDouble());
      setState(() {
        monitoredLocations[friendId] = FriendLocation(position: pos, displayName: displayName, accuracy: accuracy, address: address, updatedAt: DateTime.now(), isOnline: true);
        activityLogs.insert(0, ActivityLog(event: event, userId: friendId, displayName: displayName, latitude: latitude.toDouble(), longitude: longitude.toDouble(), timestamp: DateTime.now(), roomId: room));
      });
    } else {
      setState(() {
        activityLogs.insert(0, ActivityLog(event: event, userId: friendId, displayName: displayName, latitude: null, longitude: null, timestamp: DateTime.now(), roomId: room));
      });
    }
  }

  Set<Marker> _createMarkers() {
    final markers = <Marker>{};
    monitoredLocations.forEach((id, loc) {
      markers.add(Marker(markerId: MarkerId('admin_$id'), position: loc.position, infoWindow: InfoWindow(title: loc.displayName, snippet: '${loc.address}\nUpdated: ${loc.updatedAt}'), icon: BitmapDescriptor.defaultMarkerWithHue(markerHues[id.codeUnits.fold<int>(0, (s, c) => s + c) % markerHues.length]), alpha: loc.isOnline ? 1.0 : 0.5));
    });
    return markers;
  }

  Set<Circle> _createAccuracyCircles() {
    final circles = <Circle>{};
    monitoredLocations.forEach((id, loc) {
      final accuracy = loc.accuracy;
      if (accuracy == null) return;
      final color = friendColors[id.codeUnits.fold<int>(0, (s, c) => s + c) % friendColors.length];
      circles.add(Circle(circleId: CircleId('admin_accuracy_$id'), center: loc.position, radius: accuracy, fillColor: color.withValues(alpha: 0.12), strokeColor: color.withValues(alpha: 0.6), strokeWidth: 1));
    });
    return circles;
  }

  double _calculateDistance(LatLng pos1, LatLng pos2) {
    const p = 0.017453292519943295;
    final c = math.cos;
    final a = 0.5 - c((pos2.latitude - pos1.latitude) * p) / 2 + c(pos1.latitude * p) * c(pos2.latitude * p) * (1 - c((pos2.longitude - pos1.longitude) * p)) / 2;
    return 12742 * math.asin(math.sqrt(a));
  }

  List<String> _filteredSortedRoomIds() {
    final list = rooms.keys.where((r) => r.contains(roomSearch)).toList();
    list.sort((a, b) {
      final ca = rooms[a]?.length ?? 0;
      final cb = rooms[b]?.length ?? 0;
      return sortByCountDesc ? cb.compareTo(ca) : ca.compareTo(cb);
    });
    return list;
  }

  void _selectRoom(String roomId) {
    setState(() {
      filterRoom = roomId;
      monitoredLocations.clear();
      activityLogs.clear();
    });
    socket.emit('join_room', filterRoom);
  }

  Future<void> _adminBan(String type, String id) async {
    final base = _socketServerUrl.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$base/admin/ban');
    try {
      final res = await http.post(uri, body: jsonEncode({'type': type, 'id': id}), headers: {'Content-Type': 'application/json'});
      if (res.statusCode == 200) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Banned')));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ban failed')));
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ban error')));
    }
  }

  Future<void> _adminForceLogout(String type, String id) async {
    socket.emit('admin_force_logout', {'type': type, 'id': id});

    final base = _socketServerUrl.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$base/admin/force_logout');
    try {
      final res = await http.post(uri, body: jsonEncode({'type': type, 'id': id}), headers: {'Content-Type': 'application/json'});
      if (res.statusCode == 200) {
        _markUserForceLoggedOut(id);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$id 강제 로그아웃 완료')));
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('강제 로그아웃 요청 실패')));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('강제 로그아웃 요청 오류')));
      }
    }
  }

  void _markUserForceLoggedOut(String userId) {
    final name = monitoredLocations[userId]?.displayName ?? userId;
    setState(() {
      final current = monitoredLocations[userId];
      if (current != null) {
        monitoredLocations[userId] = current.copyWith(isOnline: false);
      }
      for (final room in rooms.values) {
        room.remove(userId);
      }
      activityLogs.insert(
        0,
        ActivityLog(
          event: 'admin_force_logout',
          userId: userId,
          displayName: name,
          latitude: null,
          longitude: null,
          timestamp: DateTime.now(),
          roomId: filterRoom,
        ),
      );
    });
  }

  Future<void> _confirmForceLogout(String userId, {String? displayName}) async {
    if (userId.trim().isEmpty) return;
    final name = displayName ?? monitoredLocations[userId]?.displayName ?? userId;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('강제 로그아웃'),
        content: Text('$name ($userId) 사용자를 강제 로그아웃하시겠습니까?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('취소')),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('로그아웃'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _adminForceLogout('user', userId);
    }
  }

  Future<void> _promptForceLogoutUserId() async {
    final ctrl = TextEditingController();
    final userId = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('특정 유저 강제 로그아웃'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'User ID',
            hintText: '강제 로그아웃할 userId 입력',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('취소')),
          TextButton(onPressed: () => Navigator.of(context).pop(ctrl.text.trim()), child: const Text('다음')),
        ],
      ),
    );
    if (userId != null && userId.isNotEmpty) {
      await _confirmForceLogout(userId);
    }
  }

  Widget _buildUserActionChip(String uid) {
    final displayName = monitoredLocations[uid]?.displayName ?? uid;
    return PopupMenuButton<String>(
      tooltip: '유저 관리',
      onSelected: (action) async {
        if (action == 'map') {
          final loc = monitoredLocations[uid];
          if (loc != null) {
            mapController?.animateCamera(CameraUpdate.newLatLngZoom(loc.position, 15));
          } else {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('위치 정보가 없습니다')));
          }
        } else if (action == 'logout') {
          await _confirmForceLogout(uid, displayName: displayName);
        } else if (action == 'ban') {
          await _adminBan('user', uid);
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'map', child: ListTile(leading: Icon(Icons.map), title: Text('지도에서 보기'))),
        const PopupMenuItem(value: 'logout', child: ListTile(leading: Icon(Icons.logout, color: Colors.orange), title: Text('강제 로그아웃'))),
        const PopupMenuItem(value: 'ban', child: ListTile(leading: Icon(Icons.block, color: Colors.red), title: Text('차단'))),
      ],
      child: InputChip(
        avatar: Icon(
          monitoredLocations[uid]?.isOnline == true ? Icons.circle : Icons.circle_outlined,
          size: 14,
          color: monitoredLocations[uid]?.isOnline == true ? Colors.green : Colors.grey,
        ),
        label: Text(displayName, style: const TextStyle(fontSize: 12)),
      ),
    );
  }

  Future<void> _adminSearch(String q) async {
    final base = _socketServerUrl.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$base/admin/search?q=${Uri.encodeComponent(q)}');
    try {
      final res = await http.get(uri);
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body);
        // handle results (rooms/users)
        final roomsRes = (body['rooms'] as List<dynamic>?)?.cast<String>() ?? [];
        final usersRes = (body['users'] as List<dynamic>?)?.cast<String>() ?? [];
        // show simple dialog with results
        showDialog(context: context, builder: (_) => AlertDialog(
          title: const Text('Search results'),
          content: SizedBox(width: 400, child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (roomsRes.isNotEmpty) ...[
              const Text('Rooms', style: TextStyle(fontWeight: FontWeight.bold)),
              ...roomsRes.take(10).map((r) => ListTile(title: Text(r), onTap: () { Navigator.of(context).pop(); _selectRoom(r); })),
            ],
            if (usersRes.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text('Users', style: TextStyle(fontWeight: FontWeight.bold)),
              ...usersRes.take(10).map((u) => ListTile(title: Text(u), trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(icon: const Icon(Icons.logout), onPressed: () { Navigator.of(context).pop(); _adminForceLogout('user', u); }),
                IconButton(icon: const Icon(Icons.block), onPressed: () { Navigator.of(context).pop(); _adminBan('user', u); }),
              ]))),
            ],
          ])),
          actions: [ TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')) ],
        ));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Search failed')));
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Search error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 700;
    final onlineCount = monitoredLocations.values.where((m) => m.isOnline).length;

    if (isMobile) {
      return DefaultTabController(
        length: 3,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Admin (Mobile)'),
            bottom: const TabBar(
              tabs: [
                Tab(icon: Icon(Icons.map), text: 'Map'),
                Tab(icon: Icon(Icons.meeting_room), text: 'Rooms'),
                Tab(icon: Icon(Icons.list), text: 'Logs'),
              ],
            ),
            actions: [
              IconButton(
                tooltip: '특정 유저 강제 로그아웃',
                icon: const Icon(Icons.logout),
                onPressed: _promptForceLogoutUserId,
              ),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Center(child: Text('$onlineCount online', style: const TextStyle(fontWeight: FontWeight.w700))),
              ),
            ],
          ),
          body: TabBarView(
            children: [
              // Map tab
              kIsWeb
                  ? GoogleMap(
                      onMapCreated: (c) => mapController = c,
                      initialCameraPosition: CameraPosition(
                        target: monitoredLocations.isNotEmpty ? monitoredLocations.values.first.position : const LatLng(37.2939, 127.0163),
                        zoom: 12,
                      ),
                      markers: _createMarkers(),
                      circles: _createAccuracyCircles(),
                    )
                  : const Center(child: Text('Map available on web')),
              // Rooms tab
              Padding(
                padding: const EdgeInsets.all(8),
                child: ListView(
                  children: rooms.keys.map((r) {
                    final count = rooms[r]?.length ?? 0;
                    return ListTile(
                      title: Text(r),
                      subtitle: Text('$count users'),
                      onTap: () => _selectRoom(r),
                    );
                  }).toList(),
                ),
              ),
              // Logs tab
              Padding(
                padding: const EdgeInsets.all(8),
                child: activityLogs.isEmpty
                    ? const Center(child: Text('No activity'))
                    : ListView.builder(
                        itemCount: activityLogs.length,
                        itemBuilder: (context, idx) {
                          final log = activityLogs[idx];
                          return ListTile(
                            title: Text('${log.displayName} (${log.event})'),
                            subtitle: Text(log.roomId ?? ''),
                            trailing: log.userId.isNotEmpty
                                ? IconButton(
                                    tooltip: '강제 로그아웃',
                                    icon: const Icon(Icons.logout, size: 20),
                                    onPressed: () => _confirmForceLogout(log.userId, displayName: log.displayName),
                                  )
                                : null,
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      );
    }

    // Desktop layout (three columns)
    final roomIds = _filteredSortedRoomIds();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin Dashboard'),
        centerTitle: false,
        backgroundColor: const Color(0xFFF5F7FA),
        foregroundColor: const Color(0xFF172033),
        elevation: 0,
        actions: [
          IconButton(
            tooltip: 'Refresh room state',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              socket.emit('join_room', filterRoom);
              socket.emit('request_rooms');
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Requested room state and rooms list')));
            },
          ),
          IconButton(
            tooltip: '특정 유저 강제 로그아웃',
            icon: const Icon(Icons.logout),
            onPressed: _promptForceLogoutUserId,
          ),
          IconButton(
            tooltip: 'Search',
            icon: const Icon(Icons.search),
            onPressed: () async {
              final q = await showDialog<String>(context: context, builder: (_) {
                final ctrl = TextEditingController();
                return AlertDialog(
                  title: const Text('Search rooms/users'),
                  content: TextField(controller: ctrl, decoration: const InputDecoration(hintText: 'Enter query')),
                  actions: [ TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')), TextButton(onPressed: () => Navigator.of(context).pop(ctrl.text.trim()), child: const Text('Search')) ],
                );
              });
              if (q != null && q.isNotEmpty) _adminSearch(q);
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // header
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: Color(0xFFE4E8F0)))),
            child: Column(
              children: [
                Row(
                  children: [
                    const Icon(Icons.admin_panel_settings, color: Color(0xFF2563EB)),
                    const SizedBox(width: 8),
                    const Expanded(child: Text('Admin Real-time Monitoring', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
                    Text('$onlineCount/${monitoredLocations.length}', style: const TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF2563EB))),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 220,
                      child: TextField(
                        decoration: InputDecoration(labelText: 'Room to monitor', isDense: true, border: OutlineInputBorder(borderRadius: BorderRadius.circular(8))),
                        controller: TextEditingController(text: filterRoom),
                        onSubmitted: (v) {
                          setState(() {
                            filterRoom = v.trim();
                            monitoredLocations.clear();
                            activityLogs.clear();
                          });
                          socket.emit('join_room', filterRoom);
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 36,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: rooms.keys.take(12).map((r) {
                      final count = rooms[r]?.length ?? 0;
                      final selected = r == filterRoom;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text('$r ($count)'),
                          selected: selected,
                          onSelected: (_) => _selectRoom(r),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
          ),

          // main area
          Expanded(
            child: Row(
              children: [
                // rooms list
                Container(
                  width: 300,
                  margin: const EdgeInsets.fromLTRB(12, 12, 6, 12),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFFE4E8F0))),
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            const Icon(Icons.meeting_room, color: Color(0xFF2563EB)),
                            const SizedBox(width: 8),
                            const Expanded(child: Text('Active Rooms', style: TextStyle(fontWeight: FontWeight.w800))),
                            IconButton(
                              icon: Icon(sortByCountDesc ? Icons.sort_by_alpha : Icons.sort),
                              tooltip: 'Toggle sort',
                              onPressed: () {
                                setState(() {
                                  sortByCountDesc = !sortByCountDesc;
                                });
                              },
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: TextField(
                          decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search rooms', isDense: true, border: OutlineInputBorder()),
                          onChanged: (v) => setState(() => roomSearch = v.trim()),
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Divider(height: 1),
                      Expanded(
                        child: roomIds.isEmpty
                            ? const Center(child: Text('No rooms detected yet.'))
                            : ListView.builder(
                                padding: const EdgeInsets.all(8),
                                itemCount: roomIds.length,
                                itemBuilder: (context, index) {
                                  final r = roomIds[index];
                                  final users = rooms[r] ?? <String>{};
                                  final lastActivity = activityLogs.firstWhere(
                                    (l) => l.roomId == r,
                                    orElse: () => ActivityLog(
                                      event: 'none',
                                      userId: '',
                                      displayName: '',
                                      latitude: null,
                                      longitude: null,
                                      timestamp: DateTime.fromMillisecondsSinceEpoch(0),
                                      roomId: r,
                                    ),
                                  );
                                  return Card(
                                    margin: const EdgeInsets.symmetric(vertical: 6),
                                    child: ExpansionTile(
                                      initiallyExpanded: r == filterRoom,
                                      title: Row(
                                        children: [
                                          Expanded(child: Text(r, maxLines: 1, overflow: TextOverflow.ellipsis)),
                                          const SizedBox(width: 8),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                            decoration: BoxDecoration(color: const Color(0xFF2563EB).withOpacity(0.08), borderRadius: BorderRadius.circular(12)),
                                            child: Text('${users.length}', style: const TextStyle(color: Color(0xFF2563EB), fontWeight: FontWeight.w800)),
                                          ),
                                        ],
                                      ),
                                      subtitle: Text(
                                        lastActivity.timestamp.millisecondsSinceEpoch == 0
                                            ? 'No recent activity'
                                            : 'Last: ${lastActivity.timestamp.hour.toString().padLeft(2, '0')}:${lastActivity.timestamp.minute.toString().padLeft(2, '0')}',
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                      children: [
                                        Padding(
                                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.stretch,
                                            children: [
                                              Wrap(
                                                spacing: 6,
                                                runSpacing: 6,
                                                children: users.map(_buildUserActionChip).toList(),
                                              ),
                                              const SizedBox(height: 8),
                                              Row(
                                                children: [
                                                  ElevatedButton(onPressed: () => _selectRoom(r), child: const Text('Monitor')),
                                                  const SizedBox(width: 8),
                                                  OutlinedButton(
                                                    onPressed: () {
                                                      final firstUser = users.isNotEmpty ? users.first : null;
                                                      if (firstUser != null && monitoredLocations.containsKey(firstUser)) {
                                                        final pos = monitoredLocations[firstUser]!.position;
                                                        mapController?.animateCamera(CameraUpdate.newLatLngZoom(pos, 14));
                                                      } else {
                                                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No location to center')));
                                                      }
                                                    },
                                                    child: const Text('Center'),
                                                  ),
                                                ],
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: ElevatedButton.icon(
                          onPressed: () {
                            socket.emit('request_rooms');
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Requested rooms list from server')));
                          },
                          icon: const Icon(Icons.sync),
                          label: const Text('Refresh rooms'),
                        ),
                      ),
                    ],
                  ),
                ),

                // map
                Expanded(
                  flex: 2,
                  child: Container(
                    margin: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFFE4E8F0))),
                    child: kIsWeb
                        ? GoogleMap(
                            onMapCreated: (controller) {
                              mapController = controller;
                            },
                            initialCameraPosition: CameraPosition(
                              target: monitoredLocations.isNotEmpty ? monitoredLocations.values.first.position : const LatLng(37.2939, 127.0163),
                              zoom: 12,
                            ),
                            markers: _createMarkers(),
                            circles: _createAccuracyCircles(),
                            myLocationEnabled: false,
                            myLocationButtonEnabled: false,
                          )
                        : const Center(child: Text('Map is available on web.')),
                  ),
                ),

                // logs
                Expanded(
                  flex: 1,
                  child: Container(
                    margin: const EdgeInsets.fromLTRB(6, 12, 12, 12),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFFE4E8F0))),
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: const [
                              Icon(Icons.list, color: Color(0xFF2563EB)),
                              SizedBox(width: 8),
                              Text('Activity Logs', style: TextStyle(fontWeight: FontWeight.w800)),
                            ],
                          ),
                        ),
                        const Divider(height: 1),
                        Expanded(
                          child: activityLogs.isEmpty
                              ? const Center(child: Text('No activity yet.'))
                              : ListView.separated(
                                  padding: const EdgeInsets.all(8),
                                  itemCount: activityLogs.length,
                                  separatorBuilder: (_, __) => const Divider(),
                                  itemBuilder: (context, index) {
                                    final log = activityLogs[index];
                                    return ListTile(
                                      dense: true,
                                      leading: CircleAvatar(
                                        backgroundColor: Colors.grey.shade100,
                                        foregroundColor: Colors.black87,
                                        child: Text(log.displayName.isNotEmpty ? log.displayName[0].toUpperCase() : '?'),
                                      ),
                                      title: Text('${log.displayName} (${log.userId})'),
                                      subtitle: Text(
                                        '${log.event}${log.roomId != null ? ' @ ${log.roomId}' : ''}\n'
                                        '${log.latitude != null ? '${log.latitude!.toStringAsFixed(5)}, ${log.longitude!.toStringAsFixed(5)}' : 'no location'}',
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      trailing: log.userId.isNotEmpty
                                          ? Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Text(
                                                  '${log.timestamp.hour.toString().padLeft(2, '0')}:${log.timestamp.minute.toString().padLeft(2, '0')}',
                                                  style: const TextStyle(fontSize: 12, color: Color(0xFF687386)),
                                                ),
                                                IconButton(
                                                  tooltip: '강제 로그아웃',
                                                  icon: const Icon(Icons.logout, size: 18),
                                                  onPressed: () => _confirmForceLogout(log.userId, displayName: log.displayName),
                                                ),
                                              ],
                                            )
                                          : Text(
                                              '${log.timestamp.hour.toString().padLeft(2, '0')}:${log.timestamp.minute.toString().padLeft(2, '0')}',
                                              style: const TextStyle(fontSize: 12, color: Color(0xFF687386)),
                                            ),
                                      onTap: () {
                                        if (log.latitude != null && log.longitude != null) {
                                          final pos = LatLng(log.latitude!, log.longitude!);
                                          mapController?.animateCamera(CameraUpdate.newLatLngZoom(pos, 15));
                                        }
                                      },
                                    );
                                  },
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// ---------------------------
/// AdminGate: simple token gate stored in localStorage (web)
/// ---------------------------
class AdminGate extends StatefulWidget {
  final Widget child;
  const AdminGate({required this.child, super.key});
  @override
  State<AdminGate> createState() => _AdminGateState();
}

class _AdminGateState extends State<AdminGate> {
  final TextEditingController _tokenController = TextEditingController();
  bool _authorized = false;
  static const _hardcodedToken = 'yejun1955!';
  static const _storageKey = 'admin_session_token';

  @override
  void initState() {
    super.initState();
    try {
      if (kIsWeb) {
        final stored = html.window.localStorage[_storageKey];
        if (stored != null && stored == _hardcodedToken) setState(() => _authorized = true);
      }
    } catch (_) {}
  }

  void _login() {
    final input = _tokenController.text.trim();
    if (input == _hardcodedToken) {
      try {
        if (kIsWeb) html.window.localStorage[_storageKey] = _hardcodedToken;
      } catch (_) {}
      setState(() => _authorized = true);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('토큰이 일치하지 않습니다')));
    }
  }

  void _logout() {
    try {
      if (kIsWeb) html.window.localStorage.remove(_storageKey);
    } catch (_) {}
    setState(() {
      _authorized = false;
      _tokenController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_authorized) {
      return Scaffold(appBar: AppBar(title: const Text('Admin (authenticated)'), actions: [ IconButton(icon: const Icon(Icons.logout), tooltip: 'Logout admin', onPressed: _logout) ]), body: widget.child);
    }
    return Scaffold(appBar: AppBar(title: const Text('Admin Login')), body: Center(child: SizedBox(width: 420, child: Card(margin: const EdgeInsets.all(16), child: Padding(padding: const EdgeInsets.all(18), child: Column(mainAxisSize: MainAxisSize.min, children: [ const Text('관리자 토큰을 입력하세요', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)), const SizedBox(height: 12), TextField(controller: _tokenController, obscureText: true, decoration: const InputDecoration(labelText: 'Admin token', border: OutlineInputBorder()), onSubmitted: (_) => _login()), const SizedBox(height: 12), Row(mainAxisAlignment: MainAxisAlignment.end, children: [ TextButton(onPressed: () { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('관리자 토큰을 관리자에게 문의하세요'))); }, child: const Text('도움말')), const SizedBox(width: 8), ElevatedButton(onPressed: _login, child: const Text('로그인')), ],), ],), ), ), ), ), );
  }
}

/// ---------------------------
/// _InfoPill: small pill widget used in headers
/// ---------------------------
class _InfoPill extends StatelessWidget {
  const _InfoPill({required this.icon, required this.label, required this.color, super.key});
  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 220),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
