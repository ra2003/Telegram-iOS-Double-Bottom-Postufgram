import Foundation
import UIKit
import AppBundle
import AsyncDisplayKit
import Display
import SolidRoundedButtonNode
import SwiftSignalKit
import OverlayStatusController
import AnimatedStickerNode
import AccountContext
import TelegramPresentationData
import PresentationDataUtils

public enum FalseBottomSplashMode {
    case hideAccount
    case addOneMoreAccount
    case setMasterPasscode
    case setSecretPasscode
    case accountWasHidden
}

public final class FalseBottomSplashScreen: ViewController {
    private let presentationData: PresentationData
    private let mode: FalseBottomSplashMode
    
    var buttonPressed: (() -> Void)?
    
    public init(presentationData: PresentationData, mode: FalseBottomSplashMode) {
        self.presentationData = presentationData
        self.mode = mode
        
        let defaultTheme = NavigationBarTheme(rootControllerTheme: self.presentationData.theme)
        let navigationBarTheme = NavigationBarTheme(buttonColor: defaultTheme.buttonColor, disabledButtonColor: defaultTheme.disabledButtonColor, primaryTextColor: defaultTheme.primaryTextColor, backgroundColor: .clear, separatorColor: .clear, badgeBackgroundColor: defaultTheme.badgeBackgroundColor, badgeStrokeColor: defaultTheme.badgeStrokeColor, badgeTextColor: defaultTheme.badgeTextColor)
        
        super.init(navigationBarPresentationData: NavigationBarPresentationData(theme: navigationBarTheme, strings: NavigationBarStrings(back: self.presentationData.strings.Common_Back, close: self.presentationData.strings.Common_Close)))
        
        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
        self.navigationPresentation = .modalInLargeLayout
        self.supportedOrientations = ViewControllerSupportedOrientations(regularSize: .all, compactSize: .portrait)
        self.navigationBar?.intrinsicCanTransitionInline = false
        
        self.navigationItem.backBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Common_Back, style: .plain, target: nil, action: nil)
        self.navigationPresentation = .modalInLargeLayout
    }
    
    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
    }
    
    override public func loadDisplayNode() {
        self.displayNode = FalseBottomSplashScreenNode(presentationData: self.presentationData, mode: self.mode, action: { [weak self] in
            guard let strongSelf = self else {
                return
            }
            
            strongSelf.buttonPressed?()
        })
        
        self.displayNodeDidLoad()
    }
    
    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        
        (self.displayNode as! FalseBottomSplashScreenNode).containerLayoutUpdated(layout: layout, navigationHeight: self.navigationHeight, transition: transition)
    }
}

private final class FalseBottomSplashScreenNode: ViewControllerTracingNode {
    private let presentationData: PresentationData
    private let mode: FalseBottomSplashMode
    
    private var animationSize: CGSize = CGSize()
    private var animationOffset: CGPoint = CGPoint()
    private let animationNode: AnimatedStickerNode
    private let titleNode: ImmediateTextNode
    private let textNode: ImmediateTextNode
    let buttonNode: SolidRoundedButtonNode
    
    var inProgress: Bool = false {
        didSet {
            self.buttonNode.isUserInteractionEnabled = !self.inProgress
            self.buttonNode.alpha = self.inProgress ? 0.6 : 1.0
        }
    }
    
