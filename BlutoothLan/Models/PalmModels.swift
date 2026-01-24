//
//  PalmModels.swift
//  BlutoothLan
//
//  Palm Authentication Models
//

import Foundation

// MARK: - Landmark Model
struct PalmLandmark: Codable, Identifiable {
    let id = UUID()
    let x: Float
    let y: Float
    let z: Float
    
    enum CodingKeys: String, CodingKey {
        case x, y, z
    }
}

// MARK: - Detection State
enum PalmDetectionState: Equatable {
    case idle
    case detecting
    case success(landmarks: [PalmLandmark], confidence: Float)
    case error(String)
    
    static func == (lhs: PalmDetectionState, rhs: PalmDetectionState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.detecting, .detecting):
            return true
        case let (.success(l1, c1), .success(l2, c2)):
            return l1.count == l2.count && c1 == c2
        case let (.error(e1), .error(e2)):
            return e1 == e2
        default:
            return false
        }
    }
}

// MARK: - Verification Request
struct PalmVerificationRequest: Codable {
    let landmarks: [PalmLandmark]
    let accuracy: Double
    let timestamp: Int64
    let userId: String?
    
    init(landmarks: [PalmLandmark], accuracy: Double, userId: String? = nil) {
        self.landmarks = landmarks
        self.accuracy = accuracy
        self.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        self.userId = userId
    }
}

// MARK: - Verification Response
struct PalmVerificationResponse: Codable {
    let verified: Bool
    let confidence: Double
    let message: String
    let timestamp: Int64
    let userId: String?
}

// MARK: - Verification State
enum PalmVerificationState: Equatable {
    case idle
    case loading
    case success(PalmVerificationResponse)
    case error(String)
    
    static func == (lhs: PalmVerificationState, rhs: PalmVerificationState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading):
            return true
        case let (.success(r1), .success(r2)):
            return r1.verified == r2.verified && r1.confidence == r2.confidence
        case let (.error(e1), .error(e2)):
            return e1 == e2
        default:
            return false
        }
    }
}
