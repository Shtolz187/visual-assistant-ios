import AVFoundation
import Speech

protocol SpeechRecognitionDelegate {
    func didRecognizeSpeech(recognizedText: String)
}

class SpeechProvider: NSObject {
    private var speechSynthesizer = AVSpeechSynthesizer()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    
    let textRecognitionLanguages = [String("ru-RU")]
    
    var delegate: SpeechRecognitionDelegate?
    
    var isSpeaking: Bool { return speechSynthesizer.isSpeaking }
    
    var isSpeechRecognitionAvailable: Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        return speechRecognizer?.isAvailable ?? false && status == .authorized
    }
    
    override init() {
        super.init()
        do {
            try initAudio()
        } catch {
            print("audioSession set properties error")
        }
    }
    
    func synthesizeVoice(text: String) {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try! audioSession.setCategory(AVAudioSession.Category.playAndRecord)
            try audioSession.setMode(AVAudioSession.Mode.spokenAudio)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            try audioSession.overrideOutputAudioPort(AVAudioSession.PortOverride.speaker)
        } catch {
            print("audioSession set properties error")
        }
        
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.4
        // utterance.postUtteranceDelay = 0.1
        let voiceIdentifier = "com.apple.ttsbundle.Milena-premium"
        utterance.voice = AVSpeechSynthesisVoice.init(identifier: voiceIdentifier)
        
        speechSynthesizer.speak(utterance)
    }
    
    func stopSpeaking() {
        speechSynthesizer.stopSpeaking(at: .immediate)
    }
    
    func startRecording() -> () {
        recognitionTask?.cancel()
        recognitionTask = nil
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest!.shouldReportPartialResults = false // type == .itemName

        if #available(iOS 13, *) {
            recognitionRequest!.requiresOnDeviceRecognition = true
        }

        do {
            try initAudio()
        } catch {
            print(error.localizedDescription)
        }

        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest!) { result, error in
            var isFinal = false
            
            if let result = result {
                isFinal = result.isFinal
                let recognizedText = result.bestTranscription.formattedString.lowercased()
                self.delegate?.didRecognizeSpeech(recognizedText: recognizedText)
            }
            
            if error != nil || isFinal {
                self.stopRecording()
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
    
    func stopRecording() {
        self.recognitionRequest?.endAudio()
        self.recognitionTask?.finish()
        
        self.audioEngine.stop()
        self.audioEngine.inputNode.removeTap(onBus: 0)
        
        self.recognitionRequest = nil
        self.recognitionTask = nil
    }
}
