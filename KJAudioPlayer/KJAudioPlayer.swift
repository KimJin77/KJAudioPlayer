//
//  KJAudioPlayer.swift
//  KJMusic
//
//  Created by Kim on 2017/4/3.
//  Copyright © 2017年 Kim. All rights reserved.
//

import UIKit
import AVFoundation

class KJAudioPlayer: NSObject {
    // 音频文件相关数据
    struct AudioInfo {
        var audioFileStream: AudioFileStreamID?
        var bitRate: UInt32 = 0					// 比特率
        var dataOffset: UInt64 = 0				// 音频数据在流数据中的偏移量（起点）
        var byteCount: UInt64 = 0				// 总字节数
    	var audioStreamBasicDescription = AudioStreamBasicDescription()
        var sampleRate: Float64 {				// 采样率
            return audioStreamBasicDescription.mSampleRate
        }
        var packetDuration: Double {
            return Double(audioStreamBasicDescription.mBytesPerPacket) / Double(sampleRate)
        }
        var fileLength: Int = 0 				// 总文件大小
		var audioDuration: (Int, Int) {		// 音频时长
            guard dataOffset != 0, bitRate != 0 else {
                return (0, 0)
            }
            let seconds = (fileLength - Int(dataOffset)) * 8 / Int(bitRate)
            let minute: Int = seconds / 60
            let second: Int = seconds % 60
            return (minute, second)
        }
    }

    // 播放、缓冲区
    struct AudioQueueBuffers {
		static let bufferDefaultSize = 2048
        static let bitRateEstimationMaxPackets = 5000
        static let audioQueueBufferNums = 15 // 缓冲区队列的数量。3 - 24
        static let audioQueueMaxPacketDescs = 512

        var audioQueue: AudioQueueRef?	// 播放队列
        var audioQueueBuffer = [AudioQueueBufferRef?](repeating: nil, count: audioQueueBufferNums)
        var packetDescription = [AudioStreamPacketDescription](repeating: AudioStreamPacketDescription(), count: audioQueueMaxPacketDescs)
        var processedPacketsCount: UInt32 = 0	// packet数量
        var processedPacketsSizeTotal: UInt32 = 0	// 所有packet的大小
        var packetBufferSize: UInt32 = 0		// 缓冲区的大小
        var bytesFilled: Int64 = 0			// 当前缓冲区已填充的byte数
        var fillBufferIndex: Int = 0			// 当前填充的缓冲区的索引
        var packetsFilled: UInt32 = 0			// 缓冲区已填充的packet数目
        var inuseBuffer = [Bool](repeating: false, count: audioQueueBufferNums)	// 标注当前的缓冲是否等待播放
        var bufferUsed = 0		// 使用的buffer数
    }
    
    enum PlayerNotification: String {
        case fetchDuration
    }

