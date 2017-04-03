//
//  PlayButton.swift
//  KJMusic
//
//  Created by Kim on 2017/3/25.
//  Copyright © 2017年 Kim. All rights reserved.
//

import UIKit

class PlayButton: UIButton {
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        self.setImage(#imageLiteral(resourceName: "cm2_btn_play_full"), for: .normal)
        self.setImage(#imageLiteral(resourceName: "cm2_btn_pause_full"), for: .selected)
        self.setImage(#imageLiteral(resourceName: "cm2_btn_pause_full_prs"), for: [.selected, .highlighted])
		self.setImage(#imageLiteral(resourceName: "cm2_btn_play_full_prs"), for: .highlighted)
    }
}
