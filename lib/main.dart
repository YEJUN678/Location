import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

void main() => runApp(const MyApp());

const String configuredSocketServerUrl = String.fromEnvironment(
  'SOCKET_SERVER_URL',
);
const String configuredUserId = String.fromEnvironment('USER_ID');
const String configuredDisplayName = String.fromEnvironment('DISPLAY_NAME');
const String configuredRoomId = String.fromEnvironment(
  'ROOM_ID',
  defaultValue: 'meetup_room_1004',
);

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

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Live Location',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2563EB),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF5F7FA),
        useMaterial3: true,
      ),
      home: const LocationShareScreen(),
    );
  }
}

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

  @override
  void initState() {
    super.initState();
    displayName = configuredDisplayName.isNotEmpty
        ? configuredDisplayName
        : userId;
    roomId = _initialRoomId();
    displayNameController = TextEditingController(text: displayName);
    roomController = TextEditingController(text: roomId);
    initServerConnection();
    startLocationTracking();
  }

  String _initialRoomId() {
    final linkedRoom = Uri.base.queryParameters['room']?.trim();
    if (linkedRoom != null && linkedRoom.isNotEmpty) {
      return linkedRoom;
    }
    return configuredRoomId;
  }

  String get _socketServerUrl {
    if (configuredSocketServerUrl.isNotEmpty) {
      return configuredSocketServerUrl;
    }

    if (kIsWeb) {
      final baseUri = Uri.base;
      return '${baseUri.scheme}://${baseUri.host}${baseUri.hasPort ? ':${baseUri.port}' : ''}';
    }

    return 'http://localhost:3000';
  }

  void initServerConnection() {
    socket = io.io(
      _socketServerUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .disableAutoConnect()
          .build(),
    );

    socket.connect();

    socket.onConnect((_) {
      setState(() {
        connectionStatus = 'Connected';
      });
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

    setState(() {
      friendsLocations[friendId] = FriendLocation(
        displayName: friendName?.isNotEmpty == true ? friendName! : friendId,
        position: LatLng(latitude.toDouble(), longitude.toDouble()),
        accuracy: (data['accuracy'] as num?)?.toDouble(),
        address: address?.isNotEmpty == true
            ? address!
            : 'Address unavailable',
        updatedAt: DateTime.now(),
        isOnline: true,
      );
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

  void _joinRoom(String nextRoom, {bool clearFriends = true}) {
    setState(() {
      roomId = nextRoom;
      roomController.text = nextRoom;
      if (clearFriends) {
        friendsLocations.clear();
      }
    });

    socket.emit('join_room', nextRoom);
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
  }

  Future<void> startLocationTracking() async {
    final permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
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
      final currentPosition = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      setState(() {
        myCurrentLatLng = LatLng(
          currentPosition.latitude,
          currentPosition.longitude,
        );
        myAccuracy = currentPosition.accuracy;
      });
      _emitCurrentLocation();
    } catch (_) {
      _emitCurrentLocation();
    }

    Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen((position) {
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
    return id.codeUnits.fold<int>(0, (sum, code) => sum + code) %
        friendColors.length;
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
        distance = _calculateDistance(
          myCurrentLatLng!,
          friendLocation.position,
        );
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
            snippet:
                '${_formatDistance(distance)}, about $walkingMinutes min walk',
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

  void _focusFriend(FriendLocation friend) {
    followMyLocation = false;
    mapController?.animateCamera(
      CameraUpdate.newLatLngZoom(friend.position, 16),
    );
  }

  void _recenterOnMe() {
    final current = myCurrentLatLng;
    if (current == null) return;

    setState(() {
      followMyLocation = true;
    });
    mapController?.animateCamera(CameraUpdate.newLatLngZoom(current, 16));
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
      ),
      body: Column(
        children: [
          _buildHeader(isConnected),
          Expanded(
            flex: 3,
            child: _buildMapPane(),
          ),
          Expanded(
            flex: 2,
            child: _buildFriendsPanel(),
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
        border: Border(
          bottom: BorderSide(color: Color(0xFFE4E8F0)),
        ),
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
                  decoration: _inputDecoration(
                    label: 'My name',
                    icon: Icons.person_outline,
                  ),
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
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
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
                  decoration: _inputDecoration(
                    label: 'Room',
                    icon: Icons.meeting_room_outlined,
                  ),
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
                  style: IconButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
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
                  style: IconButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
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
                color: isConnected
                    ? const Color(0xFF12805C)
                    : const Color(0xFFB42318),
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

  InputDecoration _inputDecoration({
    required String label,
    required IconData icon,
  }) {
    return InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon),
      filled: true,
      fillColor: const Color(0xFFF7F9FC),
      isDense: true,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Color(0xFFD7DDE8)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Color(0xFFD7DDE8)),
      ),
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
          initialCameraPosition: CameraPosition(
            target: myCurrentLatLng!,
            zoom: 14,
          ),
          markers: _createMarkers(),
          circles: _createAccuracyCircles(),
          myLocationEnabled: false,
          myLocationButtonEnabled: false,
        ),
        Positioned(
          left: 16,
          top: 16,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x22000000),
                  blurRadius: 10,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.near_me,
                    size: 18,
                    color: Color(0xFF2563EB),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    displayName,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF172033),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          right: 16,
          bottom: 16,
          child: FloatingActionButton.small(
            onPressed: _recenterOnMe,
            tooltip: 'Follow my location',
            child: Icon(
              followMyLocation ? Icons.my_location : Icons.location_searching,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFriendsPanel() {
    final onlineCount = friendsLocations.values
        .where((friend) => friend.isOnline)
        .length;

    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(
          top: BorderSide(color: Color(0xFFE4E8F0)),
        ),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(
              children: [
                const Icon(Icons.route, color: Color(0xFF2563EB)),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Friends nearby',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF172033),
                    ),
                  ),
                ),
                Text(
                  '$onlineCount/${friendsLocations.length}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF2563EB),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: friendsLocations.isEmpty
                ? const Center(
                    child: Text(
                      'Share this room link with a friend to see them here.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xFF687386)),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    itemCount: friendsLocations.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final entry = friendsLocations.entries.elementAt(index);
                      final friend = entry.value;
                      final distance = myCurrentLatLng != null
                          ? _calculateDistance(
                              myCurrentLatLng!,
                              friend.position,
                            )
                          : 0.0;
                      final walkTime = _calculateWalkingTime(distance);
                      final color = friendColors[_friendColorIndex(entry.key)];

                      return Opacity(
                        opacity: friend.isOnline ? 1 : 0.48,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: const Color(0xFFF8FAFD),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: friend.isOnline
                                  ? color.withValues(alpha: 0.35)
                                  : const Color(0xFFE4E8F0),
                            ),
                          ),
                          child: ListTile(
                            onTap: () => _focusFriend(friend),
                            leading: CircleAvatar(
                              backgroundColor: color.withValues(alpha: 0.16),
                              foregroundColor: color,
                              child: Text(
                                friend.displayName.characters.first
                                    .toUpperCase(),
                              ),
                            ),
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    friend.displayName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      color: Color(0xFF172033),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  friend.isOnline ? 'Online' : 'Offline',
                                  style: TextStyle(
                                    color: friend.isOnline
                                        ? const Color(0xFF12805C)
                                        : const Color(0xFF687386),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                            subtitle: Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                '${friend.address}\n'
                                '${_formatDistance(distance)} away, $walkTime min walk\n'
                                '${_formatAccuracy(friend.accuracy)}',
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xFF687386),
                                  height: 1.25,
                                ),
                              ),
                            ),
                            trailing: const Icon(
                              Icons.chevron_right,
                              color: Color(0xFF687386),
                            ),
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
    socket.disconnect();
    displayNameController.dispose();
    roomController.dispose();
    mapController?.dispose();
    super.dispose();
  }
}

class _InfoPill extends StatelessWidget {
  const _InfoPill({
    required this.icon,
    required this.label,
    required this.color,
  });

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
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