	var url: URL		// 音频文件URL
    lazy var internalThread: Thread = {
        return Thread.init(target: self, selector: #selector(startInternal), object: nil)
    }()	// 创建线程用于数据获取，解析
    lazy var pointee: UnsafeMutableRawPointer = {
        return unsafeBitCast(self, to: UnsafeMutableRawPointer.self)
    }()	// 指针
    var inputStream: Unmanaged<CFReadStream>?	// 输入流
    var httpHeader: CFDictionary? = nil
    var queueBuffersMutex = pthread_mutex_t()	// 开启线程锁
    var queueBufferReadyCondition = pthread_cond_t()	// 解锁条件

    var status: OSStatus = noErr
	var audioInfo = AudioInfo()
    var audioQueueBuffers = AudioQueueBuffers()
	var discontinous = false

    var duration: (String, String) {
        let minute = audioInfo.audioDuration.0 < 10 ? "0" + String(audioInfo.audioDuration.0) : String(audioInfo.audioDuration.0)
        let second = audioInfo.audioDuration.1 < 10 ? "0" + String(audioInfo.audioDuration.1) : String(audioInfo.audioDuration.1)
        return (minute, second)
    }

    /// 初始化方法
    ///
    /// - Parameter url: 音频文件的URL地址
    init(_ url: URL) {
		self.url = url
        super.init()
    }

    func start() {
		internalThread.start()
    }

    /// 开始读取流数据
    @objc private func startInternal () {
		openReadStream()
		pthread_mutex_init(&queueBuffersMutex, nil)
        pthread_cond_init(&queueBufferReadyCondition, nil)

        var isRunning = true
        repeat {
            isRunning = RunLoop.current.run(mode: .defaultRunLoopMode, before: Date.init(timeIntervalSinceNow: 0.1))
        } while isRunning
    }
}

// MARK: - Stream

extension KJAudioPlayer {
    func openReadStream() {
		synchronized(self) {
            // 创建Request
            let urlRequest = CFHTTPMessageCreateRequest(kCFAllocatorDefault, "GET" as CFString, self.url as CFURL, kCFHTTPVersion1_1)
            self.inputStream = CFReadStreamCreateForHTTPRequest(kCFAllocatorDefault, urlRequest.takeUnretainedValue())
            urlRequest.release()
            let inputStream = self.inputStream!.takeRetainedValue()

            // 允许重定向
            if !CFReadStreamSetProperty(inputStream, CFStreamPropertyKey(rawValue: kCFStreamPropertyHTTPShouldAutoredirect), kCFBooleanTrue) {
				print("\(#line): 重定向出错")
            }

            // Proxy
            if let proxySettings = CFNetworkCopySystemProxySettings() {
				CFReadStreamSetProperty(inputStream, CFStreamPropertyKey(rawValue: kCFStreamPropertyHTTPProxy), proxySettings.takeUnretainedValue())
                proxySettings.release()
            }

            // SSL
            if self.url.scheme == "https" {
                let sslSettings: NSDictionary = [kCFStreamSSLLevel: kCFStreamSocketSecurityLevelNegotiatedSSL]
                CFReadStreamSetProperty(inputStream, CFStreamPropertyKey(rawValue: kCFStreamPropertySSLSettings), sslSettings as CFDictionary)
            }

            // 回调函数
            var context = CFStreamClientContext(version: 0, info: self.pointee, retain: nil, release: nil, copyDescription: nil)
            if !CFReadStreamSetClient(inputStream, CFStreamEventType.hasBytesAvailable.rawValue | CFStreamEventType.endEncountered.rawValue | CFStreamEventType.errorOccurred.rawValue, { (aStream, eventType, clientInfo) in
                guard let stream = aStream, let clientInfo = clientInfo else {
                    return
                }

                let client = Unmanaged<KJAudioPlayer>.fromOpaque(clientInfo).takeUnretainedValue()
                client.handleEvent(eventType, of: stream)
            }, &context) {
				print("\(#line): Client 设置出错")
                return
            }
            CFReadStreamScheduleWithRunLoop(inputStream, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes)

            // 开始读取数据
            if !CFReadStreamOpen(inputStream) {
                print("\(#line): 读取数据出错")
            }
        }
    }

