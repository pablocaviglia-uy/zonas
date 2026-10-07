import AVFoundation
import Vision
import ImageIO

/// Opt-in, local inference. The capture delegate owns no images after a frame.
final class GazeCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onState: ((Bool, String) -> Void)?
    var onSample: ((Gaze.Features?, String, Double) -> Void)?
    private let queue = DispatchQueue(label: "uy.com.fcstudio.zonas.gaze-camera", qos: .userInitiated)
    private var session: AVCaptureSession? // accessed only on queue
    private var workerGeneration = 0
    private var lastFrame = 0.0
    private var generation = 0
    private let generationLock = NSLock()
    private var currentGeneration: Int {
        generationLock.lock(); defer { generationLock.unlock() }; return generation
    }
    private var notifications: [NSObjectProtocol] = []

    static var devices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                        mediaType: .video, position: .unspecified).devices
    }

    func start(deviceID: String) {
        stop()
        let token = currentGeneration
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure(deviceID: deviceID, token: token)
        case .notDetermined:
            onState?(false, "Waiting for camera permission…")
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                DispatchQueue.main.async {
                    guard let self, self.currentGeneration == token else { return }
                    if allowed { self.configure(deviceID: deviceID, token: token) }
                    else { self.onState?(false, "Camera access was declined. Enable it in System Settings → Privacy & Security → Camera.") }
                }
            }
        default: onState?(false, "Camera access is unavailable. Check System Settings → Privacy & Security → Camera.")
        }
    }

    func stop() {
        generationLock.lock(); generation += 1; generationLock.unlock()
        notifications.forEach(NotificationCenter.default.removeObserver)
        notifications = []
        queue.async { [weak self] in
            self?.session?.stopRunning()
            self?.session = nil
        }
    }

    private func configure(deviceID: String, token: Int) {
        onState?(false, "Starting camera…")
        queue.async { [weak self] in
            guard let self else { return }
            guard self.currentGeneration == token else { return }
            do {
                guard let device = Self.devices.first(where: { $0.uniqueID == deviceID }) else {
                    throw CameraError.message("The selected camera is no longer connected.")
                }
                let session = AVCaptureSession()
                session.beginConfiguration()
                if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else { throw CameraError.message("Cannot open this camera.") }
                session.addInput(input)
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                guard session.canAddOutput(output) else { throw CameraError.message("Camera output is unavailable.") }
                session.addOutput(output)
                // Unmirrored camera pixels. Calibration learns their relation
                // to a display, so no camera-to-screen sign is guessed here.
                if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = false
                }
                output.setSampleBufferDelegate(self, queue: self.queue)
                session.commitConfiguration()
                guard self.currentGeneration == token else { return }
                self.workerGeneration = token
                self.lastFrame = 0
                self.session = session
                session.startRunning()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.currentGeneration == token else { return }
                    for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
                        self.notifications.append(NotificationCenter.default.addObserver(forName: name, object: session,
                                                                                         queue: .main) { [weak self] _ in
                            guard let self, self.currentGeneration == token else { return }
                            self.stop()
                            self.onState?(false, "Camera interrupted. Start again and recalibrate.")
                        })
                    }
                    self.onState?(session.isRunning, session.isRunning ? "Camera on · looking for both pupils" : "The camera did not start.")
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.currentGeneration == token else { return }
                    self.onState?(false, error.localizedDescription)
                }
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFrame >= 1.0 / 15, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrame = now
        let token = workerGeneration
        var features: Gaze.Features?
        var message = "No face detected"
        do {
            let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up)
            // The landmarks request's implicit detector left pitch nil on the
            // real webcam trial, rejecting every sample. Rectangle revision 3
            // computes all three angles; pass that same frame's observation
            // into landmarks rather than inventing an angle or mixing frames.
            let rectangles = VNDetectFaceRectanglesRequest()
            rectangles.revision = VNDetectFaceRectanglesRequestRevision3
            try handler.perform([rectangles])
            let detected = rectangles.results ?? []
            let faces = detected.filter { $0.confidence >= 0.65 }
            if !detected.isEmpty && faces.isEmpty { message = "Face detection confidence too low · no estimate" }
            else if faces.count > 1 { message = "More than one face · no estimate" }
            else if let face = faces.first {
                let width = Double(CVPixelBufferGetWidth(buffer)), height = Double(CVPixelBufferGetHeight(buffer))
                if face.boundingBox.width * width < 160 { message = "Face too small · move closer or choose another camera" }
                else {
                    let landmarks = VNDetectFaceLandmarksRequest()
                    landmarks.revision = VNDetectFaceLandmarksRequestRevision3
                    landmarks.inputFaceObservations = [face]
                    try handler.perform([landmarks])
                    if let observation = landmarks.results?.first {
                        let inspection = Self.features(observation, imageAspect: height / width)
                        features = inspection.features
                        message = inspection.message
                    } else {
                        message = "Face found · eye landmarks unavailable"
                    }
                }
            }
        } catch { message = "Vision could not process this frame" }
        let latency = ProcessInfo.processInfo.systemUptime - now
        if latency > 0.20 {
            features = nil
            message = "Inference too slow (\(Int(latency * 1000)) ms) · no estimate"
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentGeneration == token else { return }
            self.onSample?(features, message, now)
        }
    }

    private enum Eye: String { case left = "Left", right = "Right" }
    private enum Pose: String { case yaw, pitch, roll }

    /// Missing pose, an unusable outline and a missing pupil used to look like
    /// the same blink. Report the failed check without guessing its cause or
    /// substituting data that would bypass the calibration's quality gates.
    private enum FeatureRejection {
        case missingLandmarks, lowLandmarkConfidence
        case missingOutline(Eye), missingPupil(Eye), missingPupilPoint(Eye)
        case missingPose(Pose), invalidPose, headYaw, headPitch
        case eyeGeometry(Eye), invalidFeatures

        var message: String {
            switch self {
            case .missingLandmarks: return "Face found · eye landmarks unavailable"
            case .lowLandmarkConfidence: return "Face found · eye landmark confidence too low"
            case .missingOutline(let eye): return "\(eye.rawValue) eye outline unavailable · no estimate"
            case .missingPupil(let eye): return "\(eye.rawValue) pupil unavailable · no estimate"
            case .missingPupilPoint(let eye): return "\(eye.rawValue) pupil has no usable point · no estimate"
            case .missingPose(let pose): return "Face found · head angle unavailable (\(pose.rawValue))"
            case .invalidPose: return "Face found · head angles are invalid"
            case .headYaw: return "Head turned too far from the camera · no estimate"
            case .headPitch: return "Head tilted too far up or down · no estimate"
            case .eyeGeometry(let eye): return "\(eye.rawValue) eye outline/pupil geometry rejected · no estimate"
            case .invalidFeatures: return "Face measurements are invalid · no estimate"
            }
        }
    }

    private enum FeatureInspection {
        case usable(Gaze.Features)
        case rejected(FeatureRejection)

        var features: Gaze.Features? {
            if case .usable(let features) = self { return features }
            return nil
        }
        var message: String {
            switch self {
            case .usable: return "Both pupils detected"
            case .rejected(let reason): return reason.message
            }
        }
    }

    private static func features(_ face: VNFaceObservation, imageAspect: Double) -> FeatureInspection {
        guard let landmarks = face.landmarks else { return .rejected(.missingLandmarks) }
        guard landmarks.confidence >= 0.5 else { return .rejected(.lowLandmarkConfidence) }
        guard let left = landmarks.leftEye else { return .rejected(.missingOutline(.left)) }
        guard let right = landmarks.rightEye else { return .rejected(.missingOutline(.right)) }
        guard let lp = landmarks.leftPupil else { return .rejected(.missingPupil(.left)) }
        guard let rp = landmarks.rightPupil else { return .rejected(.missingPupil(.right)) }
        guard let yaw = face.yaw?.doubleValue else { return .rejected(.missingPose(.yaw)) }
        guard let pitch = face.pitch?.doubleValue else { return .rejected(.missingPose(.pitch)) }
        guard let roll = face.roll?.doubleValue else { return .rejected(.missingPose(.roll)) }
        guard yaw.isFinite, pitch.isFinite, roll.isFinite else { return .rejected(.invalidPose) }
        guard abs(yaw) < 0.85 else { return .rejected(.headYaw) }
        guard abs(pitch) < 0.65 else { return .rejected(.headPitch) }
        func points(_ region: VNFaceLandmarkRegion2D) -> [CGPoint] {
            region.normalizedPoints.map {
                CGPoint(x: $0.x * face.boundingBox.width, y: $0.y * face.boundingBox.height * imageAspect)
            }
        }
        guard let leftPupil = points(lp).first else { return .rejected(.missingPupilPoint(.left)) }
        guard let rightPupil = points(rp).first else { return .rejected(.missingPupilPoint(.right)) }
        guard let l = Gaze.eye(contour: points(left), pupil: leftPupil) else { return .rejected(.eyeGeometry(.left)) }
        guard let r = Gaze.eye(contour: points(right), pupil: rightPupil) else { return .rejected(.eyeGeometry(.right)) }
        let result = Gaze.Features(values: [l.x, l.y, r.x, r.y, yaw, pitch, roll,
                                           face.boundingBox.midX, face.boundingBox.midY, face.boundingBox.width])
        return result.isValid ? .usable(result) : .rejected(.invalidFeatures)
    }

    private enum CameraError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }
}
