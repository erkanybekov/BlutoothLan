//  Created by Erlan Kanybekov on 2/8/26.
//

//  BiometricAuthService.swift
//  BlutoothLan
//
//  Biometric authentication (Face ID / Touch ID) service

import Foundation
import LocalAuthentication

// MARK: - Biometric Auth Error

enum BiometricAuthError: LocalizedError {
    case notAvailable
    case authenticationFailed
    case userCancel
    case userFallback
    case systemCancel
    case passcodeNotSet
    case biometryNotEnrolled
    case biometryLockout
    case other(String)
    
    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "Biometric authentication is not available on this device"
        case .authenticationFailed:
            return "Authentication failed"
        case .userCancel:
            return "Authentication cancelled by user"
        case .userFallback:
            return "User chose to use passcode"
        case .systemCancel:
            return "Authentication cancelled by system"
        case .passcodeNotSet:
            return "Device passcode is not set"
        case .biometryNotEnrolled:
            return "Face ID or Touch ID is not enrolled"
        case .biometryLockout:
            return "Biometry is locked out. Please try passcode."
        case .other(let message):
            return message
        }
    }
}

// MARK: - Biometric Type

enum BiometricType {
    case faceID
    case touchID
    case none
    
    var displayName: String {
        switch self {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .none: return "Biometrics"
        }
    }
}

// MARK: - BiometricAuthService

final class BiometricAuthService {
    
    // MARK: - Properties
    
    private let context = LAContext()
    
    // MARK: - Public Methods
    
    /// Check if biometric authentication is available
    func isBiometricAvailable() -> Bool {
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }
    
    /// Get biometric type (Face ID / Touch ID)
    func biometricType() -> BiometricType {
        guard isBiometricAvailable() else { return .none }
        
        switch context.biometryType {
        case .faceID:
            return .faceID
        case .touchID:
            return .touchID
        case .none:
            return .none
        @unknown default:
            return .none
        }
    }
    
    /// Authenticate user with biometrics
    /// - Parameter reason: Reason for authentication shown to user
    /// - Returns: True if authenticated successfully
    func authenticate(reason: String = "Authenticate to continue") async throws -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        context.localizedFallbackTitle = "Use Passcode"
        
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw mapError(error)
        }
        
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
            return success
        } catch let error as LAError {
            throw mapLAError(error)
        } catch {
            throw BiometricAuthError.other(error.localizedDescription)
        }
    }
    
    /// Authenticate with biometrics or passcode as fallback
    func authenticateWithFallback(reason: String = "Authenticate to continue") async throws -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw mapError(error)
        }
        
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
            return success
        } catch let error as LAError {
            throw mapLAError(error)
        } catch {
            throw BiometricAuthError.other(error.localizedDescription)
        }
    }
    
    // MARK: - Private Helpers
    
    private func mapError(_ error: NSError?) -> BiometricAuthError {
        guard let error = error as? LAError else {
            return .other(error?.localizedDescription ?? "Unknown error")
        }
        return mapLAError(error)
    }
    
    private func mapLAError(_ error: LAError) -> BiometricAuthError {
        switch error.code {
        case .authenticationFailed:
            return .authenticationFailed
        case .userCancel:
            return .userCancel
        case .userFallback:
            return .userFallback
        case .systemCancel:
            return .systemCancel
        case .passcodeNotSet:
            return .passcodeNotSet
        case .biometryNotAvailable:
            return .notAvailable
        case .biometryNotEnrolled:
            return .biometryNotEnrolled
        case .biometryLockout:
            return .biometryLockout
        default:
            return .other(error.localizedDescription)
        }
    }
}
