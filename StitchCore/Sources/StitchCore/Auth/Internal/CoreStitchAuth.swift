import Foundation
import ExtendedJSON

/**
 * The core class that holds and manages Stitch user authentication state. This class is meant to be inherited.
 *
 * - important: synchronization in this class happens around the authInfo and currentUser objects such that
 *              access to them is 1. always atomic and 2. queued to prevent excess token refreshes.
 *
 * - typeparameters
 *     - TStitchUser: The underlying user type for this `CoreStitchAuth`, which must conform to `CoreStitchUser`.
 */
open class CoreStitchAuth<TStitchUser> where TStitchUser: CoreStitchUser {
    // MARK: Stored Properties

    /**
     * The underlying authentication state of this `CoreStitchAuth`
     */
    internal var authStateHolder = AuthStateHolder()

    /**
     * The `Storage` object indicating where authentication information should be persisted.
     */
    internal var storage: Storage

    /**
     * The thread that will proactively refresh the access token at fixed intervals.
     */
    private var refresherThread: Thread?

    /**
     * A `TStitchUser` object that represents the currently authenticated user, or `nil` if no one is authenticated.
     */
    private var currentUser: TStitchUser?

    /**
     * The `StitchRequestClient` used by the `CoreStitchAuth` to make requests to the Stitch server.
     */
    public let requestClient: StitchRequestClient

    /**
     * The `StitchAuthRoutes` object representing the authentication API routes of the Stitch server for the current
     * app.
     */
    public let authRoutes: StitchAuthRoutes

    /**
     * The getter and setter for authentication state, as represented by an `AuthInfo` object.
     */
    public internal(set) var authInfo: AuthInfo? {
        get {
            return authStateHolder.authInfo
        }
        set {
            authStateHolder.authInfo = newValue
        }
    }

    // MARK: Initialization

    /**
     * Initializes the `CoreStitchAuth` with a request client, authentication API routes, and a `Storage` indicating
     * where the `CoreStitchAuth` should persist authentication information. This initializer will start a `Thread`
     * that will proactively refresh the access token at fixed intervals.
     */
    public init(requestClient: StitchRequestClient,
                authRoutes: StitchAuthRoutes,
                storage: Storage) throws {
        self.requestClient = requestClient
        self.authRoutes = authRoutes
        self.storage = storage

        self.authStateHolder.authInfo = try StoreAuthInfo.read(fromStorage: storage)

        if let authInfo = authInfo {
            // this implies other properties we are interested should be set
            self.currentUser =
                self.userFactory
                    .makeUser(withId: authInfo.userId,
                              withLoggedInProviderType: authInfo.loggedInProviderType,
                              withLoggedInProviderName: authInfo.loggedInProviderName,
                              withUserProfile: authInfo.userProfile)
        }

        self.refresherThread = Thread.init(target: self,
                                           selector: #selector(doRunAccessTokenRefresher),
                                           object: nil)

        self.refresherThread?.start()
    }

    /**
     * Instantiates an access token refresher and begins its infinite loop.
     *
     * - important: Should only be called on a standalone non-main thread.
     */
    @objc private func doRunAccessTokenRefresher() {
        AccessTokenRefresher<TStitchUser>(authRef: self).run()
    }

    /**
     * Cancels the access token refresher thread.
     */
    deinit {
        refresherThread?.cancel()
    }

    // MARK: Unimplemented Methods and Properties

    /**
     * Should return an `AnyStitchUserFactory` object, capable of constructing users of the `TStitchUser` type.
     */
    open var userFactory: AnyStitchUserFactory<TStitchUser> {
        fatalError("not implemented")
    }

    /**
     * A method that will be called whenever an authentication event (logging in, logging out, linking) occurs.
     */
    open func onAuthEvent() {
        fatalError("not implemented")
    }

    /**
     * A method that should return a BSON Document containing information about the current device.
     */
    open var deviceInfo: Document {
        fatalError("deviceInfo must be implemented")
    }

    // MARK: Computed Properties

