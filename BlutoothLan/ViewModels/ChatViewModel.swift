//
//  ChatViewModel.swift
//  BlutoothLan
//
//  Created by Erlan Kanybekov on 1/4/26.
//


//
//  ChatViewModel.swift
//  BlutoothLan
//
//  ViewModel for P2P Chat
//

import Foundation
import Combine
import MultipeerConnectivity
import UIKit

@MainActor
final class ChatViewModel: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published var messages: [Message] = []
    @Published var peers: [PeerDevice] = []
    @Published var statusMessage: String = "Idle"
    @Published var isAdvertising: Bool = false
    @Published var isBrowsing: Bool = false
    
    var myName: String {
        // Must match the format used in MultipeerService
        let key = "MultipeerDeviceUUID"
        let uuid = UserDefaults.standard.string(forKey: key) ?? ""
        return "\(UIDevice.current.name) (\(uuid))"
    }
    
    var connectedPeersCount: Int {
        peers.filter { $0.state == .connected }.count
    }
    
    // MARK: - Private Properties
    
    private let multipeerService: MultipeerServicing
    private var cancellables: Set<AnyCancellable> = []
    
    // MARK: - Init
    
    init(multipeerService: MultipeerServicing = MultipeerService()) {
        self.multipeerService = multipeerService
        bind()
    }
    
    // MARK: - Binding
    
    private func bind() {
        // Messages
        multipeerService.messagesPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$messages)
        
        // Peers
        multipeerService.peersPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$peers)
        
        // Status
        multipeerService.statusPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$statusMessage)
        
        // Advertising state
        multipeerService.isAdvertisingPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$isAdvertising)
        
        // Browsing state
        multipeerService.isBrowsingPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$isBrowsing)
    }
    
    // MARK: - Public Methods
    
    func startAdvertising() {
        multipeerService.startAdvertising()
    }
    
    func stopAdvertising() {
        multipeerService.stopAdvertising()
    }
    
    func startBrowsing() {
        multipeerService.startBrowsing()
    }
    
    func stopBrowsing() {
        multipeerService.stopBrowsing()
    }
    
    func sendMessage(_ text: String) {
        multipeerService.sendMessage(text)
    }
    
    func invitePeer(_ peer: PeerDevice) {
        multipeerService.invitePeer(peer)
    }
    
    func disconnect() {
        multipeerService.disconnect()
    }
    
    func clearMessages() {
        messages.removeAll()
    }
}