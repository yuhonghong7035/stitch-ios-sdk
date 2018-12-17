import Foundation
import XCTest
import MongoMobile
import MongoSwift
import StitchCoreSDK
@testable import StitchCoreRemoteMongoDBService
import StitchCoreSDKMocks
import StitchCoreLocalMongoDBService

class XCMongoMobileConfiguration: NSObject, XCTestObservation {
    // This init is called first thing as the test bundle starts up and before any test
    // initialization happens
    override init() {
        super.init()
        // We don't need to do any real work, other than register for callbacks
        // when the test suite progresses.
        // XCTestObservation keeps a strong reference to observers
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testBundleWillStart(_ testBundle: Bundle) {
        try? CoreLocalMongoDBService.shared.initialize()
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        CoreLocalMongoDBService.shared.close()
    }
}

class TestNetworkMonitor: NetworkMonitor {
    var state: NetworkState = .connected

    var networkStateListeners = [NetworkStateDelegate]()

    func add(networkStateDelegate listener: NetworkStateDelegate) {
        self.networkStateListeners.append(listener)
    }

    func remove(networkStateDelegate listener: NetworkStateDelegate) {
        if let index = self.networkStateListeners.firstIndex(where: { $0 === listener }) {
            self.networkStateListeners.remove(at: index)
        }
    }
}

class TestAuthMonitor: AuthMonitor {
    var isLoggedIn: Bool {
        return true
    }
}

class TestConflictHandler: ConflictHandler {
    typealias DocumentT = Document
    func resolveConflict(documentId: BSONValue,
                         localEvent: ChangeEvent<Document>,
                         remoteEvent: ChangeEvent<Document>) throws -> Document? {
        return remoteEvent.fullDocument
    }
}

class TestErrorListener: ErrorListener {
    func on(error: Error, forDocumentId documentId: BSONValue?) {
        XCTFail(error.localizedDescription)
    }
}

class TestEventDelegate: ChangeEventDelegate {
    typealias DocumentT = Document
    func onEvent(documentId: BSONValue,
                 event: ChangeEvent<Document>) {
    }
}

private class TestCaseDataSynchronizer: DataSynchronizer {
    private let deinitializingInstanceKey: String
    private let deinitializing: Bool

    init(deinitializing: Bool,
         instanceKey: String,
         coreRemoteMongoClient: CoreRemoteMongoClient,
         localClient: MongoClient) throws {
        self.deinitializing = deinitializing
        self.deinitializingInstanceKey = instanceKey

        let mockServiceClient = MockCoreStitchServiceClient.init()
        mockServiceClient.streamFunctionMock.doReturn(
            result: RawSSEStream.init(),
            forArg1: .any,
            forArg2: .any,
            forArg3: .any
        )

        try super.init(
            instanceKey: instanceKey,
            service: mockServiceClient,
            localClient: localClient,
            remoteClient: coreRemoteMongoClient,
            networkMonitor: TestNetworkMonitor(),
            authMonitor: TestAuthMonitor())
    }

    deinit {
        if deinitializing {
            try? self.localClient.db(
                DataSynchronizer
                    .localConfigDBName(withInstanceKey: deinitializingInstanceKey)
                ).drop()
        }
    }
}

class XCMongoMobileTestCase: XCTestCase {
    let dataDirectory = URL.init(string: "\(FileManager().currentDirectoryPath)/\("sync")")!
    lazy var appClientInfo = StitchAppClientInfo.init(clientAppID: instanceKey.oid,
                                                      dataDirectory: dataDirectory,
                                                      localAppName: instanceKey.oid,
                                                      localAppVersion: "1.0",
                                                      networkMonitor: TestNetworkMonitor(),
                                                      authMonitor: TestAuthMonitor())
    lazy var localClient: MongoClient = try! CoreLocalMongoDBService.shared.client(withAppInfo: appClientInfo)


    let routes = StitchAppRoutes.init(clientAppID: "foo").serviceRoutes
    let requestClient = MockStitchAuthRequestClient()
    final lazy var spyServiceClient = SpyCoreStitchServiceClient.init(requestClient: requestClient,
                                                                      routes: routes,
                                                                      serviceName: nil)

    private(set) var mockServiceClient: MockCoreStitchServiceClient!
    private(set) var coreRemoteMongoClient: CoreRemoteMongoClient!

    var lazyLock = DispatchSemaphore(value: 1)
    private var storedDataSynchronizer: DataSynchronizer!
    var dataSynchronizer: DataSynchronizer! {
        get {
            lazyLock.wait()
            defer { lazyLock.signal() }
            
            if storedDataSynchronizer == nil {
                storedDataSynchronizer = try! TestCaseDataSynchronizer.init(
                    deinitializing: true,
                    instanceKey: instanceKey.oid,
                    coreRemoteMongoClient: self.coreRemoteMongoClient,
                    localClient: localClient)
            }
            return storedDataSynchronizer
        }
        set {
            lazyLock.wait()
            defer { lazyLock.signal() }

            storedDataSynchronizer = newValue
        }
    }

    func replaceDataSynchronizer(
        deinitializing: Bool,
        withUndoDocuments undoDocuments: [Document] = []
    ) throws {
        // stop the existing data synchronizer for this test context
        dataSynchronizer.stop()

        // insert some documents into the undo collection to simulate a
        // failure case from which the data synchronizer should recover
        if !undoDocuments.isEmpty {
            try undoCollection().insertMany(undoDocuments)
        }

        // initialize a new data synchronizer
        dataSynchronizer = try! TestCaseDataSynchronizer.init(
            deinitializing: deinitializing,
            instanceKey: instanceKey.oid,
            coreRemoteMongoClient: self.coreRemoteMongoClient,
            localClient: localClient
        )

        // perform a no-op write so that we wait for the recovery pass to complete. This works
        // since the recovery routine write-locks all namespaces until recovery is done.
        _ = try dataSynchronizer.updateOne(
            filter: ["_id": "nonexistent"],
            update: ["$set": ["a": 1] as Document],
            options: nil,
            in: namespace
        )
    }

    func setPendingWrites(forDocumentId documentId: BSONValue,
                          event: ChangeEvent<Document>) throws {
        let nsConfig = dataSynchronizer.syncConfig[namespace]!
        var docConfig = nsConfig[documentId]!

        try docConfig.setSomePendingWrites(atTime: dataSynchronizer.logicalT, changeEvent: event)
    }

    private var _instanceKey = ObjectId()
    open var instanceKey: ObjectId {
        return _instanceKey
    }

    private var _namespace = MongoNamespace.init(databaseName: "db", collectionName: "coll")
    open var namespace: MongoNamespace {
        return _namespace
    }

    private var namespacesToBeTornDown = Set<MongoNamespace>()

    override func setUp() {
        mockServiceClient = MockCoreStitchServiceClient()
        coreRemoteMongoClient = try! CoreRemoteMongoClientFactory.shared.client(
            withService: mockServiceClient,
            withAppInfo: appClientInfo)
    }

    override func tearDown() {
        namespacesToBeTornDown.forEach {
            try? localClient.db($0.databaseName).drop()
        }
        localClient.close()
    }

    func remoteCollection(withSpy: Bool = false) throws -> CoreRemoteMongoCollection<Document> {
        return try self.remoteCollection(withSpy: withSpy, withType: Document.self)
    }

    func remoteCollection<T: Codable>(withSpy: Bool = false, withType type: T.Type) throws -> CoreRemoteMongoCollection<T> {
        return try self.remoteCollection(withSpy: withSpy, for: namespace, withType: type)
    }

    func remoteCollection(withSpy: Bool = false, for namespace: MongoNamespace) throws -> CoreRemoteMongoCollection<Document> {
        return try remoteCollection(withSpy: withSpy, for: namespace, withType: Document.self)
    }

    func remoteCollection<T: Codable>(withSpy: Bool = false,
                                      for namespace: MongoNamespace,
                                      withType type: T.Type) throws -> CoreRemoteMongoCollection<T> {
        return coreRemoteMongoClient.db(namespace.databaseName)
            .collection(namespace.collectionName,
                        withCollectionType: type)
    }

    func isUndoCollectionEmpty() throws -> Bool {
        return try undoCollection().count() == 0
    }

    func undoCollection() throws -> MongoCollection<Document> {
        return try dataSynchronizer.undoCollection(for: namespace)
    }

    func localCollection() throws -> MongoCollection<Document> {
        return try localCollection(for: MongoNamespace.init(
            databaseName: DataSynchronizer.localUserDBName(withInstanceKey: instanceKey.oid, for: namespace),
            collectionName: namespace.collectionName
        ))
    }

    func localCollection(for namespace: MongoNamespace) throws -> MongoCollection<Document> {
        self.namespacesToBeTornDown.insert(namespace)
        return try localClient
            .db(namespace.databaseName)
            .collection(namespace.collectionName, withType: Document.self)
    }
}