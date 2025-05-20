// File: lib/features/receipts/receipt_capture_screen.dart

import 'dart:io'; // For File type
import 'package:flutter/material.dart';
import 'package:camera/camera.dart'; // Camera package
import 'package:image_picker/image_picker.dart'; // Image picker
import 'package:permission_handler/permission_handler.dart'; // Permissions
import 'dart:convert'; // For base64Encode
import 'dart:typed_data'; // For Uint8List
import 'package:cloud_functions/cloud_functions.dart';

class ReceiptCaptureScreen extends StatefulWidget {
  const ReceiptCaptureScreen({super.key});

  @override
  State<ReceiptCaptureScreen> createState() => _ReceiptCaptureScreenState();
}

class _ReceiptCaptureScreenState extends State<ReceiptCaptureScreen> {
  CameraController? _cameraController;
  List<CameraDescription>? _cameras;
  Future<void>? _initializeControllerFuture;
  XFile? _imageFile; // Holds the path of the captured/picked image
  bool _isInitializing = true; // Track initialization state
  bool _isProcessing = false; // Track submission state
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _initializeCameraAndPermissions();
  }

  Future<void> _initializeCameraAndPermissions() async {
    setState(() => _isInitializing = true);
    _errorMessage = null; // Clear previous errors

    // 1. Request Permissions
    Map<Permission, PermissionStatus> statuses = await [
      Permission.camera,
      Permission.storage, // Needed for image picker on older Android
      // Permission.photos, // Use for newer iOS/Android gallery access
    ].request();

    PermissionStatus? cameraStatus = statuses[Permission.camera];
    // PermissionStatus? storageStatus = statuses[Permission.storage] ?? statuses[Permission.photos];

    if (cameraStatus != PermissionStatus.granted) {
      _errorMessage = "Camera permission is required to take photos.";
      print(_errorMessage);
      // Optionally guide user to settings using openAppSettings() from permission_handler
    }
    // Can add check for storage/photos permission if needed for picker reliability

    // 2. Initialize Camera (only if permission granted)
    if (cameraStatus == PermissionStatus.granted) {
      try {
        _cameras = await availableCameras();
        if (_cameras != null && _cameras!.isNotEmpty) {
          // Select the first available back camera
          CameraDescription selectedCamera = _cameras!.firstWhere(
              (cam) => cam.lensDirection == CameraLensDirection.back,
              orElse: () => _cameras!.first); // Fallback to first camera

          _cameraController = CameraController(
            selectedCamera,
            ResolutionPreset.high, // Choose preset (high, medium, low)
            enableAudio: false, // We don't need audio for receipts
            imageFormatGroup: ImageFormatGroup.jpeg, // Or YUV420 for processing
          );

          // Store the future for the FutureBuilder
          _initializeControllerFuture = _cameraController!.initialize();
          print("Camera initialized successfully.");
        } else {
          _errorMessage = "No cameras available on this device.";
          print(_errorMessage);
        }
      } catch (e) {
        _errorMessage = "Error initializing camera: ${e.toString()}";
        print(_errorMessage);
        _cameraController = null; // Ensure controller is null on error
      }
    }

    if (mounted) {
      setState(() => _isInitializing = false);
    }
  }

  @override
  void dispose() {
    // Dispose of the controller when the widget is disposed.
    _cameraController?.dispose();
    print("Camera controller disposed.");
    super.dispose();
  }

  // --- Action: Take Picture ---
  Future<void> _takePicture() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      print('Error: Camera controller not initialized.');
      return;
    }
    // Ensure initialization future is complete
    try {
      await _initializeControllerFuture;

      // Attempt to take a picture and get the file `XFile`
      final XFile file = await _cameraController!.takePicture();
      print("Picture taken: ${file.path}");
      if (mounted) {
        setState(() {
          _imageFile = file;
        });
      }
    } catch (e) {
      print('Error taking picture: $e');
       if (mounted) {
         ScaffoldMessenger.of(context).showSnackBar(
             SnackBar(content: Text('Error taking picture: ${e.toString()}'))
         );
       }
    }
  }

  // --- Action: Pick Image from Gallery ---
  Future<void> _pickImage() async {
     try {
       final ImagePicker picker = ImagePicker();
       // Pick an image
       final XFile? image = await picker.pickImage(source: ImageSource.gallery);
       if (image != null && mounted) {
         print("Image picked: ${image.path}");
         setState(() {
           _imageFile = image;
         });
       } else {
         print("Image picking cancelled.");
       }
     } catch (e) {
        print('Error picking image: $e');
        if (mounted) {
         ScaffoldMessenger.of(context).showSnackBar(
             SnackBar(content: Text('Error picking image: ${e.toString()}'))
         );
       }
     }
  }

  // --- Action: Submit Image ---
  Future<void> _submitImage() async {
     if (_imageFile == null || _isProcessing) return;

      setState(() => _isProcessing = true);
      _errorMessage = null; // Clear previous errors
      print("Submitting image: ${_imageFile!.path}");

      final scaffoldMessenger = ScaffoldMessenger.of(context); // Capture context

      try {
        // 1. Read image bytes
        final Uint8List imageBytes = await _imageFile!.readAsBytes();

        // 2. Encode to Base64
        final String base64String = base64Encode(imageBytes);

        // 3. Call Cloud Function
        print("Calling processReceiptImage Cloud Function...");
        final functions = FirebaseFunctions.instance;
        final callable = functions.httpsCallable(
            'processReceiptImage',
             // Optional: Increase timeout on client if needed, but backend timeout is usually dominant
             // options: HttpsCallableOptions(timeout: const Duration(seconds: 120)),
        );
        final results = await callable.call(<String, dynamic>{
          'imageDataBase64': base64String,
        });

        // 4. Handle response
        if (results.data['success'] == true) {
            final receiptId = results.data['receiptId'];
            print('Successfully processed receipt. Firestore ID: $receiptId');
            scaffoldMessenger.showSnackBar(
               SnackBar(content: Text('Receipt processed successfully (ID: $receiptId)')),
            );
            // Optionally navigate back or clear image
            if (mounted) {
               setState(() => _imageFile = null); // Clear image preview
               // Consider Navigator.pop(context); // Go back automatically?
            }
        } else {
            throw Exception(results.data['message'] ?? 'Backend indicated failure during receipt processing.');
        }

      } on FirebaseFunctionsException catch (e) {
        print("FirebaseFunctionsException calling processReceiptImage: ${e.code} - ${e.message} - Details: ${e.details}");
        _errorMessage = 'Error processing receipt: ${e.message ?? e.code}';
        scaffoldMessenger.showSnackBar(
           SnackBar(content: Text(_errorMessage!)),
        );
      } catch (e) {
         print("Error submitting image: $e");
         _errorMessage = 'An unexpected error occurred: ${e.toString()}';
          scaffoldMessenger.showSnackBar(
           SnackBar(content: Text(_errorMessage!)),
         );
      } finally {
        // Ensure processing state is reset
         if (mounted) {
           setState(() => _isProcessing = false);
         }
      }
  }

  // --- Action: Clear Selected Image ---
  void _clearImage() {
    setState(() {
      _imageFile = null;
    });
  }


  // --- Build UI ---
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan Receipt')),
      body: Column( // Use column for layout
        children: [
          // --- Main Area: Camera Preview or Image Preview ---
          Expanded(
            child: _buildContentView(), // Use helper to build main area
          ),

          // --- Bottom Control Bar ---
          Container(
            padding: const EdgeInsets.all(15.0),
            color: Colors.black.withOpacity(0.5), // Semi-transparent background
            child: _buildControlBar(), // Use helper for controls
          ),
        ],
      ),
    );
  }

  // --- Helper: Build Content View (Camera or Image) ---
  Widget _buildContentView() {
    if (_isInitializing) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_errorMessage != null) {
      return Center(child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Text('Error: $_errorMessage', style: const TextStyle(color: Colors.red), textAlign: TextAlign.center,),
      ));
    }
    // If an image is captured/selected, show it
    if (_imageFile != null) {
      return Center(child: Image.file(File(_imageFile!.path), fit: BoxFit.contain));
    }
    // Otherwise, show the camera preview (if available)
    if (_cameraController == null || _initializeControllerFuture == null) {
      // This state might occur if permissions denied after init attempt
      return const Center(child: Text('Camera not available or permission denied.'));
    }

    // Use FutureBuilder to display loading spinner until controller is initialized
    return FutureBuilder<void>(
      future: _initializeControllerFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.done) {
          // If the Future is complete, display the preview.
          // Use AspectRatio to try and match camera aspect ratio
          return Center(
             child: AspectRatio(
               aspectRatio: _cameraController!.value.aspectRatio,
               child: CameraPreview(_cameraController!),
             ),
           );
        } else {
          // Otherwise, display a loading indicator.
          return const Center(child: CircularProgressIndicator());
        }
      },
    );
  }


  // --- Helper: Build Control Bar ---
  Widget _buildControlBar() {
     // If image is selected, show Retake/Submit buttons
    if (_imageFile != null) {
       return Row(
         mainAxisAlignment: MainAxisAlignment.spaceAround,
         children: [
           OutlinedButton.icon(
             icon: const Icon(Icons.replay),
             label: const Text("Retake/Re-select"),
             onPressed: _isProcessing ? null : _clearImage, // Disable while processing
             style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white)),
           ),
           ElevatedButton.icon(
             icon: _isProcessing
               ? Container(width: 18, height: 18, child: const CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
               : const Icon(Icons.send),
             label: Text(_isProcessing ? "Processing..." : "Use Photo"),
             onPressed: _isProcessing ? null : _submitImage,
              style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.primary, foregroundColor: Theme.of(context).colorScheme.onPrimary),
           ),
         ],
       );
     }
    // If camera is active, show Take Photo button
    else if (_cameraController != null && _cameraController!.value.isInitialized) {
       return Row(
         mainAxisAlignment: MainAxisAlignment.spaceAround,
         children: [
           // Placeholder for flash button etc. if needed
            IconButton(
             icon: const Icon(Icons.image_search, color: Colors.white, size: 30),
             tooltip: 'Pick from Gallery',
             onPressed: _pickImage,
            ),
           // --- Capture Button ---
           InkWell( // Larger tap area
              onTap: _takePicture,
              child: Container(
                 padding: const EdgeInsets.all(4.0),
                 decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2)
                 ),
                 child: const CircleAvatar(
                   radius: 30.0,
                   backgroundColor: Colors.white,
                    child: Icon(Icons.camera_alt, size: 30, color: Colors.black54),
                 ),
              )
           ),
           // Placeholder for switching camera etc.
           const SizedBox(width: 48), // Balance the row
         ],
       );
     }
    // Default case (e.g., permissions denied, no camera) - show only Gallery button
    else {
       return Row(
         mainAxisAlignment: MainAxisAlignment.center,
         children: [
           ElevatedButton.icon(
             icon: const Icon(Icons.image_search),
             label: const Text('Pick from Gallery'),
             onPressed: _pickImage,
           ),
         ],
       );
    }
  }

}