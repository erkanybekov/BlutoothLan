//
//  PrintJob.swift
//  BlutoothLan
//
//  Created by Erlan Kanybekov on 1/30/26.
//

import Foundation
import UIKit

// MARK: - Print Status

enum PrintStatus: Equatable {
    case idle
    case processing
    case printing(progress: Double)
    case completed
    case failed(String)
    
    var isActive: Bool {
        switch self {
        case .processing, .printing:
            return true
        default:
            return false
        }
    }
    
    var description: String {
        switch self {
        case .idle:
            return "Ready"
        case .processing:
            return "Processing image..."
        case .printing(let progress):
            return String(format: "Printing... %.0f%%", progress * 100)
        case .completed:
            return "Completed"
        case .failed(let error):
            return "Failed: \(error)"
        }
    }
}

// MARK: - Print Job

struct PrintJob: Identifiable {
    let id = UUID()
    let originalImage: UIImage
    var processedImage: UIImage?
    var escposData: Data?
    let timestamp: Date
    var status: PrintStatus
    
    init(image: UIImage) {
        self.originalImage = image
        self.timestamp = Date()
        self.status = .idle
    }
}