    init(presentationData: PresentationData, mode: FalseBottomSplashMode, action: @escaping () -> Void) {
        self.presentationData = presentationData
        self.mode = mode
        
        self.animationNode = AnimatedStickerNode()
        
        let title: String
        let text: NSAttributedString
        let buttonText: String
        
        let textFont = Font.regular(16.0)
        let textColor = self.presentationData.theme.list.itemPrimaryTextColor

        switch mode {
        case .hideAccount:
            title = presentationData.strings.FalseBottom_HideAccount_Title
            text = NSAttributedString(string: presentationData.strings.FalseBottom_HideAccount_Text, font: textFont, textColor: textColor)
            buttonText = presentationData.strings.FalseBottom_HideAccount_Button
            
            if let path = getAppBundle().path(forResource: "FalseBottomAddAccount", ofType: "tgs") {
                self.animationNode.setup(source: AnimatedStickerNodeLocalFileSource(path: path), width: 568, height: 640, playbackMode: .loop, mode: .direct, fillColors: [
                    "Shape Layer 1.**.Fill 1": self.presentationData.theme.list.plainBackgroundColor,
                    "phone Outlines.**.Fill 1": self.presentationData.theme.list.plainBackgroundColor
                ])
                self.animationSize = CGSize(width: 284, height: 320)
                self.animationNode.visibility = true
            }
            
        case .addOneMoreAccount:
            title = presentationData.strings.FalseBottom_AddOneMoreAccount_Title
            text = NSAttributedString(string: presentationData.strings.FalseBottom_AddOneMoreAccount_Text, font: textFont, textColor: textColor)
            buttonText = presentationData.strings.FalseBottom_AddOneMoreAccount_Button
            
            if let path = getAppBundle().path(forResource: "TwoFactorSetupIntro", ofType: "tgs") {
                self.animationNode.setup(source: AnimatedStickerNodeLocalFileSource(path: path), width: 248, height: 248, playbackMode: .once, mode: .direct)
                self.animationSize = CGSize(width: 124.0, height: 124.0)
                self.animationNode.visibility = true
        }
            
        case .setMasterPasscode:
            title = presentationData.strings.FalseBottom_SetMasterPasscode_Title
            text = NSAttributedString(string: presentationData.strings.FalseBottom_SetMasterPasscode_Text, font: textFont, textColor: textColor)
            buttonText = presentationData.strings.FalseBottom_SetMasterPasscode_Button
            
            if let path = getAppBundle().path(forResource: "TwoFactorSetupIntro", ofType: "tgs") {
                self.animationNode.setup(source: AnimatedStickerNodeLocalFileSource(path: path), width: 248, height: 248, playbackMode: .once, mode: .direct)
                self.animationSize = CGSize(width: 124.0, height: 124.0)
                self.animationNode.visibility = true
            }
            
        case .setSecretPasscode:
            title = presentationData.strings.FalseBottom_SetSecretPasscode_Title
            text = NSAttributedString(string: presentationData.strings.FalseBottom_SetSecretPasscode_Text, font: textFont, textColor: textColor)
            buttonText = presentationData.strings.FalseBottom_SetSecretPasscode_Button
            
            if let path = getAppBundle().path(forResource: "TwoFactorSetupIntro", ofType: "tgs") {
                self.animationNode.setup(source: AnimatedStickerNodeLocalFileSource(path: path), width: 248, height: 248, playbackMode: .once, mode: .direct)
                self.animationSize = CGSize(width: 124.0, height: 124.0)
                self.animationNode.visibility = true
            }

        case .accountWasHidden:
            title = presentationData.strings.FalseBottom_AccountWasHidden_Title
            text = NSAttributedString(string: presentationData.strings.FalseBottom_AccountWasHidden_Text, font: textFont, textColor: textColor)
            buttonText = presentationData.strings.FalseBottom_AccountWasHidden_Button
            
            if let path = getAppBundle().path(forResource: "TwoFactorSetupDone", ofType: "tgs") {
                self.animationNode.setup(source: AnimatedStickerNodeLocalFileSource(path: path), width: 248, height: 248, mode: .direct)
                self.animationSize = CGSize(width: 124.0, height: 124.0)
                self.animationNode.visibility = true
            }
        }
        
        self.titleNode = ImmediateTextNode()
        self.titleNode.displaysAsynchronously = false
        self.titleNode.attributedText = NSAttributedString(string: title, font: Font.bold(32.0), textColor: self.presentationData.theme.list.itemPrimaryTextColor)
        self.titleNode.maximumNumberOfLines = 0
        self.titleNode.textAlignment = .center
        
        self.textNode = ImmediateTextNode()
        self.textNode.displaysAsynchronously = false
        self.textNode.attributedText = text
        self.textNode.maximumNumberOfLines = 0
        self.textNode.lineSpacing = 0.1
        self.textNode.textAlignment = .center
        
        self.buttonNode = SolidRoundedButtonNode(title: buttonText, theme: SolidRoundedButtonTheme(backgroundColor: self.presentationData.theme.list.itemCheckColors.fillColor, foregroundColor: self.presentationData.theme.list.itemCheckColors.foregroundColor), height: 50.0, cornerRadius: 10.0, gloss: false)
        self.buttonNode.isHidden = buttonText.isEmpty
        
        super.init()
        
        self.backgroundColor = self.presentationData.theme.list.plainBackgroundColor
        
        self.addSubnode(self.animationNode)
        self.addSubnode(self.titleNode)
        self.addSubnode(self.textNode)
        self.addSubnode(self.buttonNode)
        
        self.buttonNode.pressed = {
            action()
        }
    }
    
