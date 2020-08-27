import Foundation
import UIKit
import Postbox
import Display
import SwiftSignalKit
import MonotonicTime
import AccountContext
import TelegramPresentationData
import PasscodeUI
import TelegramUIPreferences
import ImageBlur
import FastBlur
import AppLockState

private func isLocked(passcodeSettings: PresentationPasscodeSettings, state: LockState) -> Bool {
    if state.isManuallyLocked {
        return true
    } else if let autolockTimeout = passcodeSettings.autolockTimeout {
        var bootTimestamp: Int32 = 0
        let uptime = getDeviceUptimeSeconds(&bootTimestamp)
        let timestamp = MonotonicTimestamp(bootTimestamp: bootTimestamp, uptime: uptime)
        
        let applicationActivityTimestamp = state.applicationActivityTimestamp
        
        if let applicationActivityTimestamp = applicationActivityTimestamp {
            if timestamp.bootTimestamp != applicationActivityTimestamp.bootTimestamp {
                return true
            }
            if timestamp.uptime > applicationActivityTimestamp.uptime + autolockTimeout {
                return true
            }
        } else {
            return true
        }
    }
    return false
}

private func getCoveringViewSnaphot(window: Window1) -> UIImage? {
    print("getCoveringViewSnaphot")
    
    let scale: CGFloat = 0.5
    let unscaledSize = window.hostView.containerView.frame.size
    return generateImage(CGSize(width: floor(unscaledSize.width * scale), height: floor(unscaledSize.height * scale)), rotatedContext: { size, context in
        context.clear(CGRect(origin: CGPoint(), size: size))
        context.scaleBy(x: scale, y: scale)
        let snapshot = window.hostView.containerView.snapshotView(afterScreenUpdates: false)
        if let snapshot = snapshot {
            window.hostView.containerView.superview?.addSubview(snapshot)
        }
        UIGraphicsPushContext(context)
        
        window.forEachViewController({ controller in
            if let controller = controller as? PasscodeEntryController {
                controller.displayNode.alpha = 0.0
            }
            return true
        })
        window.hostView.containerView.drawHierarchy(in: CGRect(origin: CGPoint(), size: unscaledSize), afterScreenUpdates: true)
        window.forEachViewController({ controller in
            if let controller = controller as? PasscodeEntryController {
                controller.displayNode.alpha = 1.0
            }
            return true
        })
        
        UIGraphicsPopContext()
        snapshot?.removeFromSuperview()
    }).flatMap(applyScreenshotEffectToImage)
}

public final class AppLockContextImpl: AppLockContext {
    private let rootPath: String
    private let syncQueue = Queue()
    
    private let applicationBindings: TelegramApplicationBindings
    private let accountManager: AccountManager
    private let presentationDataSignal: Signal<PresentationData, NoError>
    private let window: Window1?
    private let rootController: UIViewController?
    
    private var coveringView: LockedWindowCoveringView?
    private var passcodeController: PasscodeEntryController?
    
    private var timestampRenewTimer: SwiftSignalKit.Timer?
    
    private var currentStateValue: LockState
    private let currentState = Promise<LockState>()
    
    private let autolockTimeout = ValuePromise<Int32?>(nil, ignoreRepeated: true)
    private let autolockReportTimeout = ValuePromise<Int32?>(nil, ignoreRepeated: true)
    
    private let isCurrentlyLockedPromise = Promise<Bool>()
    public var isCurrentlyLocked: Signal<Bool, NoError> {
        return self.isCurrentlyLockedPromise.get()
        |> distinctUntilChanged
    }
    
    private var lastActiveTimestamp: Double?
    private var lastActiveValue: Bool = false
    
    private var hiddenAccountsAccessChallengeDataDisposable: Disposable?
    public private(set) var hiddenAccountsAccessChallengeData = [AccountRecordId:PostboxAccessChallengeData]()
    
    public var unlockedHiddenAccountRecordId: ValuePromise<AccountRecordId?>
    private var unlockedHiddenAccountRecordIdValue: AccountRecordId?
    private var unlockedHiddenAccountRecordIdDisposable: Disposable?
    
    private var applicationInForegroundDisposable: Disposable?
    private let hiddenAccountManager: HiddenAccountManager
    
