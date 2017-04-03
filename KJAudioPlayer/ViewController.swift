//
//  ViewController.swift
//  KJMusic
//
//  Created by Kim on 2017/3/22.
//  Copyright © 2017年 Kim. All rights reserved.
//

import UIKit
import CoreAudioKit
import AVFoundation

class ViewController: UIViewController {

    var player: AVPlayer?

    override func viewDidLoad() {
        super.viewDidLoad()

        if let filePath = Bundle.main.path(forResource: "nian_sui_yi_tou", ofType: "mp3") {
            let url = URL(fileURLWithPath: filePath)
            let audioURL = URL(string: "http://m10.music.126.net/20170323134345/4f3db089d6acd57d9d4e90ca78840de4/ymusic/a629/0fcf/f647/3be0ec581020ff0a080ffadf1df29ea6.mp3")
            let playerItem = AVPlayerItem(url: audioURL!)
			player = AVPlayer(playerItem: playerItem)
        }
    }

    @IBAction func play(_ sender: Any) {
        player!.play()
    }
}


