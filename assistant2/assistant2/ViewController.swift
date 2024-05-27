//
//  ViewController.swift
//  assistant2
//
//  Created by User on 24.05.2024.
//

import AVFoundation
import CoreMedia
import CoreML
import UIKit
import Vision
import VisionKit
import Speech

var mlModel = try! yolov8mCustom(configuration: .init()).model

class ViewController: UIViewController {
    @IBOutlet weak var inputTextView: UITextView!
    @IBOutlet weak var logTextView: UITextView!
    @IBOutlet weak var readTextButton: UIButton!
    @IBOutlet weak var searchItemButton: UIButton!
    @IBOutlet weak var searchTextButton: UIButton!
    @IBOutlet weak var stopButton: UIButton!
    
    @IBOutlet var videoPreview: UIView!
    @IBOutlet var View0: UIView!
    @IBOutlet var segmentedControl: UISegmentedControl!
    @IBOutlet var playButtonOutlet: UIBarButtonItem!
    @IBOutlet var pauseButtonOutlet: UIBarButtonItem!
    @IBOutlet var slider: UISlider!
    @IBOutlet var sliderConf: UISlider!
    @IBOutlet var sliderIoU: UISlider!
    @IBOutlet weak var labelName: UILabel!
    @IBOutlet weak var labelFPS: UILabel!
    @IBOutlet weak var labelZoom: UILabel!
    @IBOutlet weak var labelVersion: UILabel!
    @IBOutlet weak var labelSlider: UILabel!
    @IBOutlet weak var labelSliderConf: UILabel!
    @IBOutlet weak var labelSliderIoU: UILabel!
    @IBOutlet weak var activityIndicator: UIActivityIndicatorView!
    
    
    private var currentTask = 0 // 0 = stop, 1 = search item, 2 = read text
    
    private var searchItemTask = SearchItemTask()
    private let impactFeedbackGenerator = UIImpactFeedbackGenerator(style: .heavy)
    
    private var synthesizer = AVSpeechSynthesizer()
    private let speechRecognizer = SFSpeechRecognizer.init(locale: Locale.init(identifier: "Ru"))
    private let textRecognitionLanguages = [String("ru-RU")] //[String("en-US"), String("ru-RU")]
    
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    
    private var isSpeechRecognitionAvailable: Bool{
        let status = SFSpeechRecognizer.authorizationStatus()
        return (speechRecognizer?.isAvailable ?? false) && (status == .authorized)
    }
    
    let selection = UISelectionFeedbackGenerator()
    var detector = try! VNCoreMLModel(for: mlModel)
    var session: AVCaptureSession!
    var videoCapture: VideoCapture!
    var currentBuffer: CVPixelBuffer?
    var framesDone = 0
    var t0 = 0.0  // inference start
    var t1 = 0.0  // inference dt
    var t2 = 0.0  // inference dt smoothed
    var t3 = CACurrentMediaTime()  // FPS start
    var t4 = 0.0  // FPS dt smoothed
    // var cameraOutput: AVCapturePhotoOutput!

    // Developer mode
    let developerMode = UserDefaults.standard.bool(forKey: "developer_mode")   // developer mode selected in settings
    let save_detections = false  // write every detection to detections.txt
    let save_frames = false  // write every frame to frames.txt

    lazy var visionRequest: VNCoreMLRequest = {
        let request = VNCoreMLRequest(model: detector, completionHandler: {
            [weak self] request, error in
            self?.processObservations(for: request, error: error)
        })
        // NOTE: BoundingBoxView object scaling depends on request.imageCropAndScaleOption https://developer.apple.com/documentation/vision/vnimagecropandscaleoption
        request.imageCropAndScaleOption = .scaleFill  // .scaleFit, .scaleFill, .centerCrop
        return request
    }()

    lazy var textRecognitionRequest: VNRecognizeTextRequest = {
        let request = VNRecognizeTextRequest(completionHandler: { (request, error) in
            if let error = error {
                print("Text recognition error: \(error.localizedDescription)")
                return
            }

            guard let results = request.results as? [VNRecognizedTextObservation] else {
                print("No text recognized.")
                return
            }

            self.processRecognizedTextResults(results)
        })

        request.customWords = textRecognitionLanguages
        request.recognitionLevel = .accurate
        return request
    }()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // slider.value = 30
        // setLabels()
        setUpBoundingBoxViews()
        startVideo()
                
