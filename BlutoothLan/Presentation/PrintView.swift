//
//  PrintView.swift
//  BlutoothLan
//
//  Created by Erlan Kanybekov on 1/30/26.
//

import SwiftUI
import PhotosUI
import CoreBluetooth

struct PrintView: View {
    @StateObject private var viewModel: PrinterViewModel
    @State private var showImagePicker = false
    @State private var showCamera = false
    @State private var showSettings = false
    @State private var useHighQuality = true
    @State private var sourceType: UIImagePickerController.SourceType = .photoLibrary
    
    init(bluetoothService: BluetoothService) {
        self._viewModel = StateObject(wrappedValue: PrinterViewModel(bluetoothService: bluetoothService))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Status bar
            statusBar
            
            ScrollView {
                VStack(spacing: 20) {
                    // Printer status
                    printerStatusSection
                    
                    // Image selection
                    if viewModel.selectedImage == nil {
                        imageSelectionSection
                    } else {
                        // Image preview and controls
                        imagePreviewSection
                    }
                    
                    // Settings (when image is selected)
                    if viewModel.selectedImage != nil {
                        settingsSection
                    }
                }
                .padding()
            }
        }
        .sheet(isPresented: $showImagePicker) {
            ImagePicker(image: $viewModel.selectedImage, sourceType: sourceType)
        }
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") {
                viewModel.errorMessage = nil
            }
        } message: {
            if let error = viewModel.errorMessage {
                Text(error)
            }
        }
        .onChange(of: viewModel.selectedImage) { newImage in
            if newImage != nil {
                // Auto-process when image is selected
                Task {
                    try? await viewModel.processImage()
                }
            }
        }
        .onAppear {
            // Set high quality by default
            if useHighQuality {
                viewModel.contrast = 1.3
                viewModel.brightness = 0.15
                viewModel.threshold = 140
            }
        }
    }
    
    // MARK: - Status Bar
    
    private var statusBar: some View {
        HStack {
            Circle()
                .fill(viewModel.isPrinterReady ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            
            Text(viewModel.isPrinterReady ? "Printer Connected" : "No Printer Connected")
                .font(.caption)
                .foregroundStyle(viewModel.isPrinterReady ? .green : .secondary)
            
            Spacer()
            
            if viewModel.status.isActive {
                ProgressView()
                    .controlSize(.small)
                Text(viewModel.status.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(uiColor: .systemGroupedBackground))
    }
    
    // MARK: - Printer Status Section
    
    private var printerStatusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Printer Status", systemImage: "printer")
                .font(.headline)
            
            if let printer = viewModel.connectedPrinter {
                HStack {
                    Image(systemName: "printer.fill")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(printer.name ?? "Unknown Printer")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(printer.identifier.uuidString.prefix(8) + "...")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospaced()
                    }
                    Spacer()
                    
                    if viewModel.isPrinterReady {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                .padding()
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .cornerRadius(12)
                
                // Test buttons
                HStack(spacing: 12) {
                    Button {
                        Task {
                            try? await viewModel.testPrinter()
                        }
                    } label: {
                        Label("Test Print", systemImage: "printer")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    Button {
                        Task {
                            try? await viewModel.feedPaper()
                        }
                    } label: {
                        Label("Feed Paper", systemImage: "arrow.down")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        Task {
                            try? await viewModel.testAllWriteCharacteristics()
                        }
                    } label: {
                        Label("Probe", systemImage: "magnifyingglass")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "printer.slash")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    
                    Text("No printer connected")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    Text("Connect to a printer from the Bluetooth tab to start printing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .cornerRadius(12)
            }
        }
    }
    
    // MARK: - Image Selection Section
    
    private var imageSelectionSection: some View {
        VStack(spacing: 16) {
            Label("Select Image to Print", systemImage: "photo")
                .font(.headline)
            
            VStack(spacing: 12) {
                Button {
                    sourceType = .photoLibrary
                    showImagePicker = true
                } label: {
                    HStack {
                        Image(systemName: "photo.on.rectangle")
                        Text("Choose from Gallery")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
                
                Button {
                    sourceType = .camera
                    showImagePicker = true
                } label: {
                    HStack {
                        Image(systemName: "camera")
                        Text("Take Photo")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    // MARK: - Image Preview Section
    
    private var imagePreviewSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Preview", systemImage: "eye")
                    .font(.headline)
                
                Spacer()
                
                Button {
                    viewModel.clearSelection()
                } label: {
                    Label("Clear", systemImage: "xmark.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
            }
            
            // Original and Processed side by side
            HStack(spacing: 12) {
                // Original
                VStack(spacing: 8) {
                    Text("Original")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    if let image = viewModel.selectedImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 200)
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                    }
                }
                
                // Processed
                VStack(spacing: 8) {
                    Text("Print Preview")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    if let preview = viewModel.processedPreview {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 200)
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.blue.opacity(0.3), lineWidth: 2)
                            )
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                                .frame(height: 200)
                            
                            ProgressView()
                        }
                    }
                }
            }
            
            // Print button
            Button {
                Task {
                    try? await viewModel.printCurrentJob()
                }
            } label: {
                HStack {
                    Image(systemName: "printer.fill")
                    Text("Print Image")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(viewModel.canPrint ? Color.blue : Color.gray)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .disabled(!viewModel.canPrint)
            
            // Status message
            if case .printing(let progress) = viewModel.status {
                HStack {
                    ProgressView(value: progress)
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 40)
                }
            }
        }
    }
    
    // MARK: - Settings Section
    
    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                showSettings.toggle()
            } label: {
                HStack {
                    Label("Adjust Settings", systemImage: "slider.horizontal.3")
                        .font(.headline)
                    Spacer()
                    Image(systemName: showSettings ? "chevron.up" : "chevron.down")
                        .font(.caption)
                }
            }
            .buttonStyle(.plain)
            
            if showSettings {
                VStack(alignment: .leading, spacing: 20) {
                    // Quality preset
                    Toggle("High Quality Mode (Recommended)", isOn: $useHighQuality)
                        .tint(.blue)
                        .onChange(of: useHighQuality) { newValue in
                            if newValue {
                                viewModel.contrast = 1.3
                                viewModel.brightness = 0.15
                                viewModel.threshold = 140
                            } else {
                                viewModel.contrast = 1.0
                                viewModel.brightness = 0.0
                                viewModel.threshold = 128
                            }
                        }
                    
                    Divider()
                    
                    // Brightness
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Brightness")
                                .font(.subheadline)
                            Spacer()
                            Text(String(format: "%.2f", viewModel.brightness))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        HStack {
                            Image(systemName: "sun.min")
                                .font(.caption)
                            Slider(value: $viewModel.brightness, in: -1.0...1.0)
                            Image(systemName: "sun.max")
                                .font(.caption)
                        }
                    }
                    
                    // Contrast
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Contrast")
                                .font(.subheadline)
                            Spacer()
                            Text(String(format: "%.2f", viewModel.contrast))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        HStack {
                            Image(systemName: "circle.lefthalf.filled")
                                .font(.caption)
                            Slider(value: $viewModel.contrast, in: 0.5...2.0)
                            Image(systemName: "circle.righthalf.filled")
                                .font(.caption)
                        }
                    }
                    
                    // Threshold
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Threshold")
                                .font(.subheadline)
                            Spacer()
                            Text("\(viewModel.threshold)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Slider(value: Binding(
                            get: { Double(viewModel.threshold) },
                            set: { viewModel.threshold = UInt8($0) }
                        ), in: 0...255, step: 1)
                    }
                    
                    // Apply button
                    Button {
                        Task {
                            try? await viewModel.processImage()
                        }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("Reprocess with New Settings")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.status.isActive)
                }
                .padding()
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .cornerRadius(12)
            }
        }
    }
}

// MARK: - Image Picker

struct ImagePicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    var sourceType: UIImagePickerController.SourceType
    @Environment(\.dismiss) private var dismiss
    
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ImagePicker
        
        init(_ parent: ImagePicker) {
            self.parent = parent
        }
        
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.image = image
            }
            parent.dismiss()
        }
        
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
