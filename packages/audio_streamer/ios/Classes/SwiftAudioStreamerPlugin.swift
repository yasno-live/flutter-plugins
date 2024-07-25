import AVFoundation
import Flutter
import UIKit

enum AudioConversionError: Error {
    case converterCreationFailed
    case conversionFailed
}

public class SwiftAudioStreamerPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    
    private var eventSink: FlutterEventSink?
    private let conversionQueue = DispatchQueue(label: "conversionQueue")
    
    var engine = AVAudioEngine()
    var audioData: [Float] = []
    var recording = false
    var preferredSampleRate: Int? = nil
    
    // Register plugin
    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = SwiftAudioStreamerPlugin()
        
        // Set flutter communication channel for emitting updates
        let eventChannel = FlutterEventChannel.init(
            name: "audio_streamer.eventChannel", binaryMessenger: registrar.messenger())
        // Set flutter communication channel for receiving method calls
        let methodChannel = FlutterMethodChannel.init(
            name: "audio_streamer.methodChannel", binaryMessenger: registrar.messenger())
        methodChannel.setMethodCallHandler { (call: FlutterMethodCall, result: FlutterResult) -> Void in
            if call.method == "getSampleRate" {
                // Return sample rate that is currently being used, may differ from requested
                result(Int(AVAudioSession.sharedInstance().sampleRate))
            }
        }
        eventChannel.setStreamHandler(instance)
        instance.setupNotifications()
    }
    
    private func setupNotifications() {
        // Get the default notification center instance.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(notification:)),
            name: AVAudioSession.interruptionNotification,
            object: nil)
    }
    
    @objc func handleInterruption(notification: Notification) {
        // If no eventSink to emit events to, do nothing (wait)
        if eventSink == nil {
            return
        }
        
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else {
            return
        }
        
        switch type {
        case .began: ()
        case .ended:
            // An interruption ended. Resume playback, if appropriate.
            
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else {
                return
            }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                startRecording(sampleRate: preferredSampleRate)
            }
            
        default:
            eventSink!(
                FlutterError(
                    code: "100", message: "Recording was interrupted",
                    details: "Another process interrupted recording."))
        }
    }
    
    // Handle stream emitting (Swift => Flutter)
    private func emitValues(values: [Float]) {
        
        // If no eventSink to emit events to, do nothing (wait)
        if eventSink == nil {
            return
        }
        // Emit values count event to Flutter
        eventSink!(values)
    }
    
    // Event Channel: On Stream Listen
    public func onListen(
        withArguments arguments: Any?,
        eventSink: @escaping FlutterEventSink
    ) -> FlutterError? {
        self.eventSink = eventSink
        if let args = arguments as? [String: Any] {
            preferredSampleRate = args["sampleRate"] as? Int
            startRecording(sampleRate: preferredSampleRate)
        } else {
            startRecording(sampleRate: nil)
        }
        return nil
    }
    
    // Event Channel: On Stream Cancelled
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        NotificationCenter.default.removeObserver(self)
        eventSink = nil
        engine.stop()
        return nil
    }
    
    func startRecording(sampleRate: Int?) {
        engine = AVAudioEngine()
        let nonNullSampleRate = sampleRate ?? 44100;
        let bufferSize = nonNullSampleRate * 2
        
        do {
            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            let recordingFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(nonNullSampleRate), channels: 1, interleaved: true)
            guard let formatConverter =  AVAudioConverter(from:inputFormat, to: recordingFormat!) else {
                throw AudioConversionError.converterCreationFailed
            }
            let bus = 0
            
            // We install a tap on the audio engine and specifying the buffer size and the input format.
            engine.inputNode.installTap(onBus: bus, bufferSize: AVAudioFrameCount(bufferSize), format: inputFormat) { (buffer, time) in
                
                self.conversionQueue.async {
                    
                    // An AVAudioConverter is used to convert the microphone input to the format required for the model.(pcm 16)
                    let pcmBuffer = AVAudioPCMBuffer(pcmFormat: recordingFormat!, frameCapacity: AVAudioFrameCount(recordingFormat!.sampleRate * 2.0))
                    var error: NSError? = nil
                    
                    let inputBlock: AVAudioConverterInputBlock = {inNumPackets, outStatus in
                        outStatus.pointee = AVAudioConverterInputStatus.haveData
                        return buffer
                    }
                    
                    formatConverter.convert(to: pcmBuffer!, error: &error, withInputFrom: inputBlock)
                    
                    if error != nil {
                        print(error!.localizedDescription)
                    }
                    
                    else if let channelData = pcmBuffer!.floatChannelData {
                        
                        let channelDataValue = channelData.pointee
                        let channelDataValueArray = stride(from: 0,
                                                           to: Int(pcmBuffer!.frameLength),
                                                           by: buffer.stride).map{ channelDataValue[$0] }
                        
                        self.emitValues(values: channelDataValueArray)
                    }
                    
                }
            }
            
            try engine.start()
        } catch {
            eventSink!(
                FlutterError(
                    code: "100", message: "Unable to start audio session", details: error.localizedDescription
                ))
        }
    }
}
