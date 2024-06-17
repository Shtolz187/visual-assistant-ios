//  ViewController.swift
//

import AVFoundation
import CoreMedia
import CoreML
import UIKit
import Vision
import VisionKit
import Speech

var mlModel = try! yolov8mCOCO(configuration: .init()).model


class ViewController: UIViewController {
    @IBOutlet weak var inputTextView: UITextView!
    @IBOutlet weak var logTextView: UITextView!
    @IBOutlet weak var readTextButton: UIButton!
    @IBOutlet weak var searchItemButton: UIButton!
    @IBOutlet weak var searchTextButton: UIButton!
    @IBOutlet weak var stopButton: UIButton!
    @IBOutlet weak var backButton: UIButton!
    @IBOutlet weak var nextButton: UIButton!
    
    @IBOutlet var videoPreview: UIView!
    @IBOutlet var View0: UIView!
    @IBOutlet var segmentedControl: UISegmentedControl!
    @IBOutlet weak var labelFPS: UILabel!
    @IBOutlet weak var activityIndicator: UIActivityIndicatorView!
    
    private var currentTask = 0 // 0 = stop, 1 = search item, 2 = read text, 3 = search text
    
    private var searchProvider = SearchProvider()
    private var textDetection = TextDetection()
    private let impactFeedbackGenerator = UIImpactFeedbackGenerator(style: .heavy)
    private var timer: Timer?
    
    private let queue = DispatchQueue(label: "com.synthesiser.queue", attributes: .concurrent)
    private var speechSynthesizer = AVSpeechSynthesizer()
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
    var fpsStart = CACurrentMediaTime()
    var fpsSmooth = 0.0

    lazy var visionRequest: VNCoreMLRequest = {
        let request = VNCoreMLRequest(model: detector, completionHandler: {
            [weak self] request, error in
            self?.visionObservations(for: request, error: error)
        })
        
        request.imageCropAndScaleOption = .scaleFill  // .scaleFit, .scaleFill, .centerCrop
        return request
    }()
    
    lazy var textSearchRequest: VNRecognizeTextRequest = {
        let request = VNRecognizeTextRequest(completionHandler: {
            [weak self] request, error in
            self?.textSearchObservations(for: request, error: error)
        })
        
        request.customWords = textRecognitionLanguages
        request.recognitionLevel = .accurate
        return request
    }()
    
    lazy var textRecognitionRequest: VNRecognizeTextRequest = {
        let request = VNRecognizeTextRequest(completionHandler: {
            [weak self] request, error in
            self?.textRecognizeObservations(for: request, error: error)
        })
        
        request.customWords = textRecognitionLanguages
        request.recognitionLevel = .accurate
        return request
    }()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setUpBoundingBoxViews()
        startVideo()
        
        do {
           try initAudio()
        } catch {
            log(text: error.localizedDescription)
        }
        
