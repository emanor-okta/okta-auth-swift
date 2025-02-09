//
// Copyright (c) 2022-Present, Okta, Inc. and/or its affiliates. All rights reserved.
// The Okta software accompanied by this notice is provided pursuant to the Apache License, Version 2.0 (the "License.")
//
// You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0.
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
// WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//
// See the License for the specific language governing permissions and limitations under the License.
//

import Foundation

#if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)

private let accountIdRegex = try? NSRegularExpression(pattern: "0oa[0-9a-zA-Z]{17}")

extension SDKVersion.Migration {
    /// Migrator capable of importing credentials from the legacy `OktaOidc` SDK.
    ///
    /// If your application previously used the `OktaOidc` SDK, you can use this to register your client configuration to enable credentials already stored within your user's devices to be migrated to the new AuthFoundation SDK.
    ///
    /// ```swift
    /// func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    ///     // Import the default `Okta.plist` configuration for migration
    ///     try? SDKVersion.Migration.LegacyOIDC.register()
    ///     try? SDKVersion.migrateIfNeeded()
    ///
    ///     return true
    /// }
    /// ```
    public final class LegacyOIDC: SDKVersionMigrator {
        /// Registers the legacy OIDC migration using the OIDC configuration settings from your application's `Okta.plist` file.
        public static func register() throws {
            try register(try OAuth2Client.PropertyListConfiguration())
        }
        
        /// Registers the legacy OIDC migration using the OIDC configuration settings from the given property list file URL.
        /// - Parameter fileURL: File URL for the property list to read from.
        public static func register(plist fileURL: URL) throws {
            try register(try OAuth2Client.PropertyListConfiguration(plist: fileURL))
        }
        
        /// Registers the legacy OIDC migration using the supplied configuration values.
        /// - Parameters:
        ///   - issuer: Issuer URL for your client.
        ///   - clientId: Client ID for your application.
        ///   - redirectUri: The Redirect URI for your client.
        ///   - scopes: The scopes configured for your client.
        public static func register(issuer: URL,
                                    clientId: String,
                                    redirectUri: URL,
                                    scopes: String)
        {
            SDKVersion.register(migrator: LegacyOIDC(issuer: issuer,
                                                     clientId: clientId,
                                                     redirectUri: redirectUri,
                                                     scopes: scopes))
        }
        
        private static func register(_ config: OAuth2Client.PropertyListConfiguration) throws {
            guard let redirectUri = config.redirectUri else {
                throw OAuth2Client.PropertyListConfigurationError.missingConfigurationValues
            }
            
            self.register(issuer: config.issuer,
                          clientId: config.clientId,
                          redirectUri: redirectUri,
                          scopes: config.scopes)
        }
        
        let issuer: URL
        let clientId: String
        let redirectUri: URL
        let scopes: String
        private(set) var migrationItems: [Keychain.Search.Result]?
        
        init(issuer: URL, clientId: String, redirectUri: URL, scopes: String) {
            self.issuer = issuer
            self.clientId = clientId
            self.redirectUri = redirectUri
            self.scopes = scopes
        }
        
        public var needsMigration: Bool {
            guard let regex = accountIdRegex,
                  let items = try? Keychain
                .Search(service: "")
                .list()
            else {
                return false
            }
            
            let results = items.filter({ searchResult in
                // swiftlint:disable empty_string
                guard searchResult.service == "",
                      regex.matches(in: searchResult.account, range: NSRange(location: 0, length: searchResult.account.count)).count == 1
                else {
                    return false
                }
                // swiftlint:enable empty_string
                return true
            })
                
            return !results.isEmpty
        }
        
        public func migrate() throws {
            guard let regex = accountIdRegex else {
                return
            }

            try Keychain
                .Search(service: "")
                .list()
                .filter({ searchResult in
                    regex.matches(in: searchResult.account,
                                  range: NSRange(location: 0, length: searchResult.account.count)).count == 1
                }).map({ searchResult in
                    let item = try searchResult.get()
                    return (searchResult, try decode(item.value))
                }).forEach({ (item: Keychain.Search.Result, oldModel: StateManager?) in
                    try importToken(item, from: oldModel)
                })
        }

        private func decode(_ data: Data) throws -> StateManager? {
            let archiver: NSKeyedUnarchiver
            if #available(iOS 11.0, tvOS 11.0, macCatalyst 13.1, macOS 10.13, watchOS 4.0, *) {
                archiver = try NSKeyedUnarchiver(forReadingFrom: data)
            } else {
                archiver = NSKeyedUnarchiver(forReadingWith: data)
            }
            
            archiver.requiresSecureCoding = false
            archiver.setClass(StateManager.self, forClassName: "OktaOidc.OktaOidcStateManager")
            archiver.setClass(StateManager.AuthState.self, forClassName: "OKTAuthState")
            archiver.setClass(StateManager.AuthState.self, forClassName: "OIDAuthState")
            archiver.setClass(StateManager.TokenResponse.self, forClassName: "OKTTokenResponse")
            archiver.setClass(StateManager.TokenResponse.self, forClassName: "OIDTokenResponse")
            archiver.setClass(StateManager.AuthorizationResponse.self, forClassName: "OKTAuthorizationResponse")
            archiver.setClass(StateManager.AuthorizationResponse.self, forClassName: "OIDAuthorizationResponse")
            
