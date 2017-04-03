//
//  AudioPlayer.swift
//  KJMusic
//
//  Created by Kim on 2017/3/25.
//  Copyright © 2017年 Kim. All rights reserved.
//

import UIKit
import AVFoundation

class AudioPlayer: NSObject {

    static let bitRateEstimationMaxPackets = 5000
    static let audioQueueBufferNums = 500 // 缓冲区队列的数量。3 - 24
    static let audioQueueMaxPacketDescs = 512 // 最大的帧描述数
    static let audioQueueDefaultBufferSize = 2048

	var url: URL
    lazy var selfPointer: UnsafeMutableRawPointer = {
        return unsafeBitCast(self, to: UnsafeMutableRawPointer.self)
    }()
    lazy var playerThread: Thread = {
        return Thread(target: self, selector: #selector(process), object: nil)
    }()
    var session: URLSession?
    var status: OSStatus = noErr
    var audioFileStream: AudioFileStreamID?

    var bitRate: UInt32 = 0
    var fileLength: UInt32 {
        return audioDataByteCount + audioDataOffset
    }
    var audioDataOffset: UInt32 = 0
    var audioDataByteCount: UInt32 = 0
    lazy var audioStreamBasicDescription = AudioStreamBasicDescription()
    var audioQueue: AudioQueueRef? // 播放队列
    var processedPacketsCount: UInt32 = 0	// 要处理的帧数
    var processedPacketsSizeTotal: UInt32 = 0 // 要处理的帧的大小
    var bytesFilled: Int64 = 0
    var packetsFilled: UInt32 = 0
    var packetBufferSize: UInt32 = 0 // 每个缓冲区的size
    var fillBufferIndex = 0
    var audioQueueBuffer = [AudioQueueBufferRef?](repeating: nil, count: audioQueueBufferNums)
    var packetDescription = [AudioStreamPacketDescription](repeating: AudioStreamPacketDescription(), count: audioQueueMaxPacketDescs) // 音频帧描述
    var inuseBuffer = [Bool](repeating: false, count: audioQueueBufferNums)
    var buffersUsed = 0
    var sampleRate: Double = 0
    var packetDuration: Double = 0 // 音频帧的播放时长 = 每帧的字节数 / 采样率

    var queueBuffersMutex: pthread_mutex_t = pthread_mutex_t()
    var queueBufferReadyCondition: pthread_cond_t = pthread_cond_t()
    var stream: Unmanaged<CFReadStream>?

    /// 初始化播放器
    ///
    /// - Parameter url: 音频文件的地址
    init(_ url: URL) {
        self.url = url

    }

    func start() {
		playerThread.start()
    }

    func process() {
        // 避免多个线程访问引起问题
//        RunLoop.current.run(mode: .defaultRunLoopMode, before: Date.init(timeIntervalSinceNow: <#T##TimeInterval#>))
        synchronized(self) {
            openReadStream()
            pthread_mutex_init(&queueBuffersMutex, nil)
            pthread_cond_init(&queueBufferReadyCondition, nil)


        }
        var isRunning = true
        repeat {
            isRunning = RunLoop.current.run(mode: .defaultRunLoopMode, before: Date.init(timeIntervalSinceNow: 0.1))
        } while isRunning
    }
}

// MARK: - Stream
extension AudioPlayer {
    func openReadStream() {
		synchronized(self) { 
            // 获取音频数据
//			session = URLSession(configuration: .default, delegate: self, delegateQueue: OperationQueue.current)
//            let task = session?.dataTask(with: self.url)
//            task?.resume()
			let urlRequest = CFHTTPMessageCreateRequest(kCFAllocatorDefault, "GET" as CFString, self.url as CFURL, kCFHTTPVersion1_1).takeRetainedValue()
			stream = CFReadStreamCreateForHTTPRequest(kCFAllocatorDefault, urlRequest)
            let inputStream = stream!.takeRetainedValue()
            var context = CFStreamClientContext(version: 0, info: selfPointer, retain: nil, release: nil, copyDescription: nil)
            if CFReadStreamSetClient(inputStream, CFStreamEventType.hasBytesAvailable.rawValue, kj_CFReadStreamClientCallBack, &context) {
				CFReadStreamScheduleWithRunLoop(inputStream, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes)
            }
			CFReadStreamOpen(inputStream)


//            let s = stream!.takeRetainedValue()
//
//            if !CFReadStreamSetProperty(s, CFStreamPropertyKey(rawValue: kCFStreamPropertyHTTPShouldAutoredirect), kCFBooleanTrue) {
//                 print("Set Error")
//            }
//
//            let proxySettings = CFNetworkCopySystemProxySettings()?.takeRetainedValue()
//            CFReadStreamSetProperty(s, CFStreamPropertyKey(rawValue: kCFStreamPropertyHTTPProxy), proxySettings)
//
//            if !CFReadStreamOpen(s) {
//                print("Error")
//            }
//            var context = CFStreamClientContext(version: 0, info: selfPointer, retain: nil, release: nil, copyDescription: nil)
//            if !CFReadStreamSetClient(s, CFStreamEventType.hasBytesAvailable.rawValue | CFStreamEventType.endEncountered.rawValue | CFStreamEventType.errorOccurred.rawValue, kj_CFReadStreamClientCallBack, &context) {
//				print("Error2")
//            }
//            CFReadStreamScheduleWithRunLoop(s, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes)
        }
    }
}

func kj_CFReadStreamClientCallBack(aStream: CFReadStream?, eventType: CFStreamEventType, inClientInfo: UnsafeMutableRawPointer?) {
    let this = Unmanaged<AudioPlayer>.fromOpaque(inClientInfo!).takeUnretainedValue()
    switch eventType {
    case CFStreamEventType.hasBytesAvailable:
        if this.audioFileStream == nil {
            this.status = AudioFileStreamOpen(inClientInfo, kj_AudioFileStreamPropertyListenerProc, kj_AudioFileStreamPacketProc, this.hint(for: this.url.pathExtension), &this.audioFileStream)
            assert(this.status == noErr)
        }

        this.synchronized(this, closure: { 
            if !CFReadStreamHasBytesAvailable(aStream!) {
				return
            }

			var bytes = [UInt8](repeating: 0, count: AudioPlayer.audioQueueDefaultBufferSize)
            let length = CFReadStreamRead(aStream!, &bytes, AudioPlayer.audioQueueDefaultBufferSize)
            if length == -1 || length == 0 {
				print("Read Error")
            }
			let status = AudioFileStreamParseBytes(this.audioFileStream!, UInt32(length), &bytes, AudioFileStreamParseFlags(rawValue: 0))
			print("P \(status)")

        })

//        var data = data
//
//        let _ = data.withUnsafeBytes { (ptr: UnsafePointer<UInt8>) in
//            let rawPtr = UnsafeRawPointer(ptr)
//            let status = AudioFileStreamParseBytes(audioFileStream!, UInt32(data.count), rawPtr, AudioFileStreamParseFlags(rawValue: 0))
//            assert(status == noErr)
//        }
    default:
        break
    }
}

// MARK: - AudioFileStream Callback
// 获取音频文件的相关信息
func kj_AudioFileStreamPropertyListenerProc(clientData: UnsafeMutableRawPointer, audioFileStream: AudioFileStreamID, propertyID: AudioFilePropertyID, ioFlag: UnsafeMutablePointer<AudioFileStreamPropertyFlags>) {
    // FIXME
    print("AudioStream \(#line) \(Thread.current)")
    let this = Unmanaged<AudioPlayer>.fromOpaque(clientData).takeUnretainedValue()
    this.synchronized(this) {
        // 根据不同的propertyID获取相关的信息

        // 获取对应数据的大小
        var dataSize: UInt32 = 0
        var writable: DarwinBoolean = false
        this.status = AudioFileStreamGetPropertyInfo(audioFileStream, propertyID, &dataSize, &writable)
        assert(this.status == noErr)
        if propertyID == kAudioFileStreamProperty_BitRate {
            // 音频文件的码率，可以用于计算时长
            this.status = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_BitRate, &dataSize, &this.bitRate)
            assert(this.status == noErr)

        } else if propertyID == kAudioFileStreamProperty_DataOffset {
            // 整个音频数据在音频文件中的偏移量
            this.status = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_DataOffset, &dataSize, &this.audioDataOffset)
            assert(this.status == noErr)
        } else if propertyID == kAudioFileStreamProperty_AudioDataByteCount {
            // 音频数据总量
            this.status = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_AudioDataByteCount, &dataSize, &this.audioDataByteCount)
            assert(this.status == noErr)
        } else if propertyID == kAudioFileStreamProperty_DataFormat {
            // 音频文件结构信息
            this.status = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_DataFormat, &dataSize, &this.audioStreamBasicDescription)
            assert(this.status == noErr)
        } else if propertyID == kAudioFileStreamProperty_FormatList {
            // 也是获取音频文件的结构信息，但是是作用于AAC SBR等多文件类型的音频格式

            var formatList = [AudioFormatListItem](repeating: AudioFormatListItem(), count: Int(dataSize))
            this.status = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_FormatList, &dataSize, &formatList)
            for i in 0..<Int(dataSize) {
                let pasbd = formatList[i].mASBD
                if pasbd.mFormatID == kAudioFormatMPEG4AAC_HE || pasbd.mFormatID == kAudioFormatMPEG4AAC_HE_V2 {
                    // 获取HE-AAC
                    this.audioStreamBasicDescription = pasbd
                    break
                }
            }
        }
    }
}