        speechSynthesizer.delegate = self
        self.synthesizeVoice(text: " ")
        // self.synthesizeVoice(text: "Готово к работе")
        requestTranscribePermissions()
        mlModel = try! yolov8m(configuration: .init()).model
        setModel()
        setUpBoundingBoxViews()
        impactFeedbackGenerator.prepare()
        // showAvailableSpeechVoices()
    }
    
    //MARK: - actions
    
    @IBAction func searchItemButtonTap(_ sender: Any) {
        reset()
        currentTask = 1
        recognizeSpeech()
    }
    
    @IBAction func readTextButtonTap(_ sender: Any) {
        reset()
        currentTask = 2
    }
    
    @IBAction func searchTextButtonTap(_ sender: Any) {
        reset()
        currentTask = 3
        recognizeSpeech()
    }
    
    @IBAction func stopButtonTap(_ sender: Any) {
        reset()
    }
    
    @IBAction func backButtonTap(_ sender: Any) {
        self.textDetection.prevBlock()
        if speechSynthesizer.isSpeaking{
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
    }
    
    @IBAction func nextButtonTap(_ sender: Any) {
        if speechSynthesizer.isSpeaking{
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
    }
        
    @IBAction func vibrate(_ sender: Any) {
        selection.selectionChanged()
    }

    @IBAction func indexChanged(_ sender: Any) {
        selection.selectionChanged()
        activityIndicator.startAnimating()

        switch segmentedControl.selectedSegmentIndex {
        case 0:
            mlModel = try! yolov8mOIv7(configuration: .init()).model
        case 1:
            mlModel = try! yolov8mCOCO(configuration: .init()).model
        case 2:
            mlModel = try! yolov8m(configuration: .init()).model
        case 3:
            mlModel = try! yolov8m1696(configuration: .init()).model
        default:
            break
        }
        setModel()
        setUpBoundingBoxViews()
        activityIndicator.stopAnimating()
    }
    
    //MARK: - support
    
    private func reset() {
        currentTask = 0
        stopRecording()
        
        speechSynthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        speechSynthesizer = AVSpeechSynthesizer()
        speechSynthesizer.delegate = self
        
        searchProvider.reset()
        textDetection.results = []
        textDetection.textToSpeak = ""
        
        for boxView in self.boundingBoxViews {
            boxView.hide()
        }
    }
   
    private func requestTranscribePermissions() {
        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            DispatchQueue.main.async {
                if authStatus == .authorized {
                    self?.enableSearchItemButton(isEnabled: true)
                } else {
                    self?.enableSearchItemButton(isEnabled: false)
                    self?.log(text: "Transcription permission was declined.")
                }
            }
        }
    }
    
    private func initAudio() throws{
        let recordingFormat = audioEngine.inputNode.outputFormat(forBus: 0)
        
        audioEngine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] (buffer: AVAudioPCMBuffer, when: AVAudioTime) in
            self?.recognitionRequest?.append(buffer)
        }
              
        audioEngine.prepare()
        try audioEngine.start()
    }
    
    private func recognizeSpeech() {
        recognitionTask?.cancel()
        recognitionTask = nil
     
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest!.shouldReportPartialResults = false // { return type == .itemName ? true : false }()

        if #available(iOS 13, *) {
            recognitionRequest!.requiresOnDeviceRecognition = true
        }

        do{
           try initAudio()
        }catch{
            log(text: error.localizedDescription)
        }

        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest!) {
            [weak self] result, error in
            self?.speechRecognizeObservations(result: result!, error: error)
        }
        
        enableSearchItemButton(isEnabled: false)
        log(text: NSLocalizedString("Start voice recognition..", comment: ""))

        if self.currentTask == 1 {
            synthesizeVoice(text: "Назовите предмет")
        }
    }
    
    func speechRecognizeObservations(result: SFSpeechRecognitionResult?, error: Error?) {
        DispatchQueue.main.async {
            var isFinal = false
            
            if let result = result {
                isFinal = result.isFinal
                
                let recognizedText = result.bestTranscription.formattedString.lowercased()
                self.log(text: recognizedText)
                
                if self.currentTask == 1 && recognizedText != "" {
                    var keyFound = ""
                    var valueFound = ""
                    
                    for (key, value) in self.searchProvider.modelClassesCOCO {
                        if recognizedText.contains(key) {
                            keyFound = key
                            valueFound = value
                            mlModel = try! yolov8mCOCO(configuration: .init()).model
                            break
                        }
                    }

                    for (key, value) in self.searchProvider.modelClassesCustom {
                        if recognizedText.contains(key) && keyFound == "" {
                            keyFound = key
                            valueFound = value
                            mlModel = try! yolov8m(configuration: .init()).model
                            break
                        }
                    }
                    
                    if keyFound != "" {
                        self.stopRecording()
                        self.setModel()
                        self.setUpBoundingBoxViews()
                        self.searchProvider.initiateSearch(mode: 0, searchValue: valueFound)
                        self.synthesizeVoice(text: ("Ищу предмет, ..." + keyFound))
                        self.inputTextView.text = valueFound
                    }
                }
                
                if self.currentTask == 3 && recognizedText != "" {
                    self.stopRecording()
                    self.searchProvider.initiateSearch(mode: 1, searchValue: recognizedText)
                    self.synthesizeVoice(text: ("Ищу текст, ..." + recognizedText))
                }
            }
            
            if error != nil || isFinal {
                // Stop recognizing if there is a problem.
                self.stopRecording()
                if isFinal == false, let errorMessage = error?.localizedDescription{
                    self.log(text: errorMessage)
                }
            }
            
            if isFinal {
                self.log(text: NSLocalizedString("Finish voice recognition..", comment: ""))
            }
        }
    }
    
    private func stopRecording() {        
        self.recognitionRequest?.endAudio()
        self.recognitionTask?.finish()
        
        self.audioEngine.stop()
        self.audioEngine.inputNode.removeTap(onBus: 0)
        
        self.recognitionRequest = nil
        self.recognitionTask = nil
        
        enableSearchItemButton(isEnabled: true)
    }
    
    private func enableSearchItemButton(isEnabled: Bool){
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
        
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try! audioSession.setCategory(AVAudioSession.Category.playAndRecord)
            try audioSession.setMode(AVAudioSession.Mode.spokenAudio)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            try audioSession.overrideOutputAudioPort(AVAudioSession.PortOverride.speaker)
        } catch {
            log(text: "audioSession set properties error")
        }
        
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.4
        // utterance.postUtteranceDelay = 0.1
        let voiceIdentifier = "com.apple.ttsbundle.Milena-premium"
        utterance.voice = AVSpeechSynthesisVoice.init(identifier: voiceIdentifier)
        
        speechSynthesizer.speak(utterance)
    }
    
    
    func visionObservations(for request: VNRequest, error: Error?) {
        DispatchQueue.main.async {
            if let results = request.results as? [VNRecognizedObjectObservation] {
                if self.currentTask == 1 {
                    self.showBoundingBoxes(predictions: results)
                    
                    self.searchProvider.processDetectionResults(recognizedObjects: results)
                    
                    self.provideNotifications(text: self.searchProvider.textToSpeak, feedBackIntensity: self.searchProvider.feedBackIntensity)
                }
                
            } else {
                self.showBoundingBoxes(predictions: [])
            }

            self.fpsSmooth = (CACurrentMediaTime() - self.fpsStart) * 0.2 + self.fpsSmooth * 0.8
            self.labelFPS.text = String(format: "FPS: %.1f", 1 / self.fpsSmooth)
            self.fpsStart = CACurrentMediaTime()
        }
    }
    
    func textSearchObservations(for request: VNRequest, error: Error?) {
        DispatchQueue.main.async {
            if let results = request.results as? [VNRecognizedTextObservation] {
                if self.currentTask == 3 {
                    self.searchProvider.processDetectionResults(recognizedObjects: results)
                    
                    self.provideNotifications(text: self.searchProvider.textToSpeak, feedBackIntensity: self.searchProvider.feedBackIntensity)
                }
                
            } else {
                print("No text recognized.")
            }

            self.fpsSmooth = (CACurrentMediaTime() - self.fpsStart) * 0.2 + self.fpsSmooth * 0.8
            self.labelFPS.text = String(format: "FPS: %.1f", 1 / self.fpsSmooth)
            self.fpsStart = CACurrentMediaTime()
        }
    }
    
    func textRecognizeObservations(for request: VNRequest, error: Error?) {
        DispatchQueue.main.async {
            if let results = request.results as? [VNRecognizedTextObservation] {
                if self.currentTask == 2 {
                    self.textDetection.processDetectionResults(results: results)
                    
                    if !self.speechSynthesizer.isSpeaking {
                        self.synthesizeVoice(text: " ")
                    } else {
                        self.speechSynthesizer.stopSpeaking(at: .immediate)
                    }
                }
            } else {
                print("No text recognized.")
            }
        }
    }
    
    func provideNotifications(text: String, feedBackIntensity: Double) {
        if !self.isSpeaking {
            self.synthesizeVoice(text: text)
        }
        
        if feedBackIntensity > 0.9 {
            // Continuous haptic feedback
            if self.timer == nil {
                self.timer = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true, block: { _ in
                    self.impactFeedbackGenerator.impactOccurred(intensity: 0.99)
                })
            }
        } else {
            // Single haptic feedback
            self.timer?.invalidate() // Stop any previous timer
            self.timer = nil
            self.impactFeedbackGenerator.impactOccurred(intensity: CGFloat(feedBackIntensity))
        }
    }
    
    func log(text: String) {
        DispatchQueue.main.async { [unowned self] in
            self.logTextView.text = self.logTextView.text + text + "\n"
            self.logTextView.scrollRangeToVisible(NSMakeRange(self.logTextView.text.count - 1, 1))
        }
    }
    
    func setModel() {
        detector = try! VNCoreMLModel(for: mlModel)
        detector.featureProvider = ThresholdProvider()

        let request = VNCoreMLRequest(model: detector, completionHandler: {
            [weak self] request, error in
            self?.visionObservations(for: request, error: error)
        })
        request.imageCropAndScaleOption = .scaleFill  // .scaleFit, .scaleFill, .centerCrop
        visionRequest = request
        fpsStart = CACurrentMediaTime()  // FPS
        fpsSmooth = 0.0
    }


    let maxBoundingBoxViews = 100
    var boundingBoxViews = [BoundingBoxView]()
    var colors: [String: UIColor] = [:]

    func setUpBoundingBoxViews() {
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

        videoCapture.setUp(sessionPreset: .photo) { success in // .photo 4032x3024
            if success {
                if let previewLayer = self.videoCapture.previewLayer {
                    self.videoPreview.layer.addSublayer(previewLayer)
                    self.videoCapture.previewLayer?.frame = self.videoPreview.bounds  // resize preview layer
                }
                
                for box in self.boundingBoxViews {
                    box.addToLayer(self.videoPreview.layer)
                }
                
                self.videoCapture.start()
            }
        }
    }
    
    func predict(sampleBuffer: CMSampleBuffer) {
        if currentBuffer == nil, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            currentBuffer = pixelBuffer

            // rotate frame for the model to work as expected
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

            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: imageOrientation, options: [:])
            if currentTask != 0 {
                do {
                    if currentTask == 1 {
                        try handler.perform([visionRequest])
                    } else if currentTask == 2 && textDetection.results == [] {
                        try handler.perform([textRecognitionRequest])
                    } else if currentTask == 3 {
                        try handler.perform([textSearchRequest])
                    }
                } catch {
                    print(error)
                }
            }

            currentBuffer = nil
        }
    }
    
    func showBoundingBoxes(predictions: [VNRecognizedObjectObservation]) {
        let width = videoPreview.bounds.width  // 375 pix
        let height = videoPreview.bounds.height  // 812 pix

        // ratio = videoPreview AR divided by sessionPreset AR
        var ratio: CGFloat = 1.0
        if videoCapture.captureSession.sessionPreset == .photo {
            ratio = (height / width) / (4.0 / 3.0)  // .photo
        } else {
            ratio = (height / width) / (16.0 / 9.0)  // .hd4K3840x2160, .hd1920x1080, .hd1280x720 etc.
        }
        
        
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

                boundingBoxViews[i].show(frame: rect,
                        label: String(format: "%@ %.1f", bestClass, confidence * 100),
                        color: colors[bestClass] ?? UIColor.white,
                        alpha: CGFloat((confidence - 0.2) / (1.0 - 0.2) * 0.9))  // alpha 0 (transparent) to 1 (opaque) for conf threshold 0.2 to 1.0)
            } else {
                boundingBoxViews[i].hide()
            }
        }
    }

    // Pinch to Zoom Start ------------------------------------------------------------------
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
            case .ended:
                lastZoomFactor = minMaxZoom(newScaleFactor)
                update(scale: lastZoomFactor)
            default: break
        }
    }
    
}

extension ViewController: VideoCaptureDelegate {
    func videoCapture(_ capture: VideoCapture, didCaptureVideoFrame sampleBuffer: CMSampleBuffer) {
        predict(sampleBuffer: sampleBuffer)
    }
}

extension ViewController: AVSpeechSynthesizerDelegate { func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    // log(text: "AVSpeechSynthesizerDelegate")
    isSpeaking = false
    if currentTask == 2 {
        if self.textDetection.autoplay {
            self.textDetection.nextBlock()
            if textDetection.textToSpeak != "END_OF_TEXT" {
                // log(text: textDetection.textToSpeak)
                self.synthesizeVoice(text: textDetection.textToSpeak)
            } else {
                currentTask = 0
            }
        }
    }
}}
