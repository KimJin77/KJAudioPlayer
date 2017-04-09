//
//  KJSlider.swift
//  KJAudioPlayer
//
//  Created by Kim on 2017/4/8.
//  Copyright © 2017年 Kim. All rights reserved.
//

import UIKit

class KJSlider: UISlider {

    override var currentThumbImage: UIImage? {
        return #imageLiteral(resourceName: "mvplayer_progress_thumb")
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        print(subviews)
    }

}
