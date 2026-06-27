import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
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

class FriendLocation {
  const FriendLocation({
    required this.position,
    required this.displayName,
  });

  final LatLng position;
  final String displayName;
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Live Location',
      theme: ThemeData(primarySwatch: Colors.blue),
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

  GoogleMapController? mapController;

  final String roomId = configuredRoomId;
  final String userId = configuredUserId.isNotEmpty
      ? configuredUserId
      : 'User_${DateTime.now().millisecondsSinceEpoch % 100000}';

  late String displayName;
  LatLng? myCurrentLatLng;
  final Map<String, FriendLocation> friendsLocations = {};
  String connectionStatus = 'Waiting for server...';

  @override
  void initState() {
    super.initState();
    displayName = configuredDisplayName.isNotEmpty
        ? configuredDisplayName
        : userId;
    displayNameController = TextEditingController(text: displayName);
    initServerConnection();
    startLocationTracking();
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
      socket.emit('join_room', roomId);
    });

    socket.onConnectError((data) {
      setState(() {
        connectionStatus = 'Connection failed';
      });
    });

    socket.on('location_changed', (data) {
      if (data['userId'] == userId) return;

      final friendId = data['userId'] as String;
      final friendName = (data['displayName'] as String?)?.trim();

      setState(() {
        friendsLocations[friendId] = FriendLocation(
          displayName: friendName?.isNotEmpty == true ? friendName! : friendId,
          position: LatLng(
            (data['latitude'] as num).toDouble(),
            (data['longitude'] as num).toDouble(),
          ),
        );
      });
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

  void _emitCurrentLocation() {
    final current = myCurrentLatLng;
    if (current == null) return;

    socket.emit('update_location', {
      'roomId': roomId,
      'userId': userId,
      'displayName': displayName,
      'latitude': current.latitude,
      'longitude': current.longitude,
    });
  }

  Future<void> startLocationTracking() async {
    final permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      setState(() {
        myCurrentLatLng = const LatLng(37.5559, 126.9723);
        connectionStatus = 'Location permission denied';
      });
      _emitCurrentLocation();
      return;
    }

    setState(() {
      myCurrentLatLng = const LatLng(37.2939, 127.0163);
    });

    Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen((position) {
      final newLatLng = LatLng(position.latitude, position.longitude);

      setState(() {
        myCurrentLatLng = newLatLng;
      });

      mapController?.animateCamera(CameraUpdate.newLatLng(newLatLng));
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

  Set<Marker> _createMarkers() {
    final markers = <Marker>{};

    if (myCurrentLatLng != null) {
      markers.add(
        Marker(
          markerId: const MarkerId('my_location'),
          position: myCurrentLatLng!,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
          infoWindow: InfoWindow(title: 'Me ($displayName)', snippet: userId),
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

      markers.add(
        Marker(
          markerId: MarkerId(friendId),
          position: friendLocation.position,
          infoWindow: InfoWindow(
            title: friendLocation.displayName,
            snippet:
                '${distance.toStringAsFixed(2)} km, about $walkingMinutes min walk',
          ),
        ),
      );
    });

    return markers;
  }

  @override
  Widget build(BuildContext context) {
    final isConnected = connectionStatus == 'Connected';

    return Scaffold(
      appBar: AppBar(title: const Text('Live Location')),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            color: Colors.blueGrey,
            width: double.infinity,
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
                        decoration: const InputDecoration(
                          labelText: 'My display name',
                          filled: true,
                          fillColor: Colors.white,
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      onPressed: _saveDisplayName,
                      icon: const Icon(Icons.check),
                      tooltip: 'Save name',
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text('User ID: $userId'),
                Text('Room ID: $roomId'),
                Text(
                  'Server: $_socketServerUrl',
                  style: const TextStyle(fontSize: 12),
                ),
                Text(
                  'Status: $connectionStatus',
                  style: TextStyle(
                    color: isConnected ? Colors.greenAccent : Colors.redAccent,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 3,
            child: !kIsWeb
                ? const Center(child: Text('Google Map is shown on web.'))
                : myCurrentLatLng == null
                    ? const Center(child: CircularProgressIndicator())
                    : GoogleMap(
                        onMapCreated: (controller) {
                          mapController = controller;
                        },
                        initialCameraPosition: CameraPosition(
                          target: myCurrentLatLng!,
                          zoom: 14,
                        ),
                        markers: _createMarkers(),
                        myLocationEnabled: false,
                        myLocationButtonEnabled: true,
                      ),
          ),
          const Padding(
            padding: EdgeInsets.all(8),
            child: Text(
              'Friends, distance, and walking time',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            flex: 2,
            child: friendsLocations.isEmpty
                ? const Center(child: Text('No friends in this room yet.'))
                : ListView(
                    children: friendsLocations.entries.map((entry) {
                      final friend = entry.value;
                      final distance = myCurrentLatLng != null
                          ? _calculateDistance(
                              myCurrentLatLng!,
                              friend.position,
                            )
                          : 0.0;
                      final walkTime = _calculateWalkingTime(distance);

                      return Card(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        child: ListTile(
                          leading: const Icon(
                            Icons.directions_walk,
                            color: Colors.orange,
                          ),
                          title: Text(
                            friend.displayName,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text(
                            'ID: ${entry.key}\n'
                            'Lat: ${friend.position.latitude.toStringAsFixed(4)} / '
                            'Lng: ${friend.position.longitude.toStringAsFixed(4)}',
                          ),
                          trailing: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                '${distance.toStringAsFixed(2)} km',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Colors.blue,
                                ),
                              ),
                              Text(
                                '$walkTime min',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
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
    mapController?.dispose();
    super.dispose();
  }
}
