//
//  ImageProcessor.swift
//  BlutoothLan
//
//  Created by Erlan Kanybekov on 1/30/26.
//

import UIKit
import CoreImage
import CoreGraphics

// MARK: - Image Processing Error

enum ImageProcessingError: LocalizedError {
    case invalidImage
    case resizeFailed
    case ditheringFailed
    case conversionFailed
    
    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "Invalid image"
        case .resizeFailed:
            return "Failed to resize image"
        case .ditheringFailed:
            return "Failed to apply dithering"
        case .conversionFailed:
            return "Failed to convert to printer format"
        }
    }
}

// MARK: - Dithering Options

struct DitheringOptions {
    var threshold: UInt8 = 128
    var contrast: Double = 1.2 // Increased for better contrast
    var brightness: Double = 0.1 // Slightly brighter
    
    static let `default` = DitheringOptions()
    
    // Better quality for photos
    static let highQuality = DitheringOptions(
        threshold: 140,
        contrast: 1.3,
        brightness: 0.15
    )
}

// MARK: - Image Processor

final class ImageProcessor {
    
    // MARK: - Public Methods
    
    /// Process image for thermal printer printing
    /// - Parameters:
    ///   - image: Source image
    ///   - width: Target width in pixels (default 384 for 48mm printer)
    ///   - options: Dithering options
    /// - Returns: Tuple of (processed image for preview, ESC/POS data)
    static func processForPrinting(
        image: UIImage,
        width: Int = 384,
        options: DitheringOptions = .default
    ) throws -> (preview: UIImage, escposData: Data) {
        
        // Step 1: Resize image to printer width while maintaining aspect ratio
        guard let resizedImage = resize(image: image, targetWidth: width) else {
            throw ImageProcessingError.resizeFailed
        }
        
        // Step 2: Convert to grayscale
        guard let grayImage = convertToGrayscale(image: resizedImage) else {
            throw ImageProcessingError.conversionFailed
        }
        
        // Step 3: Apply contrast and brightness adjustments
        let adjustedImage = applyAdjustments(
            image: grayImage,
            brightness: options.brightness,
            contrast: options.contrast
        )
        
        // Step 4: Apply Floyd-Steinberg dithering
        guard let ditheredPixels = applyFloydSteinbergDithering(
            image: adjustedImage,
            threshold: options.threshold
        ) else {
            throw ImageProcessingError.ditheringFailed
        }
        
        // Step 5: Create preview image from dithered pixels
        guard let previewImage = createImageFromBoolArray(
            pixels: ditheredPixels,
            width: width
        ) else {
            throw ImageProcessingError.conversionFailed
        }
        
        // Step 6: Convert to ESC/POS raster bitmap format
        let escposData = convertToESCPOS(pixels: ditheredPixels, width: width)
        
        return (previewImage, escposData)
    }
    
    // MARK: - Image Resizing
    
    private static func resize(image: UIImage, targetWidth: Int) -> UIImage? {
        let aspectRatio = image.size.height / image.size.width
        let targetHeight = CGFloat(targetWidth) * aspectRatio
        let targetSize = CGSize(width: CGFloat(targetWidth), height: targetHeight)
        
        UIGraphicsBeginImageContextWithOptions(targetSize, false, 1.0)
        defer { UIGraphicsEndImageContext() }
        
        image.draw(in: CGRect(origin: .zero, size: targetSize))
        return UIGraphicsGetImageFromCurrentImageContext()
    }
    
    // MARK: - Grayscale Conversion
    
    private static func convertToGrayscale(image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        
        let width = cgImage.width
        let height = cgImage.height
        
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        guard let grayImage = context.makeImage() else { return nil }
        return UIImage(cgImage: grayImage)
    }
    
    // MARK: - Adjustments
    
    private static func applyAdjustments(
        image: UIImage,
        brightness: Double,
        contrast: Double
    ) -> UIImage {
        guard let ciImage = CIImage(image: image),
              brightness != 0.0 || contrast != 1.0 else {
            return image
        }
        
        var outputImage = ciImage
        
        // Apply brightness
        if brightness != 0.0 {
            if let filter = CIFilter(name: "CIColorControls") {
                filter.setValue(outputImage, forKey: kCIInputImageKey)
                filter.setValue(brightness, forKey: kCIInputBrightnessKey)
                if let output = filter.outputImage {
                    outputImage = output
                }
            }
        }
        
        // Apply contrast
        if contrast != 1.0 {
            if let filter = CIFilter(name: "CIColorControls") {
                filter.setValue(outputImage, forKey: kCIInputImageKey)
                filter.setValue(contrast, forKey: kCIInputContrastKey)
                if let output = filter.outputImage {
                    outputImage = output
                }
            }
        }
        
        let context = CIContext()
        if let cgImage = context.createCGImage(outputImage, from: outputImage.extent) {
            return UIImage(cgImage: cgImage)
        }
        
        return image
    }
    