// 分离音频帧
func kj_AudioFileStreamPacketProc(clientData: UnsafeMutableRawPointer, numberBytes: UInt32, numberPackets: UInt32, inputData: UnsafeRawPointer, packetDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>) {
    guard numberBytes != 0 && numberPackets != 0 else {
        return
    }

    let this = Unmanaged<AudioPlayer>.fromOpaque(clientData).takeUnretainedValue()
    this.synchronized(this) { 
        if this.audioQueue == nil {
            this.createQueue()
        }
    }


    // 一般情况下，VBR的AudioStreamPacketDescription非空，可是从某位大大的blog中看到，CBR也有可能非空，不能单纯靠这个来判定，所以就根据Apple的文档来判定VBR和CBR
    // 文档地址： https://developer.apple.com/library/content/documentation/MusicAudio/Conceptual/AudioQueueProgrammingGuide/AQPlayback/PlayingAudio.html
    if this.audioStreamBasicDescription.mBytesPerPacket == 0 || this.audioStreamBasicDescription.mFramesPerPacket == 0 {
        // VBR
        for i in 0..<Int(numberPackets) {
            let packetOffset = packetDescriptions[i].mStartOffset
            let packetSize = packetDescriptions[i].mDataByteSize

            if Int(this.processedPacketsCount) < AudioPlayer.bitRateEstimationMaxPackets {
                this.processedPacketsCount += 1
                this.processedPacketsSizeTotal += packetSize
            }

			var bufSpaceRemaining: UInt32 = 0 // 当前的缓冲剩余的空间
			this.synchronized(this, closure: { 
				bufSpaceRemaining = this.packetBufferSize - UInt32(this.bytesFilled) // 帧的size - 已经填充的字节数
            })


            if bufSpaceRemaining < packetSize {
                this.enqueueBuffer() // 如果剩下的空间不足以存放当前音频帧，就进入播放队列等待播放
            }

            this.synchronized(this, closure: { 
                if UInt32(this.bytesFilled) + packetSize > this.packetBufferSize {
                    return
                }

                // 将当前数据复制到缓冲队列中
                guard let audioQueueBuffer = this.audioQueueBuffer[this.fillBufferIndex] else {
                    return
                }
                print("AudioStream \(#line) \(Thread.current)")
                memcpy(audioQueueBuffer.pointee.mAudioData.advanced(by: Int(this.bytesFilled)), inputData.advanced(by: Int(packetOffset)), Int(packetSize))
                this.packetDescription[Int(this.packetsFilled)] = packetDescriptions[i]
                this.packetDescription[Int(this.packetsFilled)].mStartOffset = this.bytesFilled
                this.bytesFilled += Int64(packetSize)
                this.packetsFilled += 1
            })

            if AudioPlayer.audioQueueMaxPacketDescs - Int(this.packetsFilled) == 0 {
                // 结束
                this.enqueueBuffer()
            }
        }
    } else {
        // CBR
        var offset = 0
        var numberBytes = numberBytes
        while numberBytes != 0 {
            let bufSpaceRemaining = this.packetBufferSize - UInt32(this.bytesFilled)
            if bufSpaceRemaining < numberBytes {
                this.enqueueBuffer()

            }

            this.synchronized(this, closure: {
                let bufSpaceRemaining = this.packetBufferSize - UInt32(this.bytesFilled)
                let copySize = bufSpaceRemaining < numberBytes ? bufSpaceRemaining : numberBytes
                if UInt32(this.bytesFilled) > this.packetBufferSize {
                    return
                }

                // 将当前数据复制到缓冲队列中
                guard let audioQueueBuffer = this.audioQueueBuffer[this.fillBufferIndex] else {
                    return
                }
                memcpy(audioQueueBuffer.pointee.mAudioData.advanced(by: Int(this.bytesFilled)), inputData.advanced(by: Int(offset)), Int(copySize))
                this.bytesFilled += Int64(copySize)
                this.packetsFilled = 0
                numberBytes -= copySize
				offset += Int(copySize)
            })
        }
    }
}