    /// CFReadStream的回调函数，根据事件的类型进行处理
    ///
    /// - Parameters:
    ///   - eventType: 事件类型
    ///   - stream: 流数据
    func handleEvent(_ eventType: CFStreamEventType, of stream: CFReadStream) {
        switch eventType {
		case CFStreamEventType.hasBytesAvailable:
            if httpHeader == nil {
				let message: CFHTTPMessage = CFReadStreamCopyProperty(stream, CFStreamPropertyKey(rawValue: kCFStreamPropertyHTTPResponseHeader)) as! CFHTTPMessage
                httpHeader = CFHTTPMessageCopyAllHeaderFields(message)?.takeUnretainedValue()
                if let httpHeader = httpHeader as? [String: AnyObject] {
					audioInfo.fileLength = Int(httpHeader["Content-Length"] as! String)!
                }
            }

            if audioInfo.audioFileStream == nil {
                // 初始化文件流
				status = AudioFileStreamOpen(pointee, { (clientData, audioFileStream, propertyID, ioFlag) in
					let client = Unmanaged<KJAudioPlayer>.fromOpaque(clientData).takeUnretainedValue()
                    client.listenProperty(by: propertyID, of: audioFileStream, with: ioFlag)
                }, { (clientData, numberBytes, numbetPackets, inputData, packetDescriptions) in
					let client = Unmanaged<KJAudioPlayer>.fromOpaque(clientData).takeUnretainedValue()
                    client.handleAudioData(with: numberBytes, numberPackets: numbetPackets, inputData: inputData, packetDescriptions: packetDescriptions)
                }, hint(of: self.url), &audioInfo.audioFileStream)
                if status != noErr {
                    print("\(#line): 开启音频文件失败")
                }
            }

            synchronized(self) {
                if !CFReadStreamHasBytesAvailable(stream) {
                    return
                }

                var bytes = [UInt8](repeating: 0, count: KJAudioPlayer.AudioQueueBuffers.bufferDefaultSize)
                let length = CFReadStreamRead(stream, &bytes, KJAudioPlayer.AudioQueueBuffers.bufferDefaultSize) // 字节数
                if length == -1 {
                    print("\(#line): 读取网络数据出错")
                } else if length == 0 {
                    // 已经到达末尾
                    return
                }

                if self.discontinous {
					self.status = AudioFileStreamParseBytes(self.audioInfo.audioFileStream!, UInt32(length), &bytes, AudioFileStreamParseFlags.discontinuity)
                    if self.status != noErr {
                        print("\(#line): 流数据解析出错")
                    }
                } else {
                    self.status = AudioFileStreamParseBytes(self.audioInfo.audioFileStream!, UInt32(length), &bytes, AudioFileStreamParseFlags(rawValue: 0))
                    if self.status != noErr {
                        print("\(#line): 流数据解析出错")
                    }
                }

            }
        default: break
        }
    }
}

// MARK: - Stream Callback
extension KJAudioPlayer {

    /// 监听音频属性
    ///
    /// - Parameters:
    ///   - propertyID: 属性对应的ID
    ///   - aStream: 音频流
    ///   - ioFlag: io标志位
    func listenProperty(by propertyID: AudioFilePropertyID, of aStream: AudioFileStreamID, with ioFlag: UnsafeMutablePointer<AudioFileStreamPropertyFlags>) {
        synchronized(self) {
            // 获取属性数据的size
            var dataSize: UInt32 = 0
            var writable: DarwinBoolean = false
            self.status = AudioFileStreamGetPropertyInfo(aStream, propertyID, &dataSize, &writable)
            if self.status != noErr {
                print("\(#line)：获取属性数据大小出错")
                return
            }

            switch propertyID {
            case kAudioFileStreamProperty_BitRate:	// 比特率
                self.status = AudioFileStreamGetProperty(aStream, kAudioFileStreamProperty_BitRate, &dataSize, &self.audioInfo.bitRate)
                if self.status != noErr {
                    print("\(#line)：获取比特率出错")
                    return
                }
            case kAudioFileStreamProperty_DataOffset:	// 在流数据中，音频数据的起点的偏移量
                self.status = AudioFileStreamGetProperty(aStream, kAudioFileStreamProperty_DataOffset, &dataSize, &self.audioInfo.dataOffset)
                if self.status != noErr {
                    print("\(#line)：获取偏移量出错")
                    return
                }
                NotificationCenter.default.post(name: NSNotification.Name(rawValue: PlayerNotification.fetchDuration.rawValue), object: nil)
            case kAudioFileStreamProperty_AudioDataByteCount:	// 音频数据的总的字节数
                self.status = AudioFileStreamGetProperty(aStream, kAudioFileStreamProperty_AudioDataByteCount, &dataSize, &self.audioInfo.byteCount)
                if self.status != noErr {
                    print("\(#line)：获取总字节数出错")
                    return
                }
            case kAudioFileStreamProperty_DataFormat:	// 数据格式
                self.status = AudioFileStreamGetProperty(aStream, kAudioFileStreamProperty_DataFormat, &dataSize, &self.audioInfo.audioStreamBasicDescription)
                if self.status != noErr {
                    print("\(#line)：获取数据格式出错")
                    return
                }
            case kAudioFileStreamProperty_FormatList:	// 数据格式，但是与kAudioFileStreamProperty_DataFormat不同的是这个FormatList适用于AAC SBR等多文件类型的音频格式文件
                var formatList = [AudioFormatListItem](repeating: AudioFormatListItem(), count: Int(dataSize))
                self.status = AudioFileStreamGetProperty(aStream, kAudioFileStreamProperty_FormatList, &dataSize, &formatList)
                if self.status != noErr {
                    print("\(#line)：获取数据格式出错")
                    return
                }
                for i in 0..<Int(dataSize) {
                    let asbd = formatList[i].mASBD
                    if asbd.mFormatID == kAudioFormatMPEG4AAC_HE || asbd.mFormatID == kAudioFormatMPEG4AAC_HE_V2 {
                        // 只获取HE和AAC的
                        self.audioInfo.audioStreamBasicDescription = asbd
                        break
                    }
                }
            default: break
            }
        }
    }

