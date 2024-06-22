//
//  TextDetection.swift
//  assistant1
//
//  Created by User on 10.06.2024.
//

import Foundation
import Vision


class TextDetection {
    var results: [VNRecognizedTextObservation] = []
    var pointer: Int = -1
    var autoplay: Bool = true
    var textToSpeak: String = ""
    
    func processDetectionResults (results: [VNRecognizedTextObservation]) -> () {
        pointer = -1
        textToSpeak = ""
        self.results = results
    }
    
    func nextBlock() {
        pointer += 1
        if pointer < 0 {
            pointer = 0
        }
        if results.count > pointer {
            textToSpeak = extractText(results[pointer])
        }else{
            textToSpeak = "END_OF_TEXT"
        }
    }
    
    func prevBlock() {
        pointer -= 2
        if pointer < -1 {
            pointer = -1
        }
    }
    
    //TODO implement filtering partial results along the edges to focus-on-one-page read mode
    private func extractText(_ observation: VNRecognizedTextObservation) -> String {
        guard let topCandidate = observation.topCandidates(1).first else { return "" }
        var extractedText = topCandidate.string
        extractedText = extractedText.replacingOccurrences(of: "«", with: " ")
        extractedText = extractedText.replacingOccurrences(of: "»", with: " ")
        extractedText = extractedText.replacingOccurrences(of: ".", with: " ... ")
        return extractedText
    }
}