    public var isUnlockedAndReady: Signal<Void, NoError> {
        return self.isCurrentlyLockedPromise.get()
            |> filter { !$0 }
            |> distinctUntilChanged(isEqual: ==)
            |> mapToSignal { [weak self] _ in
                guard let strongSelf = self else { return .never() }
                
                return strongSelf.unlockedHiddenAccountRecordId.get()
                |> mapToSignal { unlockedHiddenAccountRecordId in
                    if unlockedHiddenAccountRecordId == nil {
                        return .single(())
                    } else {
                        return strongSelf.hiddenAccountManager.didFinishChangingAccountPromise.get() |> delay(0.1, queue: .mainQueue())
                    }
                }
        }
    }
    
    private var snapshot: UIImage?
    
    public init(rootPath: String, window: Window1?, rootController: UIViewController?, applicationBindings: TelegramApplicationBindings, accountManager: AccountManager, presentationDataSignal: Signal<PresentationData, NoError>, hiddenAccountManager: HiddenAccountManager, lockIconInitialFrame: @escaping () -> CGRect?) {
        assert(Queue.mainQueue().isCurrent())
        
        self.applicationBindings = applicationBindings
        self.accountManager = accountManager
        self.presentationDataSignal = presentationDataSignal
        self.rootPath = rootPath
        self.window = window
        self.rootController = rootController
        self.hiddenAccountManager = hiddenAccountManager
        self.unlockedHiddenAccountRecordId = hiddenAccountManager.unlockedHiddenAccountRecordIdPromise
        
        if let data = try? Data(contentsOf: URL(fileURLWithPath: appLockStatePath(rootPath: self.rootPath))), let current = try? JSONDecoder().decode(LockState.self, from: data) {
            self.currentStateValue = current
        } else {
            self.currentStateValue = LockState()
        }
        self.autolockTimeout.set(self.currentStateValue.autolockTimeout)
        
        self.hiddenAccountsAccessChallengeDataDisposable = (hiddenAccountManager.getHiddenAccountsAccessChallengeDataPromise.get() |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let strongSelf = self else {
                return
            }
            
            strongSelf.hiddenAccountsAccessChallengeData = value
        })
        