    /// 当解析器在流数据中获取到音频数据的时候，会将数据传到此回调函数中进行处理
    ///
    /// - Parameters:
    ///   - numberBytes: 数据的字节数
    ///   - numberPackets: 数据的帧数
    ///   - inputData: 数据
    ///   - packetDescriptions: 帧描述
    func handleAudioData(with numberBytes: UInt32, numberPackets: UInt32, inputData: UnsafeRawPointer, packetDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>) {
        if numberBytes == 0 && numberPackets == 0 {
            return
        }

        synchronized(self) {
            if audioQueueBuffers.audioQueue == nil {
                createQueue()
            }
        }

        // 一般情况下，VBR的AudioStreamPacketDescription非空，可是从某位大大的blog中看到，CBR也有可能非空，不能单纯靠这个来判定，所以就根据Apple的文档来判定VBR和CBR
        // 文档地址： https://developer.apple.com/library/content/documentation/MusicAudio/Conceptual/AudioQueueProgrammingGuide/AQPlayback/PlayingAudio.html
        if audioInfo.audioStreamBasicDescription.mBytesPerPacket == 0 || audioInfo.audioStreamBasicDescription.mFramesPerPacket == 0 {
            // VBR
            for i in 0..<Int(numberPackets) {
                let packetOffset = packetDescriptions[i].mStartOffset
                let packetSize = packetDescriptions[i].mDataByteSize

                if Int(audioQueueBuffers.processedPacketsCount) < KJAudioPlayer.AudioQueueBuffers.bitRateEstimationMaxPackets {
                    audioQueueBuffers.processedPacketsCount += 1
                    audioQueueBuffers.processedPacketsSizeTotal += packetSize
                }

                let bufferSpaceRemaining: UInt32 = audioQueueBuffers.packetBufferSize - UInt32(audioQueueBuffers.bytesFilled)	// 当前缓冲区剩余的空间
                if bufferSpaceRemaining < packetSize {
                    // 不足以存放当前packet的话，就进入播放队列
                    enqueueBuffer()
                }

                synchronized(self) {
                    if UInt32(audioQueueBuffers.bytesFilled) + packetSize > audioQueueBuffers.packetBufferSize {
                        return
                    }

                    guard let audioQueueBuffer = audioQueueBuffers.audioQueueBuffer[audioQueueBuffers.fillBufferIndex] else {
                        return
                    }

                    // 将数据复制到缓冲区
                    memcpy(audioQueueBuffer.pointee.mAudioData.advanced(by: Int(audioQueueBuffers.bytesFilled)), inputData.advanced(by: Int(packetOffset)), Int(packetSize))
					audioQueueBuffers.packetDescription[Int(audioQueueBuffers.packetsFilled)] = packetDescriptions[i]
                    audioQueueBuffers.packetDescription[Int(audioQueueBuffers.packetsFilled)].mStartOffset = audioQueueBuffers.bytesFilled
                    audioQueueBuffers.bytesFilled += Int64(packetSize)
                    audioQueueBuffers.packetsFilled += 1
                }

                if Int(audioQueueBuffers.packetsFilled) == KJAudioPlayer.AudioQueueBuffers.audioQueueMaxPacketDescs {
                    enqueueBuffer()
                }
            }
        } else {
            // CBR
			var offset = 0
            var numberBytes = numberBytes
            while numberBytes != 0 {
                let bufferSpaceRemaining = audioQueueBuffers.packetBufferSize - UInt32(audioQueueBuffers.bytesFilled)
                if bufferSpaceRemaining < numberBytes {
                    enqueueBuffer()
                }

                synchronized(self) {
					let bufferSpaceRemaining = audioQueueBuffers.packetBufferSize - UInt32(audioQueueBuffers.bytesFilled)
                    let copySize = bufferSpaceRemaining < numberBytes ? bufferSpaceRemaining : numberBytes
                    if UInt32(audioQueueBuffers.bytesFilled) > audioQueueBuffers.packetBufferSize {
                        return
                    }

                    guard let audioQueueBuffer = audioQueueBuffers.audioQueueBuffer[audioQueueBuffers.fillBufferIndex] else {
                        return
                    }
                    // 将数据复制到缓冲区
                    memcpy(audioQueueBuffer.pointee.mAudioData.advanced(by: Int(audioQueueBuffers.bytesFilled)), inputData.advanced(by: Int(offset)), Int(copySize))
					audioQueueBuffers.bytesFilled += Int64(copySize)
                    audioQueueBuffers.packetsFilled = 0
                    numberBytes -= copySize
                    offset += Int(copySize)
                }
            }
        }
    }
}

// MARK: - Audio Queue
extension KJAudioPlayer {