            defer { archiver.finishDecoding() }

            return try archiver.decodeTopLevelObject(of: StateManager.self,
                                                     forKey: NSKeyedArchiveRootObjectKey)
        }
        
        private func importToken(_ item: Keychain.Search.Result, from model: StateManager?) throws {
            guard let tokenResponse = model?.authState?.lastTokenResponse,
                  let tokenType = tokenResponse.tokenType,
                  let expiresIn = tokenResponse.accessTokenExpirationDate?.timeIntervalSinceNow,
                  let accessToken = tokenResponse.accessToken,
                  let scope = tokenResponse.scope
            else {
                return
            }
            
            let idToken: JWT?
            if let idTokenString = tokenResponse.idToken {
                idToken = try JWT(idTokenString)
            } else {
                idToken = nil
            }

            let configuration = OAuth2Client.Configuration(baseURL: issuer,
                                                           clientId: clientId,
                                                           scopes: scopes)
            let clientSettings: [String: String] = [
                "client_id": clientId,
                "redirect_uri": redirectUri.absoluteString,
                "scope": scope
            ]
            
            let issueDate = idToken?.issuedAt ?? Date()

            let token = Token(id: item.account,
                              issuedAt: issueDate,
                              tokenType: tokenType,
                              expiresIn: expiresIn,
                              accessToken: accessToken,
                              scope: scope,
                              refreshToken: tokenResponse.refreshToken,
                              idToken: idToken,
                              deviceSecret: nil,
                              context: Token.Context(configuration: configuration,
                                                     clientSettings: clientSettings))
            
            var security = Credential.Security.standard
            if let accessibility = item.accessibility {
                security.insert(.accessibility(accessibility), at: 0)
            }
            
            if let accessControl = item.accessControl {
                security.insert(.accessControlRef(accessControl), at: 0)
            }

            if let accessGroup = item.accessGroup {
                security.insert(.accessGroup(accessGroup), at: 0)
            }
            
            let credential = try Credential.store(token,
                                                  tags: ["migrated": "true"],
                                                  security: security)
            try item.delete()
            
            NotificationCenter.default.post(name: .credentialMigrated, object: credential)
        }
        
        @objc(_OIDCLegacyStateManager) class StateManager: NSObject, NSCoding {
            @objc let authState: AuthState?
            @objc let accessibility: String?

            func encode(with coder: NSCoder) {}

            required init?(coder: NSCoder) {
                authState = coder.decodeObject(forKey: "authState") as? AuthState
                accessibility = coder.decodeObject(forKey: "accessibility") as? String
            }

            @objc(_OIDCLegacyAuthState) class AuthState: NSObject, NSCoding {
                @objc let refreshToken: String?
                @objc let scope: String?
                @objc let lastTokenResponse: TokenResponse?
                @objc let lastAuthorizationResponse: AuthorizationResponse?

                func encode(with coder: NSCoder) {}

                required init?(coder: NSCoder) {
                    refreshToken = coder.decodeObject(forKey: "refreshToken") as? String
                    scope = coder.decodeObject(forKey: "scope") as? String
                    lastTokenResponse = coder.decodeObject(forKey: "lastTokenResponse") as? TokenResponse
                    lastAuthorizationResponse = coder.decodeObject(forKey: "lastAuthorizationResponse") as? AuthorizationResponse
                }
            }
            
            @objc(_OIDCLegacyTokenResponse) class TokenResponse: NSObject, NSCoding {
                @objc let accessToken: String?
                @objc let accessTokenExpirationDate: Date?
                @objc let tokenType: String?
                @objc let idToken: String?
                @objc let refreshToken: String?
                @objc let scope: String?
                @objc let additionalParameters: [String: String]?

                func encode(with coder: NSCoder) {}

                required init?(coder: NSCoder) {
                    accessToken = coder.decodeObject(forKey: "access_token") as? String
                    accessTokenExpirationDate = coder.decodeObject(forKey: "expires_in") as? Date
                    refreshToken = coder.decodeObject(forKey: "refresh_token") as? String
                    tokenType = coder.decodeObject(forKey: "token_type") as? String
                    idToken = coder.decodeObject(forKey: "id_token") as? String
                    scope = coder.decodeObject(forKey: "scope") as? String
                    additionalParameters = coder.decodeObject(forKey: "additionalParameters") as? [String: String]
                }
            }
            
            @objc(_OIDCLegacyAuthorizationResponse) class AuthorizationResponse: NSObject, NSCoding {
                @objc let authorizationCode: String?
                @objc let state: String?
                
                func encode(with coder: NSCoder) {}

                required init?(coder: NSCoder) {
                    state = coder.decodeObject(forKey: "state") as? String
                    authorizationCode = coder.decodeObject(forKey: "authorizationCode") as? String
                }
            }
        }
    }
}

#endif