        self.unlockedHiddenAccountRecordIdDisposable = (self.unlockedHiddenAccountRecordId.get() |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let strongSelf = self else {
                return
            }
            
            strongSelf.unlockedHiddenAccountRecordIdValue = value
        })
        
        let _ = (combineLatest(queue: .mainQueue(),
            accountManager.accessChallengeData(),
            accountManager.sharedData(keys: Set([ApplicationSpecificSharedDataKeys.presentationPasscodeSettings])),
            presentationDataSignal,
            applicationBindings.applicationIsActive,
            self.currentState.get()
        )
        |> deliverOnMainQueue).start(next: { [weak self] accessChallengeData, sharedData, presentationData, appInForeground, state in
            guard let strongSelf = self else {
                return
            }
            
            let passcodeSettings: PresentationPasscodeSettings = sharedData.entries[ApplicationSpecificSharedDataKeys.presentationPasscodeSettings] as? PresentationPasscodeSettings ?? .defaultSettings
            
            let timestamp = CFAbsoluteTimeGetCurrent()
            var becameActiveRecently = false
            if appInForeground {
                if !strongSelf.lastActiveValue {
                    strongSelf.lastActiveValue = true
                    strongSelf.lastActiveTimestamp = timestamp
                }
                
                if let lastActiveTimestamp = strongSelf.lastActiveTimestamp {
                    if lastActiveTimestamp + 0.5 > timestamp {
                        becameActiveRecently = true
                    }
                }
            } else {
                strongSelf.lastActiveValue = false
            }
            
            var shouldDisplayCoveringView = false
            var isCurrentlyLocked = false
            
            if !accessChallengeData.data.isLockable {
                if let passcodeController = strongSelf.passcodeController {
                    strongSelf.passcodeController = nil
                    passcodeController.dismiss()
                }
                
                strongSelf.autolockTimeout.set(nil)
                strongSelf.autolockReportTimeout.set(nil)
            } else {
                if let autolockTimeout = passcodeSettings.autolockTimeout, !appInForeground {
                    shouldDisplayCoveringView = true
                }
                
                if !appInForeground {
                    if let autolockTimeout = passcodeSettings.autolockTimeout {
                        strongSelf.autolockReportTimeout.set(autolockTimeout)
                    } else if state.isManuallyLocked {
                        strongSelf.autolockReportTimeout.set(1)
                    } else {
                        strongSelf.autolockReportTimeout.set(nil)
                    }
                } else {
                    strongSelf.autolockReportTimeout.set(nil)
                }
                
                strongSelf.autolockTimeout.set(passcodeSettings.autolockTimeout)
                
                if isLocked(passcodeSettings: passcodeSettings, state: state) {
                    isCurrentlyLocked = true
                    
                    let biometrics: PasscodeEntryControllerBiometricsMode
                    if passcodeSettings.enableBiometrics {
                        biometrics = .enabled(passcodeSettings.biometricsDomainState)
                    } else {
                        biometrics = .none
                    }
                    
                    if let passcodeController = strongSelf.passcodeController {
                        if becameActiveRecently, case .enabled = biometrics, appInForeground {
                            passcodeController.requestBiometrics()
                        }
                        passcodeController.ensureInputFocused()
                    } else {
                        let passcodeController = PasscodeEntryController(applicationBindings: strongSelf.applicationBindings, accountManager: strongSelf.accountManager, appLockContext: strongSelf, presentationData: presentationData, presentationDataSignal: strongSelf.presentationDataSignal, challengeData: accessChallengeData.data, hiddenAccountsAccessChallengeData: strongSelf.hiddenAccountsAccessChallengeData, biometrics: biometrics, arguments: PasscodeEntryControllerPresentationArguments(animated: !becameActiveRecently, lockIconInitialFrame: { [weak self] in
                            if let lockViewFrame = lockIconInitialFrame() {
                                return lockViewFrame
                            } else {
                                return CGRect()
                            }
                        }), hasPublicAccountsSignal: hiddenAccountManager.hasPublicAccounts(accountManager: accountManager))
                        if becameActiveRecently, appInForeground {
                            passcodeController.presentationCompleted = { [weak passcodeController, weak self] in
                                if let strongSelf = self {
                                    strongSelf.unlockedHiddenAccountRecordId.set(nil)
                                }
                                if case .enabled = biometrics {
                                    passcodeController?.requestBiometrics()
                                }
                                passcodeController?.ensureInputFocused()
                            }
                        } else {
                            passcodeController.presentationCompleted = { [weak self] in
                                if let strongSelf = self {
                                    strongSelf.unlockedHiddenAccountRecordId.set(nil)
                                }
                            }
                        }
                        passcodeController.presentedOverCoveringView = true
                        passcodeController.isOpaqueWhenInOverlay = true
                        strongSelf.passcodeController = passcodeController
                        if let rootViewController = strongSelf.rootController {
                            if let presentedViewController = rootViewController.presentedViewController as? UIActivityViewController {
                            } else {
                                rootViewController.dismiss(animated: false, completion: nil)
                            }
                        }
                        strongSelf.window?.present(passcodeController, on: .passcode)
                    }
                } else if let passcodeController = strongSelf.passcodeController {
                    strongSelf.passcodeController = nil
                    passcodeController.dismiss()
                }
            }
            
            strongSelf.updateTimestampRenewTimer(shouldRun: appInForeground && !isCurrentlyLocked)
            strongSelf.isCurrentlyLockedPromise.set(.single(!appInForeground || isCurrentlyLocked))
            
            if shouldDisplayCoveringView {
                if strongSelf.coveringView == nil, let window = strongSelf.window {
                    let coveringView = LockedWindowCoveringView(theme: presentationData.theme)
                    coveringView.updateSnapshot(strongSelf.snapshot)
                    strongSelf.coveringView = coveringView
                    window.coveringView = coveringView
                    
                    if let rootViewController = strongSelf.rootController {
                        if let presentedViewController = rootViewController.presentedViewController as? UIActivityViewController {
                        } else {
                            rootViewController.dismiss(animated: false, completion: nil)
                        }
                    }
                }
            } else {
                if let coveringView = strongSelf.coveringView {
                    strongSelf.coveringView = nil
                    strongSelf.window?.coveringView = nil
                }
            }
        })
        
        self.currentState.set(.single(self.currentStateValue))
        
        self.applicationInForegroundDisposable = (applicationBindings.applicationInForeground
            |> distinctUntilChanged(isEqual: ==)
            |> filter { !$0 }
            |> deliverOnMainQueue).start(next: { [weak self] _ in
                guard let strongSelf = self else { return }
                
                strongSelf.unlockedHiddenAccountRecordId.set(nil)
        })
        
        let _ = (self.autolockTimeout.get()
        |> deliverOnMainQueue).start(next: { [weak self] autolockTimeout in
            self?.updateLockState { state in
                var state = state
                state.autolockTimeout = autolockTimeout
                return state
            }
        })
    }
    
    public func updateSnapshot() {
        guard let window = self.window, window.coveringView == nil, self.unlockedHiddenAccountRecordIdValue == nil else { return }
        
        let snapshot = getCoveringViewSnaphot(window: window)
        self.snapshot = snapshot
    }
    
    private func updateTimestampRenewTimer(shouldRun: Bool) {
        if shouldRun {
            if self.timestampRenewTimer == nil {
                let timestampRenewTimer = SwiftSignalKit.Timer(timeout: 1.0, repeat: true, completion: { [weak self] in
                    guard let strongSelf = self else {
                        return
                    }
                    strongSelf.updateApplicationActivityTimestamp()
                }, queue: .mainQueue())
                self.timestampRenewTimer = timestampRenewTimer
                timestampRenewTimer.start()
            }
        } else {
            if let timestampRenewTimer = self.timestampRenewTimer {
                self.timestampRenewTimer = nil
                timestampRenewTimer.invalidate()
            }
        }
    }
    
    private func updateApplicationActivityTimestamp() {
        self.updateLockState { state in
            var bootTimestamp: Int32 = 0
            let uptime = getDeviceUptimeSeconds(&bootTimestamp)
            
            var state = state
            state.applicationActivityTimestamp = MonotonicTimestamp(bootTimestamp: bootTimestamp, uptime: uptime)
            return state
        }
    }
    
    private func updateLockState(_ f: @escaping (LockState) -> LockState) {
        Queue.mainQueue().async {
            let updatedState = f(self.currentStateValue)
            if updatedState != self.currentStateValue {
                self.currentStateValue = updatedState
                self.currentState.set(.single(updatedState))
                
                let path = appLockStatePath(rootPath: self.rootPath)
                
                self.syncQueue.async {
                    if let data = try? JSONEncoder().encode(updatedState) {
                        let _ = try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
                    }
                }
            }
        }
    }
    
    public var invalidAttempts: Signal<AccessChallengeAttempts?, NoError> {
        return self.currentState.get()
        |> map { state in
            return state.unlockAttemts.flatMap { unlockAttemts in
                return AccessChallengeAttempts(count: unlockAttemts.count, bootTimestamp: unlockAttemts.timestamp.bootTimestamp, uptime: unlockAttemts.timestamp.uptime)
            }
        }
    }
    
    public var autolockDeadline: Signal<Int32?, NoError> {
        return self.autolockReportTimeout.get()
        |> distinctUntilChanged
        |> map { value -> Int32? in
            if let value = value {
                return Int32(Date().timeIntervalSince1970) + value
            } else {
                return nil
            }
        }
    }
    
    public func lock() {
        self.updateLockState { state in
            var state = state
            state.isManuallyLocked = true
            return state
        }
    }
    
    public func unlock() {
        self.updateLockState { state in
            var state = state
            
            state.unlockAttemts = nil
            
            state.isManuallyLocked = false
            
            var bootTimestamp: Int32 = 0
            let uptime = getDeviceUptimeSeconds(&bootTimestamp)
            let timestamp = MonotonicTimestamp(bootTimestamp: bootTimestamp, uptime: uptime)
            state.applicationActivityTimestamp = timestamp
            
            return state
        }
    }
    
    public func failedUnlockAttempt() {
        self.updateLockState { state in
            var state = state
            var unlockAttemts = state.unlockAttemts ?? UnlockAttempts(count: 0, timestamp: MonotonicTimestamp(bootTimestamp: 0, uptime: 0))
            
            unlockAttemts.count += 1
            
            var bootTimestamp: Int32 = 0
            let uptime = getDeviceUptimeSeconds(&bootTimestamp)
            let timestamp = MonotonicTimestamp(bootTimestamp: bootTimestamp, uptime: uptime)
            
            unlockAttemts.timestamp = timestamp
            state.unlockAttemts = unlockAttemts
            return state
        }
    }
    
    deinit {
        self.hiddenAccountsAccessChallengeDataDisposable?.dispose()
        self.applicationInForegroundDisposable?.dispose()
        self.unlockedHiddenAccountRecordIdDisposable?.dispose()
    }
}