    /// 创建队列
    func createQueue() {
        guard let audioFileStream = audioInfo.audioFileStream else {
            return
        }

        // 创建播放队列对象
        status = AudioQueueNewOutput(&audioInfo.audioStreamBasicDescription, { (clientData, audioQueue, buffer) in
            let client = Unmanaged<KJAudioPlayer>.fromOpaque(clientData!).takeUnretainedValue()
            client.audioQueue(audioQueue, finishAcquiring: buffer)
        }, pointee, nil, nil, 0, &audioQueueBuffers.audioQueue)
        if status != noErr {
            print("\(#line): 创建播放队列出错")
        }

        status = AudioQueueAddPropertyListener(audioQueueBuffers.audioQueue!, kAudioQueueProperty_IsRunning, { (clientData, audioQueue, propertyID) in
            let client = Unmanaged<KJAudioPlayer>.fromOpaque(clientData!).takeUnretainedValue()
            client.handle(propertyID, changeOf: audioQueue)
        }, pointee)
        if status != noErr {
            print("\(#line): 添加running监听程序出错")
        }

        var dataSize: UInt32 = 0
        status = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_PacketSizeUpperBound, &dataSize, &audioQueueBuffers.packetBufferSize)
        if status != noErr || audioQueueBuffers.packetBufferSize == 0 {
            status = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_MaximumPacketSize, &dataSize, &audioQueueBuffers.packetBufferSize)
            if status != noErr || audioQueueBuffers.packetBufferSize == 0 {
                audioQueueBuffers.packetBufferSize = UInt32(KJAudioPlayer.AudioQueueBuffers.bufferDefaultSize)
            }
        }

        for i in 0..<KJAudioPlayer.AudioQueueBuffers.audioQueueBufferNums {
            status = AudioQueueAllocateBuffer(audioQueueBuffers.audioQueue!, audioQueueBuffers.packetBufferSize, &audioQueueBuffers.audioQueueBuffer[i])
            if status != noErr {
                print("\(#line): 初始化缓冲区出错")
            }
        }

        // 对于一些压缩的音频文件，会使用到包含音频元数据的结构，即 Magic Cookie Data.在开始播放前，需要获取这部分数据，并添加到播放队列中
        var cookieSize: UInt32 = 0
        var writable: DarwinBoolean = false
        status = AudioFileStreamGetPropertyInfo(audioFileStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &writable)
        if status != noErr {
            return
        }