    /**
     * Whether or not a user is currently logged in.
     */
    public var isLoggedIn: Bool {
        // swiftlint:disable force_try
        return try! sync(self) {
            // swiftlint:enable force_try
            self.authStateHolder.isLoggedIn
        }
    }

    /**
     * The currently authenticated user as a `TStitchUser`, or `nil` if no user is currently authenticated.
     */
    public var user: TStitchUser? {
        // swiftlint:disable force_try
        return try! sync(self) {
            // swiftlint:enable force_try
            self.currentUser
        }
    }

    /**
     * Returns whether or not the current authentication state has a meaningful device id.
     */
    public var hasDeviceId: Bool {
        return authInfo?.deviceId != nil
            && authInfo?.deviceId != ""
            && authInfo?.deviceId != "000000000000000000000000"
    }

    /**
     * Returns the currently authenticated user's device id, or `nil` is no user is currently authenticated, or if the
     * device id does not exist.
     */
    public var deviceId: String? {
        return authInfo?.deviceId
    }

    // MARK: Authentication Actions

    /**
     * Authenticates the `CoreStitchAuth` using the provided `StitchCredential. Blocks the current thread until the
     * request is completed.
     */
    public func loginWithCredentialBlocking(withCredential credential: StitchCredential) throws -> TStitchUser {
        return try sync(self) {
            if !isLoggedIn {
                return try doLogin(withCredential: credential, asLinkRequest: false)
            }

            if credential.providerCapabilities.reusesExistingSession {
                if type(of: credential).providerType == currentUser?.loggedInProviderType {
                    return self.currentUser!
                }
            }

            try logoutBlocking()
            return try doLogin(withCredential: credential, asLinkRequest: false)
        }
    }

    /**
     * Links the currently logged in user with a new identity represented by the provided `StitchCredential. Blocks the
     * current thread until the request is completed.
     */
    public func linkUserWithCredentialBlocking(withUser user: TStitchUser,
                                               withCredential credential: StitchCredential) throws -> TStitchUser {
        return try sync(self) {
            guard let currentUser = self.currentUser,
                user == currentUser else {
                throw StitchError.requestError(
                    withMessage: "user no longer valid; please try again with a new user from StitchAuth.user")
            }

            return try self.doLogin(withCredential: credential, asLinkRequest: true)
        }
    }

    /**
     * Logs out the current user, and clears authentication state from this `CoreStitchAuth` as well as underlying
     * storage. Blocks the current thread until the request is completed. If the logout request fails, this method will
     * still attempt to clear local authentication state. This method will only throw if clearing authentication state
     * fails.
     */
    public func logoutBlocking() throws {
        guard isLoggedIn else { return }

        do {
            try doLogout()
        } catch StitchError.serviceError {
        } catch let err {
            try clearAuth()
            throw err
        }

        try clearAuth()
    }

    // MARK: Internal Methods

    /**
     * Performs the logic of logging in this `CoreStitchAuth` as a new user with the provided credential. Can also
     * perform a user link if the `asLinkRequest` parameter is true.
     *
     * - important: Callers of `doLogin` should be synchronized before calling in.
     */
    private func doLogin(withCredential credential: StitchCredential, asLinkRequest: Bool) throws -> TStitchUser {
        let response = try self.doLoginRequest(withCredential: credential,
                                               asLinkRequest: asLinkRequest)
        let user = try self.processLoginResponse(withCredential: credential,
                                                 forResponse: response)

        onAuthEvent()

        return user
    }

    /**
     * Enum representing the keys for additional auth options that may be attached to the body of the authentication
     * request sent to the Stitch server on login or link.
     */
    private enum AuthKey: String {
        case options
        case device
    }

    /**
     * Attaches authentication options to the BSON document passed in as the `authBody` parameter. Necessary for the
     * the login request.
     */
    private func attachAuthOptions(authBody: inout Document) {
        authBody[AuthKey.options.rawValue] = [
            AuthKey.device.rawValue: deviceInfo
            ] as Document
    }

