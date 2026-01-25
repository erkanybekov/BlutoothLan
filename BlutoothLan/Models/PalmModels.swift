//
//  PalmModels.swift
//  BlutoothLan
//
//  Palm Print Recognition Models
//

import Foundation
import UIKit

// MARK: - Camera State

enum PalmCameraState: Equatable {
    case idle
    case ready
    case captured(UIImage)
    case processing
    case error(String)
    
    static func == (lhs: PalmCameraState, rhs: PalmCameraState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.ready, .ready), (.processing, .processing):
            return true
        case let (.captured(img1), .captured(img2)):
            return img1 == img2
        case let (.error(msg1), .error(msg2)):
            return msg1 == msg2
        default:
            return false
        }
    }
}

// Legacy models removed - using HandGeometryFeatures instead

// MARK: - Verification Result

struct PalmVerificationResult {
    let isMatch: Bool
    let matchPercentage: Double
    let goodMatches: Int
    let totalKeypoints: Int
    let message: String
    let timestamp: Date
    
    init(isMatch: Bool, matchPercentage: Double, goodMatches: Int, totalKeypoints: Int) {
        self.isMatch = isMatch
        self.matchPercentage = matchPercentage
        self.goodMatches = goodMatches
        self.totalKeypoints = totalKeypoints
        self.timestamp = Date()
        
        if isMatch {
            self.message = String(format: "✓ Verified (%.0f%% match)", matchPercentage * 100)
        } else {
            self.message = String(format: "✗ Not recognized (%.0f%% match)", matchPercentage * 100)
        }
    }
}

// MARK: - Auth Mode

enum PalmAuthMode {
    case register
    case verify
    
    var title: String {
        switch self {
        case .register: return "Register Palm"
        case .verify: return "Verify Palm"
        }
    }
    
    var actionTitle: String {
        switch self {
        case .register: return "Register"
        case .verify: return "Verify"
        }
    }
}

// MARK: - Verification State

enum PalmVerificationState: Equatable {
    case idle
    case loading
    case success(PalmVerificationResult)
    case error(String)
    
    var isSuccess: Bool {
        if case .success(let result) = self {
            return result.isMatch
        }
        return false
    }
    
    static func == (lhs: PalmVerificationState, rhs: PalmVerificationState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading):
            return true
        case let (.success(r1), .success(r2)):
            return r1.isMatch == r2.isMatch && r1.matchPercentage == r2.matchPercentage
        case let (.error(e1), .error(e2)):
            return e1 == e2
        default:
            return false
        }
    }
}

// Legacy template removed - using StoredHandTemplate instead
