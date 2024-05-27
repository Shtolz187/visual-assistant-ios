//
//  SearchItemTask.swift
//  assistant2
//
//  Created by User on 26.05.2024.
//

import Foundation
import Vision

struct Point {
    var x = 0.0, y = 0.0
}

extension Point {
    static func + (left: Point, right: Point) -> Point {
        return Point(x: left.x + right.x, y: left.y + right.y)
    }
    static func - (left: Point, right: Point) -> Point {
        return Point(x: left.x - right.x, y: left.y - right.y)
    }
    static func * (left: Point, right: Double) -> Point {
        return Point(x: left.x * right, y: left.y * right)
    }
    static func < (left: Point, right: Point) -> Point {
        return Point(x: left.x - right.x, y: left.y - right.y)
    }
}

class SearchItemTask {
    let modelClasses = [
        "ключи": "Keys",
        "ключ": "Keys",
        "включи": "Keys",
        "очки": "Glasses",
        "шапка": "Knitted hat",
        "шляпа": "Hat",
        "белая трость": "White cane",
        "кепка": "Cap",
        "дверная ручка": "Door handle",
        "верная ручка": "Door handle",
        "перчатка": "Glove",
        "перчатки": "Glove",
        "сушилка для рук": "Hand dryer",
        "выключатель": "Light switch",
        "розетка": "Power plugs and sockets",
        "отвёртка": "Screwdriver",
        "кран": "Tap",
        "кошелек": "Wallet",
        "бумажник": "Wallet",
        "туалетная бумага": "Toilet paper"
    ]
    
    var name: String
    var textToSpeak: String
    var feedBackIntensity: Double
    
    private var health: Int
    private var smoothPosition: Point
    
    private let SCREEN_CENTER = Point(x: 0.5, y: 0.5)
    
    init() {
        name = ""
        health = 0
        smoothPosition = Point(x: -1.0, y: -1.0)
        textToSpeak = ""
        feedBackIntensity = 0.0
    }
    
    func initiateSearch(name: String) -> () {
        self.name = name
        health = 0
        smoothPosition = Point(x: -1.0, y: -1.0)
        textToSpeak = ""
        feedBackIntensity = 0.0
    }
    
    func updateConditions(recognizedObjects: [VNRecognizedObjectObservation]) -> () {
        var desiredItems = [VNRecognizedObjectObservation]()
        for i in 0..<recognizedObjects.count {
            let prediction = recognizedObjects[i]
            if self.name.lowercased() == String(prediction.labels[0].identifier).lowercased() {
                desiredItems.append(prediction)
            }
        }
        
        if health > 10 {
            health = 10
        }
        
        if desiredItems.count > 0 {
            desiredItems = filterFalsePositives(desiredItems)
        }
        
        if desiredItems.count == 0 && health > 0 {
            health -= 1
        }else if desiredItems.count > 0 {
            health += 4
            let boundingBoxCenter = boundingBoxCenter(filterNearestToScreenCenter(desiredItems))
            
            if smoothPosition.x < 0 {
                smoothPosition = boundingBoxCenter
            }else{
                smoothPosition = smoothPosition * 0.5 + boundingBoxCenter * 0.5
            }
        }
        
        textToSpeak = ""
        feedBackIntensity = 0.0
        if smoothPosition.x > 0 && health > 4 {
            feedBackIntensity = 0.15 + 0.85 * (1 - 2 * distPointPoint(pointA: smoothPosition, pointB: SCREEN_CENTER))
            var textToSpeakX = ""
            if smoothPosition.x < 0.45 {
                textToSpeakX = "левее, ... "
            }else if smoothPosition.x >= 0.45 && smoothPosition.x < 0.55 {
                textToSpeakX = " "
            }else{
                textToSpeakX = "правее, ... "
            }
            
            var textToSpeakY = ""
            if smoothPosition.y < 0.45 {
                textToSpeakY = "ниже, ... "
            }else if smoothPosition.y >= 0.45 && smoothPosition.y < 0.55 {
                textToSpeakY = " "
            }else{
                textToSpeakY = "выше, ... "
            }
            
            if textToSpeakX == " " && textToSpeakY == " " {
                textToSpeak = "Предмет в центре"
            }else{
                textToSpeak = textToSpeakX + textToSpeakY
            }
        }
    }
    
    private func filterFalsePositives(_ predictions: [VNRecognizedObjectObservation]) -> [VNRecognizedObjectObservation] {
        var filteredPredictions = [VNRecognizedObjectObservation]()
        for i in 0..<predictions.count{
            if predictions[i].boundingBox.width > 0.7 || predictions[i].boundingBox.height > 0.7 {
                continue
            }else{
                filteredPredictions.append(predictions[i])
            }
        }
        return filteredPredictions
    }
    
    private func filterNearestToScreenCenter(_ predictions: [VNRecognizedObjectObservation]) -> VNRecognizedObjectObservation {
        var minDistance = distPredPoint(prediction: predictions[0], point: SCREEN_CENTER)
        var nearestToScreenCenter = predictions[0]
        if predictions.count > 1 {
            for i in 1..<predictions.count {
                if minDistance > distPredPoint(prediction: predictions[i], point: SCREEN_CENTER) {
                    minDistance = distPredPoint(prediction: predictions[i], point: SCREEN_CENTER)
                    nearestToScreenCenter = predictions[i]
                }
            }
        }
        return nearestToScreenCenter
    }
    
    private func boundingBoxCenter(_ prediction: VNRecognizedObjectObservation) -> Point {
        let rect = prediction.boundingBox
        let boundingBoxCenter = Point(x: Double(rect.midX), y: Double(rect.midY))
        return boundingBoxCenter
    }
    
    private func distPredPoint(prediction: VNRecognizedObjectObservation, point: Point) -> Double {
        let boundingBoxCenter = boundingBoxCenter(prediction)
        let distance = sqrt(pow((point.x - boundingBoxCenter.x), 2) + pow((point.y - boundingBoxCenter.y), 2))
        return distance
    }
    
    private func distPointPoint(pointA: Point, pointB: Point) -> Double {
        let distance = sqrt(pow((pointA.x - pointB.x), 2) + pow((pointA.y - pointB.y), 2))
        return distance
    }
}
