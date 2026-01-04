//
//  ChatView.swift
//  BlutoothLan
//
//  Created by Erlan Kanybekov on 1/4/26.
//


//
//  ChatView.swift
//  BlutoothLan
//
//  P2P Chat interface using Multipeer Connectivity
//

import SwiftUI
import MultipeerConnectivity

struct ChatView: View {
    @StateObject private var viewModel = ChatViewModel()
    @State private var messageText: String = ""
    @State private var showPeersList: Bool = false
    @FocusState private var isInputFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // Status bar
            statusBar
            
            // Messages list
            messagesScrollView
            
            // Input area
            messageInputBar
        }
        .navigationTitle("P2P Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showPeersList = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "person.2")
                        Text("\(viewModel.connectedPeersCount)")
                            .font(.caption)
                    }
                }
                
                Menu {
                    Button(viewModel.isAdvertising ? "Stop Advertising" : "Start Advertising") {
                        viewModel.isAdvertising ? viewModel.stopAdvertising() : viewModel.startAdvertising()
                    }
                    Button(viewModel.isBrowsing ? "Stop Browsing" : "Start Browsing") {
                        viewModel.isBrowsing ? viewModel.stopBrowsing() : viewModel.startBrowsing()
                    }
                    Divider()
                    Button("Disconnect All", role: .destructive) {
                        viewModel.disconnect()
                    }
                    Button("Clear Messages", role: .destructive) {
                        viewModel.clearMessages()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showPeersList) {
            peersListSheet
        }
        .onAppear {
            viewModel.startAdvertising()
            viewModel.startBrowsing()
        }
    }
    
    // MARK: - Status Bar
    
    private var statusBar: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(viewModel.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(uiColor: .systemGroupedBackground))
    }
    
    private var statusColor: Color {
        if viewModel.connectedPeersCount > 0 {
            return .green
        } else if viewModel.isAdvertising || viewModel.isBrowsing {
            return .orange
        } else {
            return .gray
        }
    }
    
    // MARK: - Messages
    
    private var messagesScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if viewModel.messages.isEmpty {
                        emptyStateView
                    } else {
                        ForEach(viewModel.messages) { message in
                            MessageBubble(message: message, isFromMe: message.senderName == viewModel.myName)
                                .id(message.id)
                        }
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.messages.count) { _ in
                if let lastMessage = viewModel.messages.last {
                    withAnimation {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("No messages yet")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Connect to nearby devices to start chatting")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
    
    // MARK: - Input Bar
    
    private var messageInputBar: some View {
        HStack(spacing: 12) {
            TextField("Message", text: $messageText)
                .textFieldStyle(.roundedBorder)
                .focused($isInputFocused)
                .onSubmit {
                    sendMessage()
                }
            
            Button(action: sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .gray : .blue)
            }
            .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
        .background(Color(uiColor: .systemBackground))
    }
    
    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        
        viewModel.sendMessage(text)
        messageText = ""
    }
    
    // MARK: - Peers Sheet
    
    private var peersListSheet: some View {
        NavigationView {
            List {
                Section("Connected Peers") {
                    let connected = viewModel.peers.filter { $0.state == .connected }
                    if connected.isEmpty {
                        Text("No connected peers")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(connected) { peer in
                            peerRow(peer)
                        }
                    }
                }
                
                Section("Available Peers") {
                    let available = viewModel.peers.filter { $0.state == .notConnected }
                    if available.isEmpty {
                        Text("No available peers")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(available) { peer in
                            peerRow(peer)
                        }
                    }
                }
            }
            .navigationTitle("Nearby Devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        showPeersList = false
                    }
                }
            }
        }
    }
    
    private func peerRow(_ peer: PeerDevice) -> some View {
        HStack {
            Image(systemName: peer.state == .connected ? "person.fill.checkmark" : "person")
                .foregroundStyle(peer.state == .connected ? .green : .secondary)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.displayName)
                    .font(.headline)
                Text(stateText(peer.state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            if peer.state == .notConnected {
                Button("Connect") {
                    viewModel.invitePeer(peer)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
    
    private func stateText(_ state: MCSessionState) -> String {
        switch state {
        case .connected: return "Connected"
        case .connecting: return "Connecting..."
        case .notConnected: return "Not connected"
        @unknown default: return "Unknown"
        }
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: Message
    let isFromMe: Bool
    
    var body: some View {
        HStack {
            if isFromMe { Spacer(minLength: 60) }
            
            VStack(alignment: isFromMe ? .trailing : .leading, spacing: 4) {
                if !isFromMe {
                    Text(message.senderName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Text(message.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isFromMe ? Color.blue : Color(uiColor: .systemGray5))
                    .foregroundColor(isFromMe ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                
                Text(timeString(from: message.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            
            if !isFromMe { Spacer(minLength: 60) }
        }
    }
    
    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Preview

#Preview {
    ChatView()
}
