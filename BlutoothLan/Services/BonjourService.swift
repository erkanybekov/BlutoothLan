//
//  BonjourService.swift
//  BlutoothLan
//
//  Created by Erlan Kanybekov on 10/17/25.
//

import Foundation
import Combine
import UIKit

final class BonjourService: NSObject {
    private let serviceType = "_blutoothlan._tcp."
    private var browser: NetServiceBrowser?
    private var advertiser: NetService?
    private var resolvingServices: Set<NetService> = []

    private let peersSubject = CurrentValueSubject<[LANPeer], Never>([])
    private let statusSubject = CurrentValueSubject<String, Never>("Idle")
    private let browsingSubject = CurrentValueSubject<Bool, Never>(false)
    private let advertisingSubject = CurrentValueSubject<Bool, Never>(false)

    var peersPublisher: AnyPublisher<[LANPeer], Never> { peersSubject.eraseToAnyPublisher() }
    var statusPublisher: AnyPublisher<String, Never> { statusSubject.eraseToAnyPublisher() }
    var isBrowsingPublisher: AnyPublisher<Bool, Never> { browsingSubject.eraseToAnyPublisher() }
    var isAdvertisingPublisher: AnyPublisher<Bool, Never> { advertisingSubject.eraseToAnyPublisher() }

    private var browseTimeoutTask: Task<Void, Never>?

    func startBrowsing(timeout: TimeInterval? = 15) {
        peersSubject.value = []
        browser?.stop()
        browser = NetServiceBrowser()
        browser?.delegate = self
        browser?.searchForServices(ofType: serviceType, inDomain: "local.")
        browsingSubject.send(true)
        statusSubject.send("Browsing...")

        browseTimeoutTask?.cancel()
        if let timeout {
            browseTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await MainActor.run {
                    self?.stopBrowsing()
                }
            }
        }
    }

    func stopBrowsing() {
        browser?.stop()
        browsingSubject.send(false)
        statusSubject.send(advertisingSubject.value ? "Advertising" : "Idle")
        for s in resolvingServices { s.stop() }
        resolvingServices.removeAll()
        browseTimeoutTask?.cancel()
        browseTimeoutTask = nil
    }

    func startAdvertising(port: Int = 0) {
        advertiser?.stop()
        let deviceName = UIDevice.current.name
        let service = NetService(domain: "local.", type: serviceType, name: deviceName, port: Int32(port))
        service.includesPeerToPeer = true
        service.delegate = self
        // Если не требуется принимать входящие соединения, достаточно publish()
        service.publish(options: [NetService.Options.listenForConnections])
        advertiser = service
        advertisingSubject.send(true)
        statusSubject.send("Advertising...")
    }

    func stopAdvertising() {
        advertiser?.stop()
        advertiser = nil
        advertisingSubject.send(false)
        statusSubject.send(browsingSubject.value ? "Browsing..." : "Idle")
    }
}

extension BonjourService: NetServiceBrowserDelegate, NetServiceDelegate {
    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        statusSubject.send("Searching...")
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        statusSubject.send(advertisingSubject.value ? "Advertising" : "Idle")
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
        statusSubject.send("Browse error: \(errorDict)")
        browsingSubject.send(false)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolvingServices.insert(service)
        service.resolve(withTimeout: 5.0)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let removedName = service.name
        var peers = peersSubject.value
        peers.removeAll { $0.name == removedName }
        peersSubject.send(peers)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        resolvingServices.remove(sender)
        let host = sender.hostName
        let port = sender.port > 0 ? sender.port : nil
        let peer = LANPeer(name: sender.name, hostName: host, domain: sender.domain, port: port)

        var peers = peersSubject.value
        if !peers.contains(peer) {
            peers.append(peer)
            peersSubject.send(peers)
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        resolvingServices.remove(sender)
    }

    func netServiceWillPublish(_ sender: NetService) {
        statusSubject.send("Publishing...")
    }

    func netServiceDidPublish(_ sender: NetService) {
        statusSubject.send("Advertising as \(sender.name)")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String : NSNumber]) {
        statusSubject.send("Advertise error: \(errorDict)")
        advertisingSubject.send(false)
    }

    func netServiceDidStop(_ sender: NetService) { }
}