func kj_AudioQueueOutputCallback(clientData: UnsafeMutableRawPointer?, AQ: AudioQueueRef, buffer: AudioQueueBufferRef) {
    print("AudioQUeue \(#line) \(Thread.current)")
    let this = Unmanaged<AudioPlayer>.fromOpaque(UnsafeRawPointer(clientData)!).takeUnretainedValue()
    var bufferIndex = -1
    for (index, buf) in this.audioQueueBuffer.enumerated() {
        if buf == buffer {
			bufferIndex = index
            break
        }
    }

    if bufferIndex == -1 {
        return
    }
    pthread_mutex_lock(&this.queueBuffersMutex)
    this.inuseBuffer[bufferIndex] = false
    this.buffersUsed -= 1
    pthread_cond_signal(&this.queueBufferReadyCondition)
    pthread_mutex_unlock(&this.queueBuffersMutex)
}

func kj_PropertyChange(AQ: AudioQueueRef, propertyID: AudioQueuePropertyID) {
    kj_AudioQueueRunningListener(clientData: nil, AQ: AQ, propertyID: propertyID)
}


func kj_AudioQueueRunningListener(clientData: UnsafeMutableRawPointer?, AQ: AudioQueueRef, propertyID: AudioQueuePropertyID) {

    let player = Unmanaged<AudioPlayer>.fromOpaque(clientData!).takeUnretainedValue()

}



