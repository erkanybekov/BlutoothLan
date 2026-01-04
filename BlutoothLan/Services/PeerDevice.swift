//
//  PeerDevice.swift
//  BlutoothLan
//
//  Created by Erlan Kanybekov on 1/4/26.
//


//
//  MultipeerService.swift
//  BlutoothLan
//
//  Multipeer Connectivity Service for P2P communication
//

import Foundation
import MultipeerConnectivity
import Combine
import UIKit

// MARK: - Models

struct PeerDevice: Identifiable, Hashable {
    let id: MCPeerID
    var displayName: String { id.displayName }
    var state: MCSessionState
    
    static func == (lhs: PeerDevice, rhs: PeerDevice) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Message Content Type

enum MessageContent: Codable, Equatable {
    case text(String)
    case image(Data)
    
    private enum CodingKeys: String, CodingKey {
        case type, value
    }
    
    private enum ContentType: String, Codable {
        case text, image
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ContentType.self, forKey: .type)
        
        switch type {
        case .text:
            let value = try container.decode(String.self, forKey: .value)
            self = .text(value)
        case .image:
            let value = try container.decode(Data.self, forKey: .value)
            self = .image(value)
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        switch self {
        case .text(let string):
            try container.encode(ContentType.text, forKey: .type)
            try container.encode(string, forKey: .value)
        case .image(let data):
            try container.encode(ContentType.image, forKey: .type)
            try container.encode(data, forKey: .value)
        }
    }
}

// MARK: - Message Model

struct Message: Identifiable, Codable {
    let id: UUID
    let content: MessageContent
    let senderName: String
    let timestamp: Date
    
    /// Convenience accessor for text content
    var text: String? {
        if case .text(let string) = content {
            return string
        }
        return nil
    }
    
    /// Convenience accessor for image content
    var image: UIImage? {
        if case .image(let data) = content {
            return UIImage(data: data)
        }
        return nil
    }
    
    /// Check if message contains an image
    var isImage: Bool {
        if case .image = content { return true }
        return false
    }
    
    // MARK: - Initializers
    
    init(text: String, senderName: String) {
        self.id = UUID()
        self.content = .text(text)
        self.senderName = senderName
        self.timestamp = Date()
    }
    
    init(imageData: Data, senderName: String) {
        self.id = UUID()
        self.content = .image(imageData)
        self.senderName = senderName
        self.timestamp = Date()
    }
    
    init(image: UIImage, senderName: String, compressionQuality: CGFloat = 0.7) {
        self.id = UUID()
        let data = image.jpegData(compressionQuality: compressionQuality) ?? Data()
        self.content = .image(data)
        self.senderName = senderName
        self.timestamp = Date()
    }
}

// MARK: - Service Protocol

protocol MultipeerServicing {
    var peersPublisher: AnyPublisher<[PeerDevice], Never> { get }
    var messagesPublisher: AnyPublisher<[Message], Never> { get }
    var isAdvertisingPublisher: AnyPublisher<Bool, Never> { get }
    var isBrowsingPublisher: AnyPublisher<Bool, Never> { get }
    var statusPublisher: AnyPublisher<String, Never> { get }
    
    func startAdvertising()
    func stopAdvertising()
    func startBrowsing()
    func stopBrowsing()
    func sendMessage(_ text: String)
    func sendImage(_ image: UIImage)
    func invitePeer(_ peer: PeerDevice)
    func disconnect()
}

// MARK: - Service Implementation

final class MultipeerService: NSObject, MultipeerServicing {
    
    // MARK: - Properties
    
    private let serviceType = "blutooth-chat"
    private let myPeerID: MCPeerID
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    
    // Publishers
    private let peersSubject = CurrentValueSubject<[PeerDevice], Never>([])
    private let messagesSubject = CurrentValueSubject<[Message], Never>([])
    private let advertisingSubject = CurrentValueSubject<Bool, Never>(false)
    private let browsingSubject = CurrentValueSubject<Bool, Never>(false)
    private let statusSubject = CurrentValueSubject<String, Never>("Idle")
    
    var peersPublisher: AnyPublisher<[PeerDevice], Never> { 
        peersSubject.eraseToAnyPublisher() 
    }
    var messagesPublisher: AnyPublisher<[Message], Never> { 
        messagesSubject.eraseToAnyPublisher() 
    }
    var isAdvertisingPublisher: AnyPublisher<Bool, Never> { 
        advertisingSubject.eraseToAnyPublisher() 
    }
    var isBrowsingPublisher: AnyPublisher<Bool, Never> { 
        browsingSubject.eraseToAnyPublisher() 
    }
    var statusPublisher: AnyPublisher<String, Never> { 
        statusSubject.eraseToAnyPublisher() 
    }
    
    // MARK: - Init
    
    // Static unique identifier for this device instance
    private static let deviceUUID: String = {
        // Try to get stored UUID or create new one
        let key = "MultipeerDeviceUUID"
        if let stored = UserDefaults.standard.string(forKey: key) {
            return stored
        }
        let newUUID = UUID().uuidString.prefix(8).lowercased()
        UserDefaults.standard.set(String(newUUID), forKey: key)
        return String(newUUID)
    }()
    