        let cookieData = UnsafeMutablePointer<Int8>.allocate(capacity: Int(cookieSize))
        status = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, cookieData)
        if status != noErr {
            return
        }

        status = AudioQueueSetProperty(audioQueueBuffers.audioQueue!, kAudioQueueProperty_MagicCookie, cookieData, cookieSize)
        if status != noErr {
            return
        }
    }

    /// 将缓冲区数据添加到播放队列中
    func enqueueBuffer() {
        synchronized(self) {
            audioQueueBuffers.inuseBuffer[audioQueueBuffers.fillBufferIndex] = true
			audioQueueBuffers.bufferUsed += 1

            guard let fillBuffer = audioQueueBuffers.audioQueueBuffer[audioQueueBuffers.fillBufferIndex],
                let audioQueue = audioQueueBuffers.audioQueue else {
                    return
            }
			fillBuffer.pointee.mAudioDataByteSize = UInt32(audioQueueBuffers.bytesFilled)

            if audioQueueBuffers.packetsFilled != 0 {
                status = AudioQueueEnqueueBuffer(audioQueue, fillBuffer, audioQueueBuffers.packetsFilled, audioQueueBuffers.packetDescription)
            } else {
				status = AudioQueueEnqueueBuffer(audioQueue, fillBuffer, 0, nil)
            }

            if status != noErr {
                print("\(#line): 入列出错")
                return
            }

            if audioQueueBuffers.bufferUsed == KJAudioPlayer.AudioQueueBuffers.audioQueueBufferNums - 1 {
                status = AudioQueueStart(audioQueue, nil)
                if status != noErr {
                    print("\(#line): 播放出错")
                    return
                }
            }

            audioQueueBuffers.fillBufferIndex += 1
            if audioQueueBuffers.fillBufferIndex >= KJAudioPlayer.AudioQueueBuffers.audioQueueBufferNums {
                audioQueueBuffers.fillBufferIndex = 0
            }
            audioQueueBuffers.bytesFilled = 0
            audioQueueBuffers.packetsFilled = 0
        }

        pthread_mutex_lock(&queueBuffersMutex)
        while audioQueueBuffers.inuseBuffer[audioQueueBuffers.fillBufferIndex] {
            pthread_cond_wait(&queueBufferReadyCondition, &queueBuffersMutex)
        }
        pthread_mutex_unlock(&queueBuffersMutex)
    }
}

// MARK: - Audio Queue Callback
extension KJAudioPlayer {

    /// 当播放队列已经完成接收一个缓冲区域的数据时调用
    ///
    /// - Parameters:
    ///   - audioQueue: 播放队列
    ///   - buffer: 一个缓冲区数据
    func audioQueue(_ audioQueue: AudioQueueRef, finishAcquiring buffer: AudioQueueBufferRef) {
        var bufferIndex = -1
        for (index, buf) in audioQueueBuffers.audioQueueBuffer.enumerated() {
            if buf == buffer {
                bufferIndex = index
                break
            }
        }

        if bufferIndex == -1 {
            return
        }

        pthread_mutex_lock(&queueBuffersMutex)
        audioQueueBuffers.inuseBuffer[bufferIndex] = false
        audioQueueBuffers.bufferUsed -= 1
        pthread_cond_signal(&queueBufferReadyCondition)
        pthread_mutex_unlock(&queueBuffersMutex)
    }

    func handle(_ property: AudioQueuePropertyID, changeOf audioQueue: AudioQueueRef) {

    }
}

// MARK: - Util
extension KJAudioPlayer {

    /// 线程锁，避免多个线程干扰
    ///
    /// - Parameters:
    ///   - lock: 要加锁的对象
    ///   - closure: 要执行的操作
    func synchronized(_ lock: AnyObject, closure:() ->()) {
        objc_sync_enter(lock)
        closure()
        objc_sync_exit(lock)
    }


    /// 根据URL的结尾判断音频文件的类型
    ///
    /// - Parameter aURL: URL
    /// - Returns: 文件类型
    func hint(of aURL: URL) -> AudioFileTypeID {
        switch aURL.pathExtension {
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