// MARK: - AudioQueueBuffer
extension AudioPlayer {
    func enqueueBuffer() {
		synchronized(self) { 
            inuseBuffer[fillBufferIndex] = true
            buffersUsed += 1

            guard let fillBuffer = audioQueueBuffer[fillBufferIndex],
            	let audioQueue = audioQueue else {
                return
            }
			fillBuffer.pointee.mAudioDataByteSize = UInt32(bytesFilled)

            if packetsFilled != 0 {
                status = AudioQueueEnqueueBuffer(audioQueue, fillBuffer, packetsFilled, packetDescription)
            } else {
				status = AudioQueueEnqueueBuffer(audioQueue, fillBuffer, 0, nil)
            }
			assert(status == noErr)
            if buffersUsed == AudioPlayer.audioQueueBufferNums - 1 {
				status = AudioQueueStart(audioQueue, nil)
            }

            assert(status == noErr)
            fillBufferIndex += 1
            if fillBufferIndex >= AudioPlayer.audioQueueBufferNums {
                fillBufferIndex = 0
            }
            bytesFilled = 0
            packetsFilled = 0
        }

        pthread_mutex_lock(&queueBuffersMutex)
        while inuseBuffer[fillBufferIndex] {
            pthread_cond_wait(&queueBufferReadyCondition, &queueBuffersMutex)
        }
        pthread_mutex_unlock(&queueBuffersMutex)
    }