    // MARK: - Floyd-Steinberg Dithering
    
    private static func applyFloydSteinbergDithering(
        image: UIImage,
        threshold: UInt8
    ) -> [[Bool]]? {
        guard let cgImage = image.cgImage else { return nil }
        
        let width = cgImage.width
        let height = cgImage.height
        
        // Extract pixel data
        guard let pixelData = cgImage.dataProvider?.data,
              let data = CFDataGetBytePtr(pixelData) else {
            return nil
        }
        
        let bytesPerRow = cgImage.bytesPerRow
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        
        // Create mutable grayscale array
        var grayscale = [[Int]](repeating: [Int](repeating: 0, count: width), count: height)
        
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let gray = Int(data[offset])
                grayscale[y][x] = gray
            }
        }
        
        // Apply Floyd-Steinberg dithering
        var result = [[Bool]](repeating: [Bool](repeating: false, count: width), count: height)
        
        for y in 0..<height {
            for x in 0..<width {
                let oldPixel = grayscale[y][x]
                let newPixel = oldPixel > Int(threshold) ? 255 : 0
                result[y][x] = newPixel == 0 // true = black, false = white
                
                let error = oldPixel - newPixel
                
                // Distribute error to neighboring pixels
                if x + 1 < width {
                    grayscale[y][x + 1] = clamp(grayscale[y][x + 1] + error * 7 / 16)
                }
                if y + 1 < height {
                    if x > 0 {
                        grayscale[y + 1][x - 1] = clamp(grayscale[y + 1][x - 1] + error * 3 / 16)
                    }
                    grayscale[y + 1][x] = clamp(grayscale[y + 1][x] + error * 5 / 16)
                    if x + 1 < width {
                        grayscale[y + 1][x + 1] = clamp(grayscale[y + 1][x + 1] + error * 1 / 16)
                    }
                }
            }
        }
        
        return result
    }
    
    private static func clamp(_ value: Int) -> Int {
        return max(0, min(255, value))
    }
    
    // MARK: - Preview Image Creation
    
    private static func createImageFromBoolArray(pixels: [[Bool]], width: Int) -> UIImage? {
        let height = pixels.count
        guard height > 0, pixels[0].count == width else { return nil }
        
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        
        var pixelData = [UInt8]()
        for row in pixels {
            for pixel in row {
                pixelData.append(pixel ? 0 : 255) // black or white
            }
        }
        
        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }
        
        guard let cgImage = context.makeImage() else { return nil }
        return UIImage(cgImage: cgImage)
    }
    
    // MARK: - X6h Format Conversion
    
    // X6h printer: 384 pixels width, 48 bytes per line, LSB first
    private static let x6hWidth = 384
    private static let x6hBytesPerLine = 48
    
    private static func convertToESCPOS(pixels: [[Bool]], width: Int) -> Data {
        let height = pixels.count
        
        var imageBytes = [UInt8]()
        
        // X6h expects raw scanlines without header
        // Each scanline is sent separately via 0xA2 command
        // Just output the raw bitmap data here
        
        // Convert each row to bytes
        // X6h uses LSB first: leftmost pixel is bit 0 of first byte
        for row in pixels {
            var rowBytes = [UInt8](repeating: 0, count: x6hBytesPerLine)
            
            for (x, pixel) in row.enumerated() {
                if x >= x6hWidth { break }
                if pixel { // black pixel = 1
                    let byteIndex = x / 8
                    let bitIndex = x % 8 // LSB first!
                    rowBytes[byteIndex] |= (1 << bitIndex)
                }
            }
            
            imageBytes.append(contentsOf: rowBytes)
        }
        
        return Data(imageBytes)
    }
    
    // MARK: - Quick Preview (without full processing)
    
    /// Quick preview of what the image will look like after dithering
    static func quickPreview(image: UIImage, width: Int = 384) -> UIImage? {
        guard let resized = resize(image: image, targetWidth: width),
              let gray = convertToGrayscale(image: resized),
              let dithered = applyFloydSteinbergDithering(image: gray, threshold: 128),
              let preview = createImageFromBoolArray(pixels: dithered, width: width) else {
            return nil
        }
        return preview
    }
}
