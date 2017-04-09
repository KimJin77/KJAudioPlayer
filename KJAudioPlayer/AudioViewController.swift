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

    @IBOutlet weak var playButton: UIButton!
    @IBOutlet weak var progressSlider: UISlider!
    @IBOutlet weak var durationLabel: UILabel!
//    let player = KJAudioPlayer(URL(string: "http://mr3.doubanio.com/92abf16874bbbe6a1c77faeb8e1e35b3/0/fm/song/p1888508_128k.mp4")!)
    @IBOutlet weak var albumView: UIImageView!

	let player = KJAudioPlayer(URL(string: "http://7u2m53.com1.z0.glb.clouddn.com/nian_sui_yi_tou.mp3")!)
    override func viewDidLoad() {
        super.viewDidLoad()
        setUpSubviews()
		registerNotification()
    }

    func setUpSubviews() {
        albumView.layer.cornerRadius = 165
        navigationController?.setNavigationBarHidden(true, animated: true)
        setPlayButtonImage()
    }

    private func setPlayButtonImage() {
        playButton.setImage(#imageLiteral(resourceName: "player_btn_play_normal"), for: .normal)
        playButton.setImage(#imageLiteral(resourceName: "player_btn_play_highlight"), for: .highlighted)
        playButton.setImage(#imageLiteral(resourceName: "player_btn_pause_normal"), for: .selected)
        playButton.setImage(#imageLiteral(resourceName: "player_btn_pause_highlight"), for: [.selected, .highlighted])
    }

    private func registerNotification() {
        NotificationCenter.default.addObserver(forName: NSNotification.Name(rawValue: KJAudioPlayer.PlayerNotification.fetchDuration.rawValue), object: nil, queue: nil) { [unowned self] (notification) in
            // 消息发送的出来的时候并不是在主线程
            DispatchQueue.main.async {
                self.durationLabel.text = self.player.duration.0 + ":" + self.player.duration.1
                NotificationCenter.default.removeObserver(self, name: NSNotification.Name(rawValue: KJAudioPlayer.PlayerNotification.fetchDuration.rawValue), object: nil)
            }
        }
    }
}

// MARK: - IBAction

extension AudioViewController {
    @IBAction func play(_ sender: UIButton) {
        sender.isSelected = !sender.isSelected
        if sender.isSelected {
			player.start()
        } else {

        }
    }

    @IBAction func close(_ sender: UIButton) {
		navigationController?.popViewController(animated: true)
    }
}

