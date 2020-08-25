import Foundation
import SwiftSignalKit
import TelegramCore
import SyncCore
import Postbox
import LightweightAccountData
import BuildConfig

private func accountInfo(account: Account) -> Signal<StoredAccountInfo, NoError> {
    let peerName = account.postbox.transaction { transaction -> String in
        guard let peer = transaction.getPeer(account.peerId) else {
            return ""
        }
        if let addressName = peer.addressName {
            return "\(addressName)"
        }
        return peer.debugDisplayTitle
    }
    
    let primaryDatacenterId = Int32(account.network.datacenterId)
    let context = account.network.context
    
    var datacenters: [Int32: AccountDatacenterInfo] = [:]
    for nId in context.knownDatacenterIds() {
        if let id = nId as? Int {
            if let authInfo = context.authInfoForDatacenter(withId: id), let authKey = authInfo.authKey {
                let transportScheme = context.chooseTransportSchemeForConnection(toDatacenterId: id, schemes: context.transportSchemesForDatacenter(withId: id, media: true, enforceMedia: false, isProxy: false))
                var addressList: [AccountDatacenterAddress] = []
                if let transportScheme = transportScheme, let address = transportScheme.address, let host = address.host {
                    let secret: Data? = address.secret
                    addressList.append(AccountDatacenterAddress(host: host, port: Int32(address.port), isMedia: address.preferForMedia, secret: secret))
                }
                datacenters[Int32(id)] = AccountDatacenterInfo(masterKey: AccountDatacenterKey(id: authInfo.authKeyId, data: authKey), addressList: addressList)
            }
        }
    }
    
    let notificationKey = masterNotificationsKey(account: account, ignoreDisabled: false)
    
    return combineLatest(peerName, notificationKey)
    |> map { peerName, notificationKey -> StoredAccountInfo in
        return StoredAccountInfo(id: account.id.int64, primaryId: primaryDatacenterId, isTestingEnvironment: account.testingEnvironment, peerName: peerName, datacenters: datacenters, notificationKey: AccountNotificationKey(id: notificationKey.id, data: notificationKey.data))
    }
}

func sharedAccountInfos(accountManager: AccountManager, accounts: Signal<[Account], NoError>) -> Signal<StoredAccountInfos, NoError> {
    return combineLatest(accountManager.sharedData(keys: [SharedDataKeys.proxySettings]), filterPublicAccounts(accounts, accountManager: accountManager))
    |> mapToSignal { sharedData, accounts -> Signal<StoredAccountInfos, NoError> in
        let proxySettings = sharedData.entries[SharedDataKeys.proxySettings] as? ProxySettings
        let proxy = proxySettings?.effectiveActiveServer.flatMap { proxyServer -> AccountProxyConnection? in
            var username: String?
            var password: String?
            var secret: Data?
            switch proxyServer.connection {
                case let .socks5(usernameValue, passwordValue):
                    username = usernameValue
                    password = passwordValue
                case let .mtp(secretValue):
                    secret = secretValue
            }
            return AccountProxyConnection(host: proxyServer.host, port: proxyServer.port, username: username, password: password, secret: secret)
        }

        var rootPath: String?
        var encryptionParameters: ValueBoxEncryptionParameters?
        
        let baseAppBundleId = Bundle.main.bundleIdentifier!
        let appGroupName = "group.\(baseAppBundleId)"
        let maybeAppGroupUrl = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupName)
        if let appGroupUrl = maybeAppGroupUrl {
            rootPath = rootPathForBasePath(appGroupUrl.path)
            let deviceSpecificEncryptionParameters = BuildConfig.deviceSpecificEncryptionParameters(rootPath!, baseAppBundleId: baseAppBundleId)
            encryptionParameters = ValueBoxEncryptionParameters(forceEncryptionIfNoSet: false, key: ValueBoxEncryptionParameters.Key(data: deviceSpecificEncryptionParameters.key)!, salt: ValueBoxEncryptionParameters.Salt(data: deviceSpecificEncryptionParameters.salt)!)
        }
        
        let hiddenNotificationKeys = accountManager.transaction({ transaction -> [AccountRecordId] in
            return transaction.getRecords()
                .filter { $0.attributes.contains(where: { $0 is HiddenAccountAttribute }) }
                .map { $0.id }
        }) |> mapToSignal { hiddenAccountIds in
            return combineLatest(hiddenAccountIds.compactMap { id -> Signal<(String, AccountNotificationKey)?, NoError>? in
                guard let rootPath = rootPath, let encryptionParameters = encryptionParameters else { return nil }
                
                return masterNotificationsKey(rootPath: rootPath, id: id, encryptionParameters: encryptionParameters)
                |> map { key in
                    guard let key = key else { return nil }
                    
                    return ("\(id.int64)", AccountNotificationKey(id: key.id, data: key.data))
                }
            })
        } |> take(1)
        
        return combineLatest(combineLatest(accounts.map(accountInfo)), hiddenNotificationKeys)
        |> map { infos, hiddenNotificationKeys -> StoredAccountInfos in
            return StoredAccountInfos(proxy: proxy, accounts: infos, hiddenNotificationKeys: Dictionary(uniqueKeysWithValues: hiddenNotificationKeys.compactMap { $0 }))
        }
    }
}

func storeAccountsData(rootPath: String, accounts: StoredAccountInfos) {
    guard let data = try? JSONEncoder().encode(accounts) else {
        Logger.shared.log("storeAccountsData", "Error encoding data")
        return
    }
    guard let _ = try? data.write(to: URL(fileURLWithPath: rootPath + "/accounts-shared-data")) else {
        Logger.shared.log("storeAccountsData", "Error saving data")
        return
    }
}

private func filterPublicAccounts(_ signal: Signal<[Account], NoError>, accountManager: AccountManager) -> Signal<[Account], NoError> {
    signal |> mapToSignal { accounts in
        accountManager.transaction { transaction in
            let hiddenIds = Set(transaction.getRecords().filter { $0.attributes.contains(where: { $0 is HiddenAccountAttribute }) }.map { $0.id })
            return accounts.filter { !hiddenIds.contains($0.id) }
        }
    }
}
