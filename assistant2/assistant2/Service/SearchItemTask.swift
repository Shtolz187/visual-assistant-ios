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
}

class SearchItemTask {
    var name: String
    var textToSpeak: String
    var feedBackIntensity: Double
    
    private var health: Int // to prevent trigger on false positive one-frame detections
    private var smoothPosition: Point
    
    private let SCREEN_CENTER = Point(x: 0.5, y: 0.5)
    private let HEALTH_MAX: Int = 10
    private let HEALTH_IN_ON_DETECT: Int = 4
    private let HEALTH_OUT_NO_DETECT: Int = 1
    
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
        
        if desiredItems.count > 0 {
            desiredItems = filterFalsePositives(desiredItems)
        }
        
        if desiredItems.count == 0 && health > 0 {
            health -= 1
        } else if desiredItems.count > 0 {
            health += 4
            let boundingBoxCenter = boundingBoxCenter(filterNearestToScreenCenter(desiredItems))
            
            if smoothPosition.x < 0 {
                smoothPosition = boundingBoxCenter
            } else {
                smoothPosition = smoothPosition * 0.5 + boundingBoxCenter * 0.5
            }
        }
        
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
            if smoothPosition.x < 0.45 {
                textToSpeakX = "левее, ... "
            } else if smoothPosition.x >= 0.45 && smoothPosition.x < 0.55 {
                textToSpeakX = " "
            } else {
                textToSpeakX = "правее, ... "
            }
            
            var textToSpeakY = ""
            if smoothPosition.y < 0.45 {
                textToSpeakY = "ниже, ... "
            } else if smoothPosition.y >= 0.45 && smoothPosition.y < 0.55 {
                textToSpeakY = " "
            } else {
                textToSpeakY = "выше, ... "
            }
            
            if textToSpeakX == " " && textToSpeakY == " " {
                textToSpeak = "Предмет в центре"
            } else {
                textToSpeak = textToSpeakX + textToSpeakY
            }
        }
    }
    
    // TODO filter false positive predictions on the edge of screen
    private func filterFalsePositives(_ predictions: [VNRecognizedObjectObservation]) -> [VNRecognizedObjectObservation] {
        var filteredPredictions = [VNRecognizedObjectObservation]()
        for i in 0..<predictions.count {
            if predictions[i].boundingBox.width > 0.8 || predictions[i].boundingBox.height > 0.8 {
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
    
    private func boundingBoxCenter(_ prediction: VNRecognizedObjectObservation) -> Point {
        let rect = prediction.boundingBox
        let boundingBoxCenter = Point(x: Double(rect.midX), y: Double(rect.midY))
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
    
    let modelClassesCustom = [
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
     
    let modelClassesCOCO = [
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