    override init() {
        // Use device name + unique suffix to distinguish devices with same name
        let deviceName = UIDevice.current.name
        let uniqueName = "\(deviceName) (\(MultipeerService.deviceUUID))"
        self.myPeerID = MCPeerID(displayName: uniqueName)
        
        super.init()
        
        // Setup session
        self.session = MCSession(
            peer: myPeerID,
            securityIdentity: nil,
            encryptionPreference: .required
        )
        self.session.delegate = self
    }
    
    // MARK: - Public Methods
    
    func startAdvertising() {
        advertiser = MCNearbyServiceAdvertiser(
            peer: myPeerID,
            discoveryInfo: nil,
            serviceType: serviceType
        )
        advertiser?.delegate = self
        advertiser?.startAdvertisingPeer()
        advertisingSubject.send(true)
        updateStatus()
    }
    
    func stopAdvertising() {
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        advertisingSubject.send(false)
        updateStatus()
    }
    
    func startBrowsing() {
        browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: serviceType)
        browser?.delegate = self
        browser?.startBrowsingForPeers()
        browsingSubject.send(true)
        updateStatus()
    }
    
    func stopBrowsing() {
        browser?.stopBrowsingForPeers()
        browser = nil
        browsingSubject.send(false)
        updateStatus()
    }
    
    func sendMessage(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !session.connectedPeers.isEmpty else {
            statusSubject.send("No connected peers")
            return
        }
        
        let message = Message(text: text, senderName: myPeerID.displayName)
        sendMessageToPeers(message)
    }
    
    func sendImage(_ image: UIImage) {
        guard !session.connectedPeers.isEmpty else {
            statusSubject.send("No connected peers")
            return
        }
        
        // Compress image to reduce transfer size
        let message = Message(image: image, senderName: myPeerID.displayName, compressionQuality: 0.6)
        sendMessageToPeers(message)
    }
    
    // MARK: - Private Send Helper
    
    private func sendMessageToPeers(_ message: Message) {
        // Add to local messages
        var messages = messagesSubject.value
        messages.append(message)
        messagesSubject.send(messages)
        
        // Send to all connected peers
        do {
            let data = try JSONEncoder().encode(message)
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
        } catch {
            statusSubject.send("Failed to send: \(error.localizedDescription)")
        }
    }
    
    func invitePeer(_ peer: PeerDevice) {
        guard let browser = browser else { return }
        browser.invitePeer(peer.id, to: session, withContext: nil, timeout: 30)
        statusSubject.send("Inviting \(peer.displayName)...")
    }
    
    func disconnect() {
        session.disconnect()
        updatePeersList()
        statusSubject.send("Disconnected")
    }
    
    // MARK: - Private Helpers
    
    private func updatePeersList() {
        // Get all connected and connecting peers
        let connectedPeers = session.connectedPeers.map { 
            PeerDevice(id: $0, state: .connected)
        }
        
        peersSubject.send(connectedPeers)
    }
    
    private func updateStatus() {
        var status = ""
        if advertisingSubject.value {
            status += "Advertising"
        }
        if browsingSubject.value {
            if !status.isEmpty { status += " & " }
            status += "Browsing"
        }
        if status.isEmpty {
            status = "Idle"
        }
        if !session.connectedPeers.isEmpty {
            status += " | \(session.connectedPeers.count) connected"
        }
        statusSubject.send(status)
    }
}

// MARK: - MCSessionDelegate

extension MultipeerService: MCSessionDelegate {
    
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async { [weak self] in
            self?.updatePeersList()
            self?.updateStatus()
            
            switch state {
            case .connected:
                self?.statusSubject.send("Connected to \(peerID.displayName)")
            case .connecting:
                self?.statusSubject.send("Connecting to \(peerID.displayName)...")
            case .notConnected:
                self?.statusSubject.send("\(peerID.displayName) disconnected")
            @unknown default:
                break
            }
        }
    }
    
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            do {
                let message = try JSONDecoder().decode(Message.self, from: data)
                var messages = self.messagesSubject.value
                messages.append(message)
                self.messagesSubject.send(messages)
            } catch {
                self.statusSubject.send("Failed to decode message: \(error.localizedDescription)")
            }
        }
    }
    
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        // Handle stream if needed
    }
    
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        // Handle resource transfer if needed
    }
    
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        // Handle resource completion if needed
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension MultipeerService: MCNearbyServiceAdvertiserDelegate {
    
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Auto-accept invitations (you can add UI confirmation if needed)
            invitationHandler(true, self.session)
            self.statusSubject.send("Accepted invitation from \(peerID.displayName)")
        }
    }
    
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.statusSubject.send("Advertising error: \(error.localizedDescription)")
            self?.advertisingSubject.send(false)
        }
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension MultipeerService: MCNearbyServiceBrowserDelegate {
    
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Add discovered peer to list
            var peers = self.peersSubject.value
            let newPeer = PeerDevice(id: peerID, state: .notConnected)
            
            if !peers.contains(where: { $0.id == peerID }) {
                peers.append(newPeer)
                self.peersSubject.send(peers)
            }
            
            self.statusSubject.send("Found \(peerID.displayName)")
        }
    }
    
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            var peers = self.peersSubject.value
            peers.removeAll { $0.id == peerID }
            self.peersSubject.send(peers)
            
            self.statusSubject.send("Lost \(peerID.displayName)")
        }
    }
    
    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.statusSubject.send("Browsing error: \(error.localizedDescription)")
            self?.browsingSubject.send(false)
        }
    }
}