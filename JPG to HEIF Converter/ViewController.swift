//
//  ViewController.swift
//  JPG to HEIF Converter
//
//  Created by Sergey Armodin on 21.05.2018.
//  Copyright © 2018 Sergey Armodin. All rights reserved.
//

import Cocoa
import AVFoundation
import CoreFoundation


/// Converter state
///
/// - launched: just launched
/// - converting: converting right now
/// - complete: convertion complete
enum ConverterState: Int {
	case launched
	case converting
	case complete
}

typealias JSON = [String:Any]

class ViewController: NSViewController {
	
	// MARK: - Outlets
	
	/// Open files button
	@IBOutlet fileprivate weak var openFilesButton: NSButtonCell!
	
	/// Indicator
	@IBOutlet fileprivate weak var progressIndicator: NSProgressIndicator!
	
	/// Complete label
	@IBOutlet fileprivate weak var completeLabel: NSTextField!
	
	
	// MARK: - Properties
	
	/// Processed images number
	fileprivate var processedImages: Int = 0 {
		didSet {
			self.completeLabel.stringValue = "\(self.processedImages)" + NSLocalizedString("of", comment: "conjunction") + "\(self.totalImages)"
			
			self.progressIndicator.doubleValue = Double(self.processedImages)
		}
	}
	
	/// Total selected images number
	fileprivate var totalImages: Int = 0 {
		didSet {
			self.progressIndicator.maxValue = Double(totalImages)
		}
	}
	
	/// State
	fileprivate var converterState: ConverterState = .launched {
		didSet {
			switch converterState {
			case .launched:
				self.progressIndicator.isHidden = true
				self.completeLabel.isHidden = true
			case .converting:
				self.openFilesButton.isEnabled = false
				self.progressIndicator.isHidden = false
				self.completeLabel.isHidden = false
			case .complete:
				self.openFilesButton.isEnabled = true
				self.progressIndicator.isHidden = false
				self.completeLabel.isHidden = false
				
				self.completeLabel.stringValue = NSLocalizedString("Converting complete", comment: "Label")
			}
		}
	}
	
	
	override func viewDidLoad() {
		super.viewDidLoad()
		
		if #available(macOS 10.13, *) {
			self.openFilesButton.isEnabled = true
		} else {
			self.openFilesButton.isEnabled = false
		}
		
		self.converterState = .launched
	}

	override var representedObject: Any? {
		didSet {
		// Update the view, if already loaded.
		}
	}

	
}


// MARK: - Actions
extension ViewController {
	
	/// Open files button touched
	///
	/// - Parameter sender: NSButton
	@IBAction func openFilesButtonTouched(_ sender: Any) {
		
		self.totalImages = 0
		self.processedImages = 0
		
		let panel = NSOpenPanel.init()
		panel.allowsMultipleSelection = true
		panel.canChooseDirectories = true
		panel.canChooseFiles = true
		panel.isFloatingPanel = true
		panel.allowedFileTypes = ["jpg", "jpeg", "png", "xcassets", "imageset"]
		
		panel.beginSheetModal(for: self.view.window!) { [weak self] (result) in
			guard let `self` = self else { return }
			
			guard result == .OK else { return }
			guard panel.urls.isEmpty == false else { return }
			
            self.processItems(panel.urls)
		}
	}
	
    func processItems(_ urls: [URL]) {
        converterState = .converting
        totalImages = 0
        processedImages = 0
        
        let group = DispatchGroup()
        let serialQueue = DispatchQueue(label: "me.spaceinbox.jpgtoheifconverter")
        
        for url in urls {
            
            switch FileType(url) {
            case .image:        convertImage(url, group: group, queue: serialQueue)
            case .json:         updateContentsFile(url, group: group, queue: serialQueue)
            case .directory:    processFolder(url, group: group, queue: serialQueue)
            case .invalid:      continue
            }

        }
        
        group.notify(queue: .main, execute: { [weak self] in
            guard let `self` = self else { return }
            self.converterState = .complete
        })
        
    }
    
    func processFolder(_ url: URL, group: DispatchGroup, queue: DispatchQueue) {
        guard case .directory = FileType(url) else { return }
        
        let subPaths = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey])
        
        while let path = subPaths?.nextObject() as? URL {

            switch FileType(path) {
            case .image:
                convertImage(path, group: group, queue: queue)
                continue
            case .json:
                updateContentsFile(path, group: group, queue: queue)
            case .directory, .invalid:
                /* subdirectories' contents are also part of the enumerated sequence, so the directories themselves can be ignored */
                continue
            }
            
        }
        
    }
    
    func convertImage(_ imageUrl: URL, group: DispatchGroup, queue: DispatchQueue) {
        
        totalImages += 1
        
        group.enter()
        queue.async { [weak self] in
            
            guard let `self` = self else { return }
            
            guard case .image = FileType(imageUrl) else { return }
            guard let source = CGImageSourceCreateWithURL(imageUrl as CFURL, nil) else { return }
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
            guard let imageMetadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return }
            
            let pathWithName = imageUrl.deletingPathExtension()
            guard let outputUrl = URL(string: pathWithName.absoluteString + ".heic") else { return }
            
            guard let destination = CGImageDestinationCreateWithURL(
                outputUrl as CFURL,
                AVFileType.heic as CFString,
                1, nil
                ) else {
                    fatalError("unable to create CGImageDestination")
            }
            
            CGImageDestinationAddImageAndMetadata(destination, image, imageMetadata, nil)
            CGImageDestinationFinalize(destination)
            
            DispatchQueue.main.async {
                self.processedImages += 1
            }
            
            group.leave()
        }
        
    }
    
}

extension ViewController {
    
    func updateContentsFile(_ url: URL, group: DispatchGroup, queue: DispatchQueue) {
        guard case .json = FileType(url) else { return }
        
        group.enter()
        queue.async { [weak self] in
            
            do {
                try self?.updateJSONContents(url)
            } catch let error {
                print(error)
            }
            
            group.leave()
        }
        
    }
    
    private func updateJSONContents(_ url: URL) throws {
        guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url), options: .mutableLeaves) as? JSON else { return }
        let processed = try JSONSerialization.data(withJSONObject: processJSON(json), options: .prettyPrinted)
        try processed.write(to: url)
        
    }
    
    private func processJSON(_ json: JSON) -> JSON {
        var json = json
        for (k, v) in json {
            if k == "filename", let value = v as? String {
                for type in FileType.allowedImageTypes {
                    json[k] = value.replacingOccurrences(of: ".\(type)", with: ".heic")
                }
            } else if let value = v as? JSON {
                json[k] = processJSON(value)
            } else if let values = v as? [JSON] {
                json[k] = values.compactMap({ return processJSON($0) })
            }
        }
        
        return json
    }
    
}
