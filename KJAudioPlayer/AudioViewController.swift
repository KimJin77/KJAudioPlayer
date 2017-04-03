//
//  AudioViewController.swift
//  KJMusic
//
//  Created by Kim on 2017/3/23.
//  Copyright © 2017年 Kim. All rights reserved.
//

import UIKit
import AVFoundation

class AudioViewController: UIViewController {

//    let player = KJAudioPlayer(URL(string: "http://mr3.doubanio.com/92abf16874bbbe6a1c77faeb8e1e35b3/0/fm/song/p1888508_128k.mp4")!)
	let player = KJAudioPlayer(URL(string: "http://7u2m53.com1.z0.glb.clouddn.com/nian_sui_yi_tou.mp3")!)
    override func viewDidLoad() {
        super.viewDidLoad()

    }

}

// MARK: - Action
extension AudioViewController {
    @IBAction func play(_ sender: PlayButton) {
        sender.isSelected = !sender.isSelected
        player.start()
    }
}

