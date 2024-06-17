//  SearchItemTask.swift
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
    static func / (left: Point, right: Double) -> Point {
        return Point(x: left.x / right, y: left.y / right)
    }
}

class SearchProvider {
    var mode: Int // 0 - search item, 1 - search text
    var searchValue: String = ""
    var textToSpeak: String = ""
    var feedBackIntensity: Double = 0.0
    
    private var health: Int = 0 // to prevent trigger on false positive one-frame detections
    private var smoothPosition: Point = Point(x: -1.0, y: -1.0)
    
    private let SCREEN_CENTER: Point = Point(x: 0.5, y: 0.5)
    private let CENTER_RADIUS: Double = 0.05
    private let HEALTH_MAX: Int = 10
    private let HEALTH_IN_ON_DETECT: Int = 4
    private let HEALTH_OUT_NO_DETECT: Int = 1
    private let SMOOTH_FACTOR: Double = 0.1
    
    init() {
        mode = 0
    }
    
    func reset() ->() {
        self.searchValue = ""
        health = 0
        smoothPosition = Point(x: -1.0, y: -1.0)
        textToSpeak = ""
        feedBackIntensity = 0.0
    }
    
    func initiateSearch(mode: Int, searchValue: String) -> () {
        reset()
        self.mode = mode
        self.searchValue = searchValue
    }
    
    func processDetectionResults(recognizedObjects: [VNRecognizedObjectObservation]) -> () {
        var desiredItems = [VNRecognizedObjectObservation]()
        
        for prediction in recognizedObjects {
            if self.searchValue.lowercased() == String(prediction.labels[0].identifier).lowercased() {
                desiredItems.append(prediction)
            }
        }
        
        if desiredItems.count > 0 {
            desiredItems = filterFalsePositives(desiredItems)
        }
        
        if desiredItems.count == 0 && health > 0 {
            health -= HEALTH_OUT_NO_DETECT
        } else if desiredItems.count > 0 {
            health += HEALTH_IN_ON_DETECT
            let boundingBoxCenter = boundingBoxCenter(filterNearestToScreenCenter(desiredItems))
            
            if smoothPosition.x < 0 {
                smoothPosition = boundingBoxCenter
            } else {
                smoothPosition = smoothPosition * SMOOTH_FACTOR + boundingBoxCenter * (1 - SMOOTH_FACTOR)
            }
        }
        
        updateNotifications()
    }
    
    func processDetectionResults(recognizedObjects: [VNRecognizedTextObservation]) -> () {
        var desiredItems = [VNRecognizedTextObservation]()
        
        for observation in recognizedObjects {
            guard let topCandidate = observation.topCandidates(1).first else { continue }
            if topCandidate.string.lowercased().contains(self.searchValue.lowercased()) {
                desiredItems.append(observation)
            }
        }
        
        if desiredItems.count == 0 && health > 0 {
            health -= HEALTH_OUT_NO_DETECT * 2
        } else if desiredItems.count > 0 {
            health += HEALTH_IN_ON_DETECT
            let boundingBoxCenter = boundingBoxCenter(filterNearestToScreenCenter(desiredItems))
            
            // TODO here call func to locate searched text in text block to get more precision on long strings of text
            
            if smoothPosition.x < 0 {
                smoothPosition = boundingBoxCenter
            } else {
                smoothPosition = smoothPosition * SMOOTH_FACTOR + boundingBoxCenter * (1 - SMOOTH_FACTOR)
            }
        }
        
        updateNotifications()
    }
    
