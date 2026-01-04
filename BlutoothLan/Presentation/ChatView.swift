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
import PhotosUI
import MultipeerConnectivity

struct ChatView: View {
    @StateObject private var viewModel = ChatViewModel()
    @State private var messageText: String = ""
    @State private var showPeersList: Bool = false
    @State private var selectedPhotoItem: PhotosPickerItem?
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
        .onChange(of: selectedPhotoItem) { newItem in
            handleSelectedPhoto(newItem)
        }
        .onAppear {
            viewModel.startAdvertising()
            viewModel.startBrowsing()
        }
    }
    
    // MARK: - Photo Handling
    
    private func handleSelectedPhoto(_ item: PhotosPickerItem?) {
        guard let item = item else { return }
        
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                await MainActor.run {
                    viewModel.sendImage(image)
                    selectedPhotoItem = nil
                }
            }
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
            // Image picker button
            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                Image(systemName: "photo")
                    .font(.system(size: 22))
                    .foregroundStyle(viewModel.canSendMessage ? .blue : .gray)
            }
            .disabled(!viewModel.canSendMessage || viewModel.isSendingImage)
            
            // Text input field
            TextField("Message", text: $messageText)
                .textFieldStyle(.roundedBorder)
                .focused($isInputFocused)
                .onSubmit {
                    sendMessage()
                }
            
            // Send button or loading indicator
            if viewModel.isSendingImage {
                ProgressView()
                    .frame(width: 32, height: 32)
            } else {
                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(canSendTextMessage ? .blue : .gray)
                }
                .disabled(!canSendTextMessage)
            }
        }
        .padding()
        .background(Color(uiColor: .systemBackground))
    }
    
    private var canSendTextMessage: Bool {
        let hasText = !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText && viewModel.canSendMessage
    }
    
    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, viewModel.canSendMessage else { return }
        
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
    
    @State private var showFullScreenImage: Bool = false
    
    var body: some View {
        HStack {
            if isFromMe { Spacer(minLength: 60) }
            
            VStack(alignment: isFromMe ? .trailing : .leading, spacing: 4) {
                // Sender name (for received messages)
                if !isFromMe {
                    Text(message.senderName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                // Content bubble
                messageContent
                
                // Timestamp
                Text(timeString(from: message.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            
            if !isFromMe { Spacer(minLength: 60) }
        }
        .fullScreenCover(isPresented: $showFullScreenImage) {
            FullScreenImageView(image: message.image, isPresented: $showFullScreenImage)
        }
    }
    
    // MARK: - Content Views
    
    @ViewBuilder
    private var messageContent: some View {
        if message.isImage, let image = message.image {
            imageContent(image)
        } else if let text = message.text {
            textContent(text)
        }
    }
    
    private func textContent(_ text: String) -> some View {
        Text(text)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isFromMe ? Color.blue : Color(uiColor: .systemGray5))
            .foregroundColor(isFromMe ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    
    private func imageContent(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 220, maxHeight: 300)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isFromMe ? Color.blue.opacity(0.3) : Color.gray.opacity(0.3), lineWidth: 1)
            )
            .onTapGesture {
                showFullScreenImage = true
            }
    }
    
    // MARK: - Helpers
    
    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Full Screen Image View

struct FullScreenImageView: View {
    let image: UIImage?
    @Binding var isPresented: Bool
    
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = lastScale * value
                            }
                            .onEnded { _ in
                                lastScale = scale
                                // Reset if zoomed out too much
                                if scale < 1.0 {
                                    withAnimation {
                                        scale = 1.0
                                        lastScale = 1.0
                                    }
                                }
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation {
                            if scale > 1.0 {
                                scale = 1.0
                                lastScale = 1.0
                            } else {
                                scale = 2.0
                                lastScale = 2.0
                            }
                        }
                    }
            }
            
            // Close button
            VStack {
                HStack {
                    Spacer()
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.white.opacity(0.8))
                            .padding()
                    }
                }
                Spacer()
            }
        }
    }
}

// MARK: - Preview

#Preview {
    ChatView()
}