    /**
     * Performs the login request against the Stitch server. If `asLinkRequest` is true, a link request is performed
     * instead.
     */
    private func doLoginRequest(withCredential credential: StitchCredential,
                                asLinkRequest: Bool) throws -> Response {
        let reqBuilder = StitchDocRequestBuilderImpl {
            $0.method = .post
            if asLinkRequest {
                $0.path = authRoutes.authProviderLinkRoute(withProviderName: credential.providerName)
            } else {
                $0.path = authRoutes.authProviderLoginRoute(withProviderName: credential.providerName)
            }

            var body = credential.material
            self.attachAuthOptions(authBody: &body)
            $0.document = body
        }

        if !asLinkRequest {
            return try self.requestClient.doJSONRequestRaw(reqBuilder.build())
        }

        return try doAuthenticatedJSONRequestRaw(try StitchAuthDocRequestBuilderImpl {
            $0.body = reqBuilder.body
            $0.path = reqBuilder.path
            $0.headers = reqBuilder.headers
            $0.method = reqBuilder.method
            $0.document = reqBuilder.document
        }.build())
    }

    /**
     * Processes the response of the login/link request, setting the authentication state if appropriate, and
     * requesting the user profile in a separate request.
     */
    private func processLoginResponse(withCredential credential: StitchCredential,
                                      forResponse response: Response) throws -> TStitchUser {
        guard let body = response.body else {
            throw StitchErrorCode.missingAuthReq
        }

        let decodedInfo = try JSONDecoder().decode(APIAuthInfoImpl.self, from: body)

        // Provisionally set so we can make a profile request
        if self.authInfo == nil {
            self.authStateHolder.apiAuthInfo = decodedInfo
        } else {
            self.authInfo =
                self.authInfo?.merge(withPartialInfo: decodedInfo,
                                     fromOldInfo: self.authInfo!)
        }

        var profile: StitchUserProfile!
        do {
            profile = try doGetUserProfile()
        } catch let err {
            try self.logoutBlocking()
            throw err
        }

        // Finally set the info and user
        self.authInfo = StoreAuthInfo.init(
            withAPIAuthInfo: decodedInfo,
            withExtendedAuthInfo: ExtendedAuthInfoImpl.init(loggedInProviderType: type(of: credential).providerType,
                                                            loggedInProviderName: credential.providerName,
                                                            userProfile: profile)
        )

        try self.authInfo?.write(toStorage: &storage)
        self.currentUser =
            userFactory
                .makeUser(
                    withId: authInfo!.userId,
                    withLoggedInProviderType: type(of: credential).providerType,
                    withLoggedInProviderName: credential.providerName,
                    withUserProfile: profile)
        return self.currentUser!
    }

    /**
     * Performs a request against the Stitch server to get the currently authenticated user's profile.
     */
    private func doGetUserProfile() throws -> StitchUserProfile {
        let response = try doAuthenticatedRequest(StitchAuthRequestBuilderImpl {
            $0.method = .get
            $0.path = self.authRoutes.profileRoute
        }.build())

        let decodedProfile = try JSONDecoder.init().decode(APICoreUserProfileImpl.self,
                                                           from: response.body!)

        return StitchUserProfileImpl.init(userType: decodedProfile.userType,
                                          identities: decodedProfile.identities,
                                          data: decodedProfile.data)
    }

    /**
     * Performs a logout request against the Stitch server.
     */
    @discardableResult
    private func doLogout() throws -> Response {
        return try self.doAuthenticatedRequest(StitchAuthRequestBuilderImpl {
            $0.useRefreshToken = true
            $0.path = authRoutes.sessionRoute
            $0.method = .delete
        }.build())
    }

    /**
     * Clears the `CoreStitchAuth`'s authentication state, as well as associated authentication state in underlying
     * storage.
     */
    internal func clearAuth() throws {
        try sync(self) {
            guard self.isLoggedIn else { return }
            self.authStateHolder.clearState()
            StoreAuthInfo.clear(storage: &storage)
            currentUser = nil
            onAuthEvent()
        }
    }
}