        do{
           try initAudio()
        }catch{
            log(text: error.localizedDescription)
        }
        
        synthesizer.delegate = self
        requestTranscribePermissions()
        showAvailableSpeechVoices()
        
        // setUpTextRecognitionRequest()
        // setModel()
    }
    
    //MARK: - actions
    
    @IBAction func searchItemButtonTap(_ sender: Any) {
        reset()
        currentTask = 1
        recognizeItemName()
    }
    
    @IBAction func readTextButtonTap(_ sender: Any) {
        reset()
        currentTask = 2
    }
    
    @IBAction func searchTextButtonTap(_ sender: Any) {
        reset()
        currentTask = 3
    }
    
    @IBAction func stopButtonTap(_ sender: Any) {
        reset()
    }
    
    //MARK: - support
    
    private func reset() {
        currentTask = 0
        stopRecording()
        synthesizer.stopSpeaking(at: .immediate) //_synthesizer.pauseSpeaking(at: .immediate)
        searchItemTask.name = ""
    }
    
    private func requestTranscribePermissions() {
        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            DispatchQueue.main.async {
                if authStatus == .authorized {
                    self?.enableStartRec(isEnabled: true)
                } else {
                    self?.enableStartRec(isEnabled: false)
                    self?.log(text: "Transcription permission was declined.")
                }
            }
        }
    }
    
    private func initAudio() throws{
        let recordingFormat = audioEngine.inputNode.outputFormat(forBus: 0)
        // The buffer size tells us how much data should the microphone record before dumping it into the recognition request.
        audioEngine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] (buffer: AVAudioPCMBuffer, when: AVAudioTime) in
            self?.recognitionRequest?.append(buffer)
        }
              
        audioEngine.prepare()
        try audioEngine.start()
    }
    
    private func processRecognizedTextResults(_ results: [VNRecognizedTextObservation]) {
        var extractedText = ""
        
        for observation in results {
            guard let topCandidate = observation.topCandidates(1).first else { continue }
            
            extractedText += topCandidate.string + "\n"
        }
        
        if !self.isSpeaking {
            DispatchQueue.main.async {
                // self.log(text: extractedText)
                self.synthesizeVoice(text: extractedText)
            }
        }
    }
    
    private func recognizeItemName() {
        // Cancel the previous recognition task.
        recognitionTask?.cancel()
        recognitionTask = nil
              
        // The AudioBuffer
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest!.shouldReportPartialResults = false
        
        // Force speech recognition to be on-device
        if #available(iOS 13, *) {
            recognitionRequest!.requiresOnDeviceRecognition = true
        }
        
        // Actually create the recognition task. We need to keep a pointer to it so we can stop it.
        
        do{
           try initAudio()
        }catch{
            log(text: error.localizedDescription)
        }
        
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest!) { [weak self] result, error in
            var isFinal = false
            
            if let result = result {
                isFinal = result.isFinal
                let recognizedText = result.bestTranscription.formattedString.lowercased()
                self?.log(text: recognizedText)
                
                if let modelClasses = self?.searchItemTask.modelClasses {
                    for (key, value) in modelClasses {
                        if recognizedText.contains(key) {
                            self?.stopRecording()
                            self?.searchItemTask.initiateSearch(name: value)
                            self?.synthesizeVoice(text: ("Ищу предмет, ..." + key))
                            
                            DispatchQueue.main.async { [unowned self] in
                                self?.inputTextView.text = value
                            }
                        }
                    }
                }
            }

            if error != nil || isFinal {
                // Stop recognizing speech if there is a problem.
                self?.stopRecording()
                if isFinal == false, let errorMessage = error?.localizedDescription{
                    self?.log(text: errorMessage)
                }
            }
            
            if isFinal == true{
                self?.log(text: NSLocalizedString("Finish voice recognition..", comment: ""))
            }
        }
        
        enableStartRec(isEnabled: false)
        log(text: NSLocalizedString("Start voice recognition..", comment: ""))
        synthesizeVoice(text: "Назовите предмет")
    }
    
    private func stopRecording() {
        
        self.recognitionRequest?.endAudio()
        self.recognitionTask?.finish()
        
        self.audioEngine.stop()
        self.audioEngine.inputNode.removeTap(onBus: 0)
        
        self.recognitionRequest = nil
        self.recognitionTask = nil
        
        enableStartRec(isEnabled: true)
    }
    
    private func enableStartRec(isEnabled: Bool){
        self.searchItemButton.isEnabled = isEnabled && isSpeechRecognitionAvailable
        self.searchItemButton.alpha = (self.searchItemButton.isEnabled == true ? 1.0 : 0.5)
    }
    
    private func showAvailableSpeechVoices(){
         log(text: NSLocalizedString("Available voices:", comment: ""))
         let speechVoices = AVSpeechSynthesisVoice.speechVoices()
         for voice in speechVoices{
            log(text: "\(voice.identifier) - \(voice.name)");
         }
     }
    
    private var isSpeaking: Bool = false
    
    private func synthesizeVoice(text: String) {
        isSpeaking = true
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.4
        let voiceIdentifier = "com.apple.ttsbundle.Milena-premium"
        utterance.voice = AVSpeechSynthesisVoice.init(identifier: voiceIdentifier)
        synthesizer.speak(utterance)
    }
    
    func log(text: String) {
        DispatchQueue.main.async { [unowned self] in
            self.logTextView.text = self.logTextView.text + text + "\n"
            self.logTextView.scrollRangeToVisible(NSMakeRange(self.logTextView.text.count - 1, 1))
        }
    }
    
    
    @IBAction func vibrate(_ sender: Any) {
        selection.selectionChanged()
    }

    @IBAction func indexChanged(_ sender: Any) {
        selection.selectionChanged()
        activityIndicator.startAnimating()

        /// Switch model
        switch segmentedControl.selectedSegmentIndex {
        case 0:
            mlModel = try! yolov8mCOCO(configuration: .init()).model
        case 1:
            mlModel = try! yolov8mCOCO(configuration: .init()).model
        case 2:
            mlModel = try! yolov8mCOCO(configuration: .init()).model
        case 3:
            mlModel = try! yolov8mCustom(configuration: .init()).model
        default:
            break
        }
        setModel()
        setUpBoundingBoxViews()
        activityIndicator.stopAnimating()
    }

    func setModel() {
        /// VNCoreMLModel
        detector = try! VNCoreMLModel(for: mlModel)
        detector.featureProvider = ThresholdProvider()

        /// VNCoreMLRequest
        let request = VNCoreMLRequest(model: detector, completionHandler: {
            [weak self] request, error in
            self?.processObservations(for: request, error: error)
        })
        request.imageCropAndScaleOption = .scaleFill  // .scaleFit, .scaleFill, .centerCrop
        visionRequest = request
        t2 = 0.0 // inference dt smoothed
        t3 = CACurrentMediaTime()  // FPS start
        t4 = 0.0  // FPS dt smoothed
    }

    /// Update thresholds from slider values
    @IBAction func sliderChanged(_ sender: Any) {
        let conf = Double(round(100 * sliderConf.value)) / 100
        let iou = Double(round(100 * sliderIoU.value)) / 100
        self.labelSliderConf.text = String(conf) + " Confidence Threshold"
        self.labelSliderIoU.text = String(iou) + " IoU Threshold"
        detector.featureProvider = ThresholdProvider(iouThreshold: iou, confidenceThreshold: conf)
    }

    let maxBoundingBoxViews = 100
    var boundingBoxViews = [BoundingBoxView]()
    var colors: [String: UIColor] = [:]

    func setUpBoundingBoxViews() {
        // Ensure all bounding box views are initialized up to the maximum allowed.
        while boundingBoxViews.count < maxBoundingBoxViews {
            boundingBoxViews.append(BoundingBoxView())
        }

        // Retrieve class labels directly from the CoreML model's class labels, if available.
        guard let classLabels = mlModel.modelDescription.classLabels as? [String] else {
            fatalError("Class labels are missing from the model description")
        }

        // Assign random colors to the classes.
        for label in classLabels {
            if colors[label] == nil {  // if key not in dict
                colors[label] = UIColor(red: CGFloat.random(in: 0...1),
                        green: CGFloat.random(in: 0...1),
                        blue: CGFloat.random(in: 0...1),
                        alpha: 0.6)
            }
        }
    }

    func startVideo() {
        videoCapture = VideoCapture()
        videoCapture.delegate = self

        videoCapture.setUp(sessionPreset: .photo) { success in
            // .hd4K3840x2160 or .photo (4032x3024)  Warning: 4k may not work on all devices i.e. 2019 iPod
            if success {
                // Add the video preview into the UI.
                if let previewLayer = self.videoCapture.previewLayer {
                    self.videoPreview.layer.addSublayer(previewLayer)
                    self.videoCapture.previewLayer?.frame = self.videoPreview.bounds  // resize preview layer
                }

                // Add the bounding box layers to the UI, on top of the video preview.
                for box in self.boundingBoxViews {
                    box.addToLayer(self.videoPreview.layer)
                }

                // Once everything is set up, we can start capturing live video.
                self.videoCapture.start()
            }
        }
    }
    
    func predict(sampleBuffer: CMSampleBuffer) {
        if currentBuffer == nil, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            currentBuffer = pixelBuffer

            /// - Tag: MappingOrientation
            // The frame is always oriented based on the camera sensor,
            // so in most cases Vision needs to rotate it for the model to work as expected.
            let imageOrientation: CGImagePropertyOrientation
            switch UIDevice.current.orientation {
            case .portrait:
                imageOrientation = .up
            case .portraitUpsideDown:
                imageOrientation = .down
            case .landscapeLeft:
                imageOrientation = .left
            case .landscapeRight:
                imageOrientation = .right
            case .unknown:
                print("The device orientation is unknown, the predictions may be affected")
                fallthrough
            default:
                imageOrientation = .up
            }

            // Invoke a VNRequestHandler with that image
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: imageOrientation, options: [:])
            if currentTask != 0 {
                t0 = CACurrentMediaTime()  // inference start
                do {
                    if currentTask == 1 {
                        try handler.perform([visionRequest])
                    }else if currentTask == 2 && !isSpeaking {
                        try handler.perform([textRecognitionRequest])
                    }
                } catch {
                    print(error)
                }
                t1 = CACurrentMediaTime() - t0  // inference dt
            }

            currentBuffer = nil
        }
    }

    func processObservations(for request: VNRequest, error: Error?) {
        DispatchQueue.main.async {
            if let results = request.results as? [VNRecognizedObjectObservation] {
                self.show(predictions: results)
                
                if self.currentTask == 1 {
                    self.searchItemTask.updateConditions(recognizedObjects: results)
                    if !self.isSpeaking {
                        self.synthesizeVoice(text: self.searchItemTask.textToSpeak)
                    }
                    self.impactFeedbackGenerator.impactOccurred(intensity: CGFloat(self.searchItemTask.feedBackIntensity))
                }
                
            } else {
                self.show(predictions: [])
            }

            // Measure FPS
            if self.t1 < 10.0 {  // valid dt
                self.t2 = self.t1 * 0.05 + self.t2 * 0.95  // smoothed inference time
            }
            self.t4 = (CACurrentMediaTime() - self.t3) * 0.05 + self.t4 * 0.95  // smoothed delivered FPS
            self.labelFPS.text = String(format: "FPS: %.1f", 1 / self.t4, self.t2 * 1000)  // t2 seconds to ms
            self.t3 = CACurrentMediaTime()
        }
    }

    // Return RAM usage (GB)
    func memoryUsage() -> Double {
        var taskInfo = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &taskInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if kerr == KERN_SUCCESS {
            return Double(taskInfo.resident_size) / 1E9   // Bytes to GB
        } else {
            return 0
        }
    }

    func show(predictions: [VNRecognizedObjectObservation]) {
        let width = videoPreview.bounds.width  // 375 pix
        let height = videoPreview.bounds.height  // 812 pix
        // var str = ""

        // ratio = videoPreview AR divided by sessionPreset AR
        var ratio: CGFloat = 1.0
        if videoCapture.captureSession.sessionPreset == .photo {
            ratio = (height / width) / (4.0 / 3.0)  // .photo
        } else {
            ratio = (height / width) / (16.0 / 9.0)  // .hd4K3840x2160, .hd1920x1080, .hd1280x720 etc.
        }

//        self.labelSlider.text = String(predictions.count) + " items (max " + String(Int(slider.value)) + ")"
        for i in 0..<boundingBoxViews.count {
            if i < predictions.count && i < Int(30) {
                let prediction = predictions[i]

                var rect = prediction.boundingBox  // normalized xywh, origin lower left
                switch UIDevice.current.orientation {
                case .portraitUpsideDown:
                    rect = CGRect(x: 1.0 - rect.origin.x - rect.width,
                            y: 1.0 - rect.origin.y - rect.height,
                            width: rect.width,
                            height: rect.height)
                case .landscapeLeft:
                    rect = CGRect(x: rect.origin.y,
                            y: 1.0 - rect.origin.x - rect.width,
                            width: rect.height,
                            height: rect.width)
                case .landscapeRight:
                    rect = CGRect(x: 1.0 - rect.origin.y - rect.height,
                            y: rect.origin.x,
                            width: rect.height,
                            height: rect.width)
                case .unknown:
                    print("The device orientation is unknown, the predictions may be affected")
                    fallthrough
                default: break
                }

                if ratio >= 1 { // iPhone ratio = 1.218
                    let offset = (1 - ratio) * (0.5 - rect.minX)
                    let transform = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: offset, y: -1)
                    rect = rect.applying(transform)
                    rect.size.width *= ratio
                } else { // iPad ratio = 0.75
                    let offset = (ratio - 1) * (0.5 - rect.maxY)
                    let transform = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: offset - 1)
                    rect = rect.applying(transform)
                    rect.size.height /= ratio
                }

                // Scale normalized to pixels [375, 812] [width, height]
                rect = VNImageRectForNormalizedRect(rect, Int(width), Int(height))

                // The labels array is a list of VNClassificationObservation objects,
                // with the highest scoring class first in the list.
                let bestClass = prediction.labels[0].identifier
                let confidence = prediction.labels[0].confidence
                // print(confidence, rect)  // debug (confidence, xywh) with xywh origin top left (pixels)

                // Show the bounding box.
                boundingBoxViews[i].show(frame: rect,
                        label: String(format: "%@ %.1f", bestClass, confidence * 100),
                        color: colors[bestClass] ?? UIColor.white,
                        alpha: CGFloat((confidence - 0.2) / (1.0 - 0.2) * 0.9))  // alpha 0 (transparent) to 1 (opaque) for conf threshold 0.2 to 1.0)
            } else {
                boundingBoxViews[i].hide()
            }
        }
    }

    // Pinch to Zoom Start ---------------------------------------------------------------------------------------------
    let minimumZoom: CGFloat = 1.0
    let maximumZoom: CGFloat = 10.0
    var lastZoomFactor: CGFloat = 1.0

    @IBAction func pinch(_ pinch: UIPinchGestureRecognizer) {
        let device = videoCapture.captureDevice

        // Return zoom value between the minimum and maximum zoom values
        func minMaxZoom(_ factor: CGFloat) -> CGFloat {
            return min(min(max(factor, minimumZoom), maximumZoom), device.activeFormat.videoMaxZoomFactor)
        }

        func update(scale factor: CGFloat) {
            do {
                try device.lockForConfiguration()
                defer {
                    device.unlockForConfiguration()
                }
                device.videoZoomFactor = factor
            } catch {
                print("\(error.localizedDescription)")
            }
        }

        let newScaleFactor = minMaxZoom(pinch.scale * lastZoomFactor)
        switch pinch.state {
            case .began: fallthrough
            case .changed:
                update(scale: newScaleFactor)
                // self.labelZoom.text = String(format: "%.2fx", newScaleFactor)
                // self.labelZoom.font = UIFont.preferredFont(forTextStyle: .title2)
            case .ended:
                lastZoomFactor = minMaxZoom(newScaleFactor)
                update(scale: lastZoomFactor)
                // self.labelZoom.font = UIFont.preferredFont(forTextStyle: .body)
            default: break
        }
    }
    
}  // ViewController class End

extension ViewController: VideoCaptureDelegate {
    func videoCapture(_ capture: VideoCapture, didCaptureVideoFrame sampleBuffer: CMSampleBuffer) {
        predict(sampleBuffer: sampleBuffer)
    }
}

extension ViewController: AVSpeechSynthesizerDelegate { func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    isSpeaking = false
    if currentTask == 2 { // for semi-auto text recognize mode
        currentTask = 0
    }
}}