    func createQueue() {
        guard let audioFileStream = self.audioFileStream else {
            return
        }

		sampleRate = audioStreamBasicDescription.mSampleRate
		packetDuration = Double(audioStreamBasicDescription.mBytesPerPacket) / self.sampleRate
        status = AudioQueueNewOutput(&audioStreamBasicDescription, kj_AudioQueueOutputCallback, selfPointer, nil, nil, 0, &audioQueue)
        assert(status == noErr)
        status = AudioQueueAddPropertyListener(audioQueue!, kAudioQueueProperty_IsRunning, kj_AudioQueueRunningListener, selfPointer)
        assert(status == noErr)

        var dataSize: UInt32 = 0
        status = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_PacketSizeUpperBound, &dataSize, &packetBufferSize)
        if status != noErr || packetBufferSize == 0 {
			status = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_MaximumPacketSize, &dataSize, &packetBufferSize)
            if status != noErr || packetBufferSize == 0 {
                packetBufferSize = 2048
            }
        }

        for i in 0..<AudioPlayer.audioQueueBufferNums {
            status = AudioQueueAllocateBuffer(audioQueue!, packetBufferSize, &audioQueueBuffer[i])
            assert(status == noErr)
        }

        // 对于一些压缩的音频文件，会使用到包含音频元数据的结构，即 Magic Cookie Data.在开始播放前，需要获取这部分数据，并添加到播放队列中
        var cookieSize: UInt32 = 0
        var writable: DarwinBoolean = false
        status = AudioFileStreamGetPropertyInfo(audioFileStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &writable)
        if status != noErr {
            return
        }

        let cookieData = UnsafeMutablePointer<CChar>.allocate(capacity: Int(cookieSize))
        status = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, cookieData)
        assert(status == noErr)
        status = AudioQueueSetProperty(audioQueue!, kAudioQueueProperty_MagicCookie, cookieData, cookieSize)
        assert(status == noErr)
		cookieData.deallocate(capacity: Int(cookieSize))
    }
}

// MARK: - URLSessionDelegate
extension AudioPlayer: URLSessionDataDelegate {

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {

        if audioFileStream == nil {
			status = AudioFileStreamOpen(selfPointer, kj_AudioFileStreamPropertyListenerProc, kj_AudioFileStreamPacketProc, hint(for: self.url.pathExtension), &audioFileStream)
            assert(status == noErr)
        }

        var data = data

        let _ = data.withUnsafeBytes { (ptr: UnsafePointer<UInt8>) in
            let rawPtr = UnsafeRawPointer(ptr)
            let status = AudioFileStreamParseBytes(audioFileStream!, UInt32(data.count), rawPtr, AudioFileStreamParseFlags(rawValue: 0))
            assert(status == noErr)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        print("Error \(error)")
    }
}

// MARK: - Helper
extension AudioPlayer {
    func synchronized(_ lock: AnyObject, closure: () -> ()) {
        objc_sync_enter(lock)
        closure()
        objc_sync_exit(lock)
    }

    func hint(for fileType: String) -> AudioFileTypeID {
        switch fileType {
        case "mp3":
            return kAudioFileMP3Type
        case "wav":
            return kAudioFileWAVEType
        case "aifc":
            return kAudioFileAIFCType
        case "aiff":
            return kAudioFileAIFFType
        case "m4a":
            return kAudioFileM4AType
        case "mp4":
            return kAudioFileMPEG4Type
        case "caf":
            return kAudioFileCAFType
        case "aac":
            return kAudioFileAAC_ADTSType
        default:
            return kAudioFileAAC_ADTSType
        }
    }
}