    override func didLoad() {
        super.didLoad()
    }
    
    func containerLayoutUpdated(layout: ContainerViewLayout, navigationHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        let sideInset: CGFloat = 32.0
        let buttonSideInset: CGFloat = 48.0
        let iconSpacing: CGFloat = 35.0
        let titleSpacing: CGFloat = 19.0
        let buttonHeight: CGFloat = 50.0
        
        let iconSize: CGSize = self.animationSize
        var iconOffset = CGPoint()
        switch self.mode {
        case .accountWasHidden:
            iconOffset.x = 10.0
        default:
            break
        }
        
        let titleSize = self.titleNode.updateLayout(CGSize(width: layout.size.width - sideInset * 2.0, height: layout.size.height))
        let textSize = self.textNode.updateLayout(CGSize(width: layout.size.width - sideInset * 2.0, height: layout.size.height))
        
        let contentHeight = iconSize.height + iconSpacing + titleSize.height + titleSpacing + textSize.height
        var contentVerticalOrigin = floor((layout.size.height - contentHeight - iconSize.height / 2.0) / 2.0)
        
        let minimalBottomInset: CGFloat = 60.0
        let bottomInset = layout.intrinsicInsets.bottom + minimalBottomInset
        
        let buttonWidth = layout.size.width - buttonSideInset * 2.0
        
        let buttonFrame = CGRect(origin: CGPoint(x: floor((layout.size.width - buttonWidth) / 2.0), y: layout.size.height - bottomInset - buttonHeight), size: CGSize(width: buttonWidth, height: buttonHeight))
        transition.updateFrame(node: self.buttonNode, frame: buttonFrame)
        self.buttonNode.updateLayout(width: buttonFrame.width, transition: transition)
        
        var maxContentVerticalOrigin = buttonFrame.minY - 12.0 - contentHeight
        
        contentVerticalOrigin = min(contentVerticalOrigin, maxContentVerticalOrigin)
        
        let iconFrame = CGRect(origin: CGPoint(x: floor((layout.size.width - iconSize.width) / 2.0) + self.animationOffset.x, y: contentVerticalOrigin + self.animationOffset.y), size: iconSize).offsetBy(dx: iconOffset.x, dy: iconOffset.y)
        self.animationNode.updateLayout(size: iconFrame.size)
        transition.updateFrameAdditive(node: self.animationNode, frame: iconFrame)
        let titleFrame = CGRect(origin: CGPoint(x: floor((layout.size.width - titleSize.width) / 2.0), y: iconFrame.maxY + iconSpacing), size: titleSize)
        transition.updateFrameAdditive(node: self.titleNode, frame: titleFrame)
        let textFrame = CGRect(origin: CGPoint(x: floor((layout.size.width - textSize.width) / 2.0), y: titleFrame.maxY + titleSpacing), size: textSize)
        transition.updateFrameAdditive(node: self.textNode, frame: textFrame)
    }
}