    private func updateNotifications() -> () {
        if health > HEALTH_MAX {
            health = HEALTH_MAX
        } else if health < 0 {
            health = 0
        }
        
        textToSpeak = ""
        feedBackIntensity = 0.0
        
        if smoothPosition.x > 0 && health > HEALTH_IN_ON_DETECT {
            feedBackIntensity = 0.15 + 0.85 * (1 - 2 * distancePointToPoint(pointA: smoothPosition, pointB: SCREEN_CENTER)) // < 0.15 is almost not felt
            
            var textToSpeakX = ""
            if smoothPosition.x < 0.5 - CENTER_RADIUS {
                textToSpeakX = "левее, ... "
            } else if smoothPosition.x >= 0.5 - CENTER_RADIUS && smoothPosition.x < 0.5 + CENTER_RADIUS {
                textToSpeakX = " "
            } else {
                textToSpeakX = "правее, ... "
            }
            
            var textToSpeakY = ""
            if smoothPosition.y < 0.5 - CENTER_RADIUS {
                textToSpeakY = "ниже, ... "
            } else if smoothPosition.y >= 0.5 - CENTER_RADIUS && smoothPosition.y < 0.5 + CENTER_RADIUS {
                textToSpeakY = " "
            } else {
                textToSpeakY = "выше, ... "
            }
            
            if textToSpeakX == " " && textToSpeakY == " " {
                if mode == 0 {
                    textToSpeak = "Предмет в центре ... "
                } else {
                    textToSpeak = "Текст в центре ... "
                }
            } else {
                textToSpeak = textToSpeakX + textToSpeakY
            }
        }
    }
    
    // TODO redo this, + add filter false positive predictions on the edge of screen
    private func filterFalsePositives(_ predictions: [VNRecognizedObjectObservation]) -> [VNRecognizedObjectObservation] {
        var filteredPredictions = [VNRecognizedObjectObservation]()
        for i in 0..<predictions.count {
            if predictions[i].boundingBox.width > 0.9 || predictions[i].boundingBox.height > 0.9 {
                continue
            } else {
                filteredPredictions.append(predictions[i])
            }
        }
        return filteredPredictions
    }
        
    private func filterNearestToScreenCenter(_ predictions: [VNRecognizedObjectObservation]) -> VNRecognizedObjectObservation {
        var minDistance = distancePredictionToPoint(prediction: predictions[0], point: SCREEN_CENTER)
        var nearestToScreenCenter = predictions[0]
        if predictions.count > 1 {
            for i in 1..<predictions.count {
                if minDistance > distancePredictionToPoint(prediction: predictions[i], point: SCREEN_CENTER) {
                    minDistance = distancePredictionToPoint(prediction: predictions[i], point: SCREEN_CENTER)
                    nearestToScreenCenter = predictions[i]
                }
            }
        }
        return nearestToScreenCenter
    }
    
    private func filterNearestToScreenCenter(_ predictions: [VNRecognizedTextObservation]) -> VNRecognizedTextObservation {
        var minDistance:Double = 1.0
        var nearestToScreenCenter = predictions[0]
        if predictions.count > 1 {
            for i in 1..<predictions.count {
                let center = boundingBoxCenter(predictions[i])
                if minDistance > distancePointToPoint(pointA: center, pointB: SCREEN_CENTER) {
                    minDistance = distancePointToPoint(pointA: center, pointB: SCREEN_CENTER)
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
    
    private func boundingBoxCenter(_ prediction: VNRecognizedTextObservation) -> Point {
        var boundingBoxCenter = Point(x: -1.0, y: -1.0)
        guard let topCandidate = prediction.topCandidates(1).first else { return boundingBoxCenter}
        if let box = try? topCandidate.boundingBox(for: topCandidate.string.range(of: topCandidate.string)!) {
            let topLeft = Point(x: Double(box.topLeft.x), y: Double(box.topLeft.y))
            let bottomRight = Point(x: Double(box.bottomRight.x), y: Double(box.bottomRight.y))
            boundingBoxCenter = (topLeft + bottomRight) / 2
        }
        return boundingBoxCenter
    }
    
    private func distancePredictionToPoint(prediction: VNRecognizedObjectObservation, point: Point) -> Double {
        let boundingBoxCenter = boundingBoxCenter(prediction)
        let distance = sqrt(pow((point.x - boundingBoxCenter.x), 2) + pow((point.y - boundingBoxCenter.y), 2))
        return distance
    }
    
    private func distancePointToPoint(pointA: Point, pointB: Point) -> Double {
        let distance = sqrt(pow((pointA.x - pointB.x), 2) + pow((pointA.y - pointB.y), 2))
        return distance
    }
    
    static let modelClassesCustom = [
        "ключи": "Keys", "ключ": "Keys", "включи": "Keys",
        "очки": "Glasses",
        "шапка": "Knitted hat",
        "шляпа": "Hat",
        "белая трость": "White cane",
        "кепка": "Cap",
        "дверная ручка": "Door handle", "верная ручка": "Door handle",
        "перчатка": "Glove", "перчатки": "Glove",
        "сушилка для рук": "Hand dryer",
        "выключатель": "Light switch",
        "розетка": "Power plugs and sockets",
        "отвёртка": "Screwdriver",
        "кран": "Tap",
        "кошелек": "Wallet", "бумажник": "Wallet",
        "туалетная бумага": "Toilet paper"
    ]
     
    static let modelClassesCOCO = [
        "человек": "person",
        "велосипед": "bicycle",
        "машина": "car", "автомобиль": "car",
        "мотоцикл": "motorbike",
        "самолёт": "aeroplane",
        "автобус": "bus",
        "поезд": "train",
        "грузовик": "truck",
        "лодка": "boat",
        "светофор": "traffic light",
        "гидрант": "fire hydrant",
        "знак стоп": "stop sign",
        "парковочный счётчик": "parking meter",
        "скамейка": "bench", "скамья": "bench",
        "птица": "bird",
        "кошка": "cat", "кот": "cat",
        "собака": "dog", "пёс": "dog",
        "лошадь": "horse",
        "овца": "sheep",
        "корова": "cow",
        "слон": "elephant",
        "медведь": "bear",
        "зебра": "zebra",
        "жираф": "giraffe",
        "рюкзак": "backpack",
        "зонт": "umbrella", "зонтик": "umbrella",
        "сумка": "handbag", "сумочка": "handbag",
        "галстук": "tie",
        "чемодан": "suitcase", "кейс": "suitcase",
        "фризби": "frisbee",
        "лыжи": "skis",
        "сноуборд": "snowboard",
        "мяч": "sports ball",
        "воздушный змей": "kite",
        "бита": "baseball bat", "убита": "baseball bat", "убито": "baseball bat",
        "бейсбольная перчатка": "baseball glove",
        "скейтборд": "skateboard",
        "доска для сёрфинга": "surfboard",
        "теннисная ракетка": "tennis racket",
        "бутылка": "bottle",
        "бокал": "wine glass",
        "кружка": "cup", "крошка": "cup", "чашка": "cup",
        "вилка": "fork",
        "нож": "knife", "наш": "knife",
        "ложка": "spoon",
        "чаша": "bowl",
        "банан": "banana",
        "яблоко": "apple",
        "сэндвич": "sandwich",
        "апельсин": "orange", "мандарин": "orange",
        "брокколи": "broccoli",
        "морковь": "carrot", "морковка": "carrot",
        "хот дог": "hot dog",
        "пицца": "pizza",
        "пончик": "donut", "бублик": "donut",
        "торт": "cake", "пирог": "cake",
        "кресло": "chair",
        "диван": "sofa",
        "растение в горшке": "pottedplant", "растения в горшке": "pottedplant",
        "кровать": "bed",
        "стол": "dining table",
        "унитаз": "toilet", "туалет": "toilet",
        "телевизор": "tv", "монитор": "tv",
        "ноутбук": "laptop",
        "мышь": "mouse",
        "пульт": "remote",
        "клавиатура": "keyboard",
        "телефон": "cell phone",
        "микроволновая": "microwave", "микроволновка": "microwave",
        "печь": "oven",
        "духовка": "oven",
        "тостер": "toaster",
        "раковина": "sink",
        "холодильник": "refrigerator",
        "книга": "book",
        "часы": "clock",
        "ваза": "vase",
        "ножницы": "scissors",
        "плюшевый мишка": "teddy bear",
        "фен": "hair drier",
        "зубная щетка": "toothbrush"
    ]
}
