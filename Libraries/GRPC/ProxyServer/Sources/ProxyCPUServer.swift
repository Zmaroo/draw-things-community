import BinaryResources
import Crypto
import DataModels
import Foundation
import GRPCControlPanelModels
import GRPCCore
import GRPCImageServiceModels
import GRPCNIOTransportHTTP2
import Logging
import ModelZoo

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public enum ProxyTaskPriority: Sendable {
  case real
  case high
  case low
  case background
}

struct WorkTask {
  var priority: ProxyTaskPriority
  var request: ImageGenerationRequest
  var metadata: Metadata
  var responseWriter: RPCWriter<ImageGenerationResponse>
  var completion: @Sendable (Result<Metadata, Error>) -> Void
  var heartbeat: Task<Void, Never>
  var creationTimestamp: Date
  var model: String
  var payload: JWTPayload
}

public struct Worker {
  var id: String
  var primaryPriority: ProxyTaskPriority
  public let client: ProxyGPUClientWrapper
  private let logger = Logger(label: "com.draw-things.image-generation-proxy-service")
  enum WorkerError: Error {
    case invalidNioClient
  }
  public init(
    id: String, client: ProxyGPUClientWrapper, primaryPriority: ProxyTaskPriority
  ) {
    self.id = id
    self.client = client
    self.primaryPriority = primaryPriority
  }
}

extension Worker {
  func executeTask(
    _ task: WorkTask, proxyMessageSigner: ProxyMessageSigner, throttleQueueTimeoutSeconds: Int
  ) async throws {
    logger.info(
      "Worker \(id) primaryPriority:\(primaryPriority) starting task  (Priority: \(task.priority))"
    )
    let taskQueueingTimeMs = Date().timeIntervalSince(task.creationTimestamp) * 1000
    logger.info(
      "Task queueing time: \(taskQueueingTimeMs)ms, (Priority: \(task.priority)), userId: \(task.payload.userId as Any), generation id: \(task.payload.generationId as Any)"
    )
    defer { task.heartbeat.cancel() }

    // Check if task from throttle queue is over 1 hour old, reject if so (except boost tasks)
    if task.priority == .background && task.payload.consumableType != .boost {
      let taskAge = Date().timeIntervalSince(task.creationTimestamp)
      if taskAge > Double(throttleQueueTimeoutSeconds) {
        let errorMessage = "Task rejected: enqueue time exceeded 1 hour (\(Int(taskAge))s)"
        logger.info(
          "user: \(task.payload.userId as Any), \(errorMessage) (Priority: \(task.priority))")
        // intentionally abort task from throttle queue over 1 hour
        task.completion(.failure(RPCError(code: .aborted, message: errorMessage)))
        return
      }
    }

    do {
      guard let client = client.client else {
        logger.error("Worker \(id) task failed: invalid NIO client")
        throw WorkerError.invalidNioClient
      }
      let logger = logger
      let taskExecuteStartTimestamp = Date()
      let workerId = id
      let callTask = Task {
        try await client.generateImage(task.request, metadata: task.metadata) { response in
          var numberOfImages = 0
          for try await streamResponse in response.messages {
            if !streamResponse.generatedImages.isEmpty {
              numberOfImages += streamResponse.generatedImages.count
            }
            do {
              try await task.responseWriter.write(streamResponse)
              logger.debug("forward response: \(streamResponse)")
            } catch {
              logger.error("Worker: \(workerId), forward response error \(error)")
              task.completion(.failure(error))
              throw error
            }
          }
          return numberOfImages
        }
      }
      let numberOfImages = try await callTask.value
      if numberOfImages > 0 {
        let totalTimeMs = Date().timeIntervalSince(task.creationTimestamp) * 1000
        let totalExecutionTimeMs = Date().timeIntervalSince(taskExecuteStartTimestamp) * 1000
        logger.info(
          "Task total time: \(totalTimeMs)ms, Task execution time: \(totalExecutionTimeMs)ms, (Priority: \(task.priority))"
        )
        logger.info(
          "Succeed: {\"model\": \"\(task.model)\", \"userid\": \"\(task.payload.userId as Any)\",  \"generationId\": \"\(task.payload.generationId as Any)\", \"images\":\(numberOfImages)}"
        )
      }
      let isTaskSuccessful = numberOfImages > 0

      if task.payload.consumableType == .boost, let amount = task.payload.amount,
        let generationId = task.payload.generationId
      {
        await proxyMessageSigner.completeBoost(
          action: isTaskSuccessful ? .complete : .cancel, generationId: generationId,
          amount: amount,
          logger: logger)
      }
      task.completion(.success([:]))

      logger.info(
        "Worker \(id) completed, generationId: \(task.payload.generationId as Any), successfully (Priority: \(task.priority))"
      )

    } catch {
      if task.payload.consumableType == .boost, let amount = task.payload.amount,
        let generationId = task.payload.generationId
      {
        await proxyMessageSigner.completeBoost(
          action: .cancel, generationId: generationId, amount: amount,
          logger: logger)
      }
      logger.error("Worker \(id) task failed with error: \(error) (Priority: \(task.priority))")
      task.completion(.failure(error))
      throw error
    }
  }

}

actor TaskQueue {
  private var highPriorityTasks: [WorkTask] = []
  private var lowPriorityTasks: [WorkTask] = []
  private var realPriorityTasks: [WorkTask] = []
  private var backgroundPriorityTasks: [WorkTask] = []
  private var pendingRemoveWorkerId = Set<String>()
  private var workers: [String: Worker]
  private var busyWorkerIDs: Set<String> = []
  private let logger: Logger
  var workerIds: [String] {
    return Array(workers.keys)
  }

  // Shared availability stream
  private let workerAvailabilityStream: AsyncStream<Worker>
  private let availabilityContinuation: AsyncStream<Worker>.Continuation

  init(workers: [Worker], logger: Logger) {
    self.logger = logger
    self.workers = Dictionary(uniqueKeysWithValues: workers.map { ($0.id, $0) })

    (workerAvailabilityStream, availabilityContinuation) = AsyncStream.makeStream(of: Worker.self)
    for worker in workers {
      availabilityContinuation.yield(worker)
    }
  }

  var availableWorkerCount: Int {
    return workers.count - busyWorkerIDs.count
  }

  func nextWorker() async -> Worker? {
    for await worker in workerAvailabilityStream {
      if workers[worker.id] != nil {
        busyWorkerIDs.insert(worker.id)
        return worker
      } else {
        logger.info("skip removed worker:\(worker) from workerAvailabilityStream")
      }
    }
    return nil
  }

  func nextTaskForWorker(
    _ worker: Worker, highThreshold: Int, communityThreshold: Int, taskLoopBreakoutSeconds: Int
  ) async
    -> WorkTask?
  {
    let startTime = Date()
    let timeout: TimeInterval = TimeInterval(taskLoopBreakoutSeconds)
    // When free workers are very low, only process real and high priority tasks
    while availableWorkerCount < highThreshold && Date().timeIntervalSince(startTime) < timeout {
      if let task = realPriorityTasks.first {
        realPriorityTasks.removeFirst()
        return task
      } else if let task = highPriorityTasks.first {
        highPriorityTasks.removeFirst()
        return task
      } else if availableWorkerCount >= communityThreshold {
        if let task = lowPriorityTasks.first {
          lowPriorityTasks.removeFirst()
          return task
        }
      }
      do {
        try await Task.sleep(for: .milliseconds(5))
      } catch {
        logger.error("Task.sleep failed with error: \(error)")
        continue
      }
    }

    if Date().timeIntervalSince(startTime) >= timeout {
      logger.info(
        "Throttling loop timed out after 30s. availableWorkerCount:\(availableWorkerCount), communityThreshold:\(communityThreshold), availableWorkerCount:\(availableWorkerCount)."
      )
    }

    // Check worker's primary priority queue first
    switch worker.primaryPriority {
    case .real:
      if let task = realPriorityTasks.first {
        realPriorityTasks.removeFirst()
        return task
      }
    case .high:
      if let task = highPriorityTasks.first {
        highPriorityTasks.removeFirst()
        return task
      }
    case .low:
      if let task = lowPriorityTasks.first {
        lowPriorityTasks.removeFirst()
        return task
      }
    case .background:
      if let task = backgroundPriorityTasks.first {
        backgroundPriorityTasks.removeFirst()
        return task
      }
    }

    // If primary queue is empty, check other queues in priority order
    if let task = realPriorityTasks.first {
      realPriorityTasks.removeFirst()
      return task
    }
    if let task = highPriorityTasks.first {
      highPriorityTasks.removeFirst()
      return task
    }
    if let task = lowPriorityTasks.first {
      lowPriorityTasks.removeFirst()
      return task
    }
    if let task = backgroundPriorityTasks.first {
      backgroundPriorityTasks.removeFirst()
      return task
    }

    return nil
  }

  func addTask(_ task: WorkTask) {
    switch task.priority {
    case .real:
      logger.info("realPriorityTasks append task \(task.priority)")
      realPriorityTasks.append(task)
    case .high:
      logger.info("highPriorityTasks append task \(task.priority)")
      highPriorityTasks.append(task)
    case .low:
      logger.info("lowPriorityTasks append task \(task.priority)")
      lowPriorityTasks.append(task)
    case .background:
      logger.info("backgroundPriorityTasks append task \(task.priority)")
      backgroundPriorityTasks.append(task)
    }
  }

  func returnWorker(_ worker: Worker) async {
    guard workers[worker.id] != nil else {
      logger.error("worker:\(worker) is removed, can not be added to worker stream")
      busyWorkerIDs.remove(worker.id)
      return
    }
    logger.info("add worker:\(worker) back to worker stream")
    busyWorkerIDs.remove(worker.id)
    availabilityContinuation.yield(worker)
  }

  func addWorker(_ worker: Worker) async {
    guard worker.client.client != nil else {
      logger.error(
        "can add worker:\(worker) to worker TaskQueue with invalid nioclient connection")
      return
    }
    let alreadyExists = workers[worker.id] != nil
    workers[worker.id] = worker
    guard !alreadyExists else {
      logger.info("worker:\(worker) already exists in workers, skip adding")
      return
    }
    availabilityContinuation.yield(worker)
    logger.info("add worker:\(worker) to worker TaskQueue and stream")
  }

  func removeWorkerById(_ name: String) async {
    guard let worker = workers[name] else {
      logger.error("failed to find worker based on name \(name)")
      return
    }
    try? worker.client.disconnect()
    workers[worker.id] = nil
    busyWorkerIDs.remove(worker.id)
    logger.info("remove worker:\(worker) from worker TaskQueue")
  }

  deinit {
    for worker in workers.values {
      try? worker.client.disconnect()
    }
    availabilityContinuation.finish()
  }
}

public actor ControlConfigs {
  public private(set) var throttlePolicy = [String: Int]()
  public private(set) var publicKeyPEM: String
  public private(set) var modelListPath: String
  public private(set) var computeUnitPerBoost: Int = 60000
  private var nonces = Set<String>()
  private let logger: Logger
  private var nonceSizeLimit: Int
  private var sharedSecret: String?
  private var computeUnitPolicy = [String: Int]()
  private var expirationTimestamp: Date?
  enum ControlConfigsError: Error {
    case updatePublicKeyFailed(message: String)
  }

  init(
    throttlePolicy: [String: Int], publicKeyPEM: String, logger: Logger, modelListPath: String,
    nonceSizeLimit: Int
  ) {
    self.throttlePolicy = throttlePolicy
    self.publicKeyPEM = publicKeyPEM
    self.logger = logger
    self.modelListPath = modelListPath
    self.nonceSizeLimit = nonceSizeLimit
  }

  func addProcessedNonce(_ nonce: String) async {
    guard !nonces.contains(nonce) else { return }
    if nonces.count >= nonceSizeLimit {
      if let randomElement = nonces.randomElement() {
        nonces.remove(randomElement)
      }
    }

    nonces.insert(nonce)
    logger.info("ControlConfigs add processed nonce:\(nonce)")
  }

  func getComputeUnitPolicyAndExpirationTimestamp() async -> ([String: Int], Date?) {
    return (computeUnitPolicy, expirationTimestamp)
  }

  func isUsedNonce(_ nonce: String) async -> Bool {
    nonces.contains(nonce)
  }

  func isSharedSecretValid(_ sharedSecret: String) async -> Bool {
    guard let configuredSecret = self.sharedSecret else {
      return false
    }
    return configuredSecret == sharedSecret
  }

  func updateThrottlePolicy(newPolicies: [String: Int]) async {
    for (key, value) in newPolicies {
      throttlePolicy[key] = value
    }
  }

  func updateComputeUnitPolicyAndExpirationTimestamp(newPolicies: [String: Int], _ timestamp: Date)
    async
  {
    for (key, value) in newPolicies {
      computeUnitPolicy[key] = value
    }
    expirationTimestamp = timestamp
  }

  func updatePublicKeyPEM() async throws {
    guard let url = URL(string: "https://api.drawthings.ai/key") else {
      logger.error("ControlConfigs failed to update Pem, invalid url")
      return
    }
    let (data, response) = try await URLSession.shared.data(from: url)
    if let string = String(data: data, encoding: .utf8) {
      publicKeyPEM = string
      logger.info("ControlConfigs update public Pem as:\(string)")
    } else {
      logger.error("ControlConfigs failed to update Pem, response:\(response))")
    }
  }

  func updateSharedSecret() async -> String {
    func generatePassword() -> String {
      // Avoiding confusing characters like 1, l, I, i, 0, O
      let allowedChars = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"
      var password = ""
      // Ensure at least one number and one letter
      let numbers = "23456789"
      let letters = "ABCDEFGHJKMNPQRSTUVWXYZ"
      // Add one random number
      password.append(numbers.randomElement()!)
      // Add one random letter
      password.append(letters.randomElement()!)
      // Fill the remaining 10 characters
      for _ in 0..<10 {
        password.append(allowedChars.randomElement()!)
      }
      // Shuffle the password to randomize position of guaranteed number and letter
      return String(password.shuffled())
    }
    let sharedSecret = generatePassword()
    self.sharedSecret = sharedSecret
    logger.info("ControlConfigs update shared Secret")
    return sharedSecret
  }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class ControlPanelProxyService: GRPCControlPanelModels.ControlPanelService
    .SimpleServiceProtocol
{
  private let taskQueue: TaskQueue
  private let controlConfigs: ControlConfigs
  private let proxyMessageSigner: ProxyMessageSigner
  private let logger: Logger
  enum ControlPanelError: Error {
    case gpuConnectFailed(message: String)
    case nioClientFailed(message: String)
    case removeGPUFailed(message: String)
  }

  init(
    taskQueue: TaskQueue, controlConfigs: ControlConfigs, logger: Logger,
    proxyMessageSigner: ProxyMessageSigner
  ) {
    self.taskQueue = taskQueue
    self.controlConfigs = controlConfigs
    self.logger = logger
    self.proxyMessageSigner = proxyMessageSigner
  }

  func manageGPUServer(
    request: GRPCControlPanelModels.GPUServerRequest, context: ServerContext
  ) async throws -> GRPCControlPanelModels.GPUServerResponse {
    let gpuServerName = "\(request.serverConfig.address):\(request.serverConfig.port)"
    switch request.operation {
    case .add:
      self.logger.info(
        "Worker connecting server: \(gpuServerName). Worker focus on \(request.serverConfig.isHighPriority ? ProxyTaskPriority.high : ProxyTaskPriority.low) priority Task"
      )
      let client = ProxyGPUClientWrapper(deviceName: gpuServerName)
      do {
        try client.connect(
          host: request.serverConfig.address, port: Int(request.serverConfig.port))
        let result = await client.echo()
        self.logger.info("server: \(gpuServerName). echo \(result)")
        if let _ = client.client, result.0 {
          let worker = Worker(
            id: gpuServerName, client: client,
            primaryPriority: request.serverConfig.isHighPriority ? .high : .low)
          await taskQueue.addWorker(worker)
          let workersId = await taskQueue.workerIds
          let response = GPUServerResponse.with {
            $0.message =
              "added GPU \(gpuServerName) into workers stream, current workers:\(workersId)"
          }
          return response
        } else {
          try? client.disconnect()
          throw ControlPanelError.nioClientFailed(
            message: "fail to create nio client for \(gpuServerName)")
        }
      } catch (let error) {
        throw ControlPanelError.gpuConnectFailed(
          message: "fail to connect GPU \(gpuServerName) error:\(error)")
      }
    case .remove:
      await taskQueue.removeWorkerById(gpuServerName)
      let workersId = await taskQueue.workerIds
      let response = GPUServerResponse.with {
        $0.message =
          "remove GPU \(gpuServerName) from taskCoordinator, current workers:\(workersId)"
      }
      return response
    case .unspecified, .UNRECOGNIZED(_):
      return GPUServerResponse.with {
        $0.message = "No operation specified"
      }
    }
  }

  func updateModelList(
    request: GRPCControlPanelModels.UpdateModelListRequest, context: ServerContext
  ) async throws -> GRPCControlPanelModels.UpdateModelListResponse {
    let fileList = request.files.joined(separator: "\n")
    // TODO: The path is problematic.
    let internalFilePath = await controlConfigs.modelListPath
    try? fileList.write(
      to: URL(fileURLWithPath: internalFilePath),
      atomically: true,
      encoding: .utf8)
    self.logger.info(
      "update model list to file: \(internalFilePath) with \(request.files.count) models")

    let response = UpdateModelListResponse.with {
      $0.message = "update model-list file with \(request.files.count) models"
    }
    return response
  }

  func updateThrottlingConfig(
    request: GRPCControlPanelModels.ThrottlingRequest, context: ServerContext
  ) async throws -> GRPCControlPanelModels.ThrottlingResponse {
    await controlConfigs.updateThrottlePolicy(
      newPolicies: request.limitConfig.mapValues { Int($0) })
    let currentThrottlePolicies = await controlConfigs.throttlePolicy
    self.logger.info(
      "Update throttling for \(request.limitConfig), current throttling policies are \(currentThrottlePolicies)"
    )
    let response = ThrottlingResponse.with {
      $0.message =
        "Update throttling for \(request.limitConfig), current throttling policies are \(currentThrottlePolicies)"
    }
    return response
  }

  func updatePem(
    request: GRPCControlPanelModels.UpdatePemRequest, context: ServerContext
  ) async throws -> GRPCControlPanelModels.UpdatePemResponse {
    try await controlConfigs.updatePublicKeyPEM()
    let pem = await controlConfigs.publicKeyPEM
    let response = UpdatePemResponse.with {
      $0.message = "Update proxy pem as:\n \(pem)"
    }
    return response
  }

  func updateSharedSecret(request: UpdateSharedSecretRequest, context: ServerContext)
    async throws -> UpdateSharedSecretResponse
  {
    let sharedSecret = await controlConfigs.updateSharedSecret()
    let response = UpdateSharedSecretResponse.with {
      $0.message = "Update proxy shared secret as:\n \(sharedSecret)"
    }
    return response
  }

  func updatePrivateKey(request: UpdatePrivateKeyRequest, context: ServerContext)
    async throws -> UpdatePrivateKeyResponse
  {
    await proxyMessageSigner.reloadKeys()
    self.logger.info(
      "regenerate proxy private key pairs"
    )

    let publicKeyPEM = await proxyMessageSigner.getPublicKey()
    let response = UpdatePrivateKeyResponse.with {
      $0.message = "Update proxy private keys, current public key is: \(publicKeyPEM as Any)"
    }
    return response
  }

  func updateComputeUnit(
    request: GRPCControlPanelModels.UpdateComputeUnitRequest,
    context: ServerContext
  ) async throws -> GRPCControlPanelModels.UpdateComputeUnitResponse {
    // Get current state
    let (currentComputeUnitPolicies, currentExpirationTimestamp) =
      await controlConfigs.getComputeUnitPolicyAndExpirationTimestamp()
    let currentExpirationStr =
      currentExpirationTimestamp.map { "expiration: \($0)" } ?? "no expiration"

    // Validate expiration timestamp first
    let currentTime = Int64(Date().timeIntervalSince1970)

    let logMessage: String
    let response: UpdateComputeUnitResponse
    let newExpirationTimestamp = request.expirationTimestamp
    if newExpirationTimestamp > currentTime {
      self.logger.info(
        "Current compute unit policies: \(currentComputeUnitPolicies), \(currentExpirationStr)")

      // Update with new policies and timestamp
      await controlConfigs.updateComputeUnitPolicyAndExpirationTimestamp(
        newPolicies: request.cuConfig.mapValues { Int($0) },
        Date(timeIntervalSince1970: TimeInterval(newExpirationTimestamp)))

      let (updatedComputeUnitPolicies, updatedExpirationTimestamp) =
        await controlConfigs.getComputeUnitPolicyAndExpirationTimestamp()

      logMessage =
        "Updated compute unit policies to \(updatedComputeUnitPolicies), timestamp: \(updatedExpirationTimestamp as Any)"

      response = UpdateComputeUnitResponse.with {
        $0.message = logMessage
      }
    } else {
      // Invalid timestamp - skip update and report current state
      logMessage =
        "Invalid expiration timestamp \(request.expirationTimestamp) (must be in the future). Current compute unit policies: \(currentComputeUnitPolicies), \(currentExpirationStr)"

      response = UpdateComputeUnitResponse.with {
        $0.message = logMessage
      }
    }

    self.logger.info("\(logMessage)")
    return response
  }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
private actor WorkerHealthState {
  private var failureCounts: [String: Int] = [:]
  private let maxFailureCount: Int

  init(maxFailureCount: Int) {
    self.maxFailureCount = maxFailureCount
  }

  func markSuccess(for workerID: String) {
    failureCounts[workerID] = 0
  }

  func recordFailure(for workerID: String) -> (count: Int, shouldRemove: Bool) {
    let count = failureCounts[workerID, default: 0] + 1
    failureCounts[workerID] = count
    return (count, count >= maxFailureCount)
  }

  func clearFailure(for workerID: String) {
    failureCounts.removeValue(forKey: workerID)
  }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class ImageGenerationProxyService: ImageGenerationService.ServiceProtocol {

  private let taskQueue: TaskQueue
  private let logger: Logger
  private let controlConfigs: ControlConfigs
  private let healthCheckTask: Task<Void, Never>?
  private let proxyMessageSigner: ProxyMessageSigner
  private let workerHealthState: WorkerHealthState
  private let maxFailureCount: Int

  init(
    taskQueue: TaskQueue, controlConfigs: ControlConfigs, logger: Logger, healthCheck: Bool,
    proxyMessageSigner: ProxyMessageSigner, maxFailureCount: Int = 3
  ) {
    self.taskQueue = taskQueue
    self.logger = logger
    self.controlConfigs = controlConfigs
    self.proxyMessageSigner = proxyMessageSigner
    self.maxFailureCount = maxFailureCount
    self.workerHealthState = WorkerHealthState(maxFailureCount: maxFailureCount)
    self.healthCheckTask =
      healthCheck
      ? Self.makeHealthCheckTask(
        taskQueue: taskQueue,
        logger: logger,
        workerHealthState: self.workerHealthState,
        maxFailureCount: maxFailureCount
      ) : nil
  }

  private static func makeHealthCheckTask(
    taskQueue: TaskQueue,
    logger: Logger,
    workerHealthState: WorkerHealthState,
    maxFailureCount: Int
  ) -> Task<Void, Never> {
    Task {
      while !Task.isCancelled {
        if let worker = await taskQueue.nextWorker() {
          let (success, _) = await worker.client.echo()
          if success {
            logger.info("Health check passed for worker: \(worker.id)")
            await workerHealthState.markSuccess(for: worker.id)
            await taskQueue.returnWorker(worker)
          } else {
            let (currentCount, shouldRemove) = await workerHealthState.recordFailure(for: worker.id)
            logger.error(
              "Health check failed for worker: \(worker.id) (failure count: \(currentCount)/\(maxFailureCount))"
            )

            if shouldRemove {
              logger.error("Worker \(worker.id) exceeded max failure count, removing from queue")
              await workerHealthState.clearFailure(for: worker.id)
              await taskQueue.removeWorkerById(worker.id)
            } else {
              await taskQueue.returnWorker(worker)
            }
          }
          try? await Task.sleep(for: .seconds(10))  // wait for 10s
        }
      }
    }
  }

  func parseBearer(from string: String) -> String? {
    let components = string.trimmingCharacters(in: .whitespaces).split(separator: " ")
    guard components.count == 2,
      components[0].lowercased() == "bearer"
    else {
      return nil
    }
    return String(components[1])
  }

  private func isValidRequest(
    payload: JWTPayload?, encodedBlob: Data, request: ImageGenerationRequest
  ) async -> (Bool, String, String?) {

    let isSharedSecretValid = await controlConfigs.isSharedSecretValid(request.sharedSecret)
    logger.info(
      "Proxy Server enqueue image generating payload:\(payload as Any)"
    )
    if isSharedSecretValid {
      logger.info("Proxy Server SharedSecret is valid, skip requests validation")
      return (true, "", GenerationConfiguration.from(data: request.configuration).model)
    }
    let requestHash = Data(SHA256.hash(data: encodedBlob))
    let checksum = requestHash.map({ String(format: "%02x", $0) }).joined()
    guard let payload = payload, payload.checksum == checksum else {
      logger.info(
        "Proxy Server enqueue image generating request failed, payload.blobSHA:\(payload?.checksum ?? "empty"), request blob:\(checksum) "
      )
      logger.info(
        "Proxy Server enqueue image generating request failed, payload:\(payload as Any)"
      )
      return (false, "Service bear-token signature is failed", nil)
    }
    logger.info("Proxy Server verified request checksum:\(checksum) success")

    guard await !controlConfigs.isUsedNonce(payload.nonce) || isSharedSecretValid else {
      logger.error(
        "Proxy Server image generating request failed, \(payload.nonce) is a used nonce"
      )
      return (false, "used nonce", nil)
    }
    await self.controlConfigs.addProcessedNonce(payload.nonce)
    let throttlePolicies = await controlConfigs.throttlePolicy
    for (key, stat) in payload.stats {
      let effectivePolicy = getEffectiveThrottlePolicy(
        for: key, payload: payload, throttlePolicies: throttlePolicies)

      if let throttlePolicy = effectivePolicy, throttlePolicy < stat {
        logger.error(
          "user \(payload.userId as Any) made \(stat) requests, while policy only allow \(throttlePolicy) for \(key)"
        )
        return (
          false, "user failed to pass throttlePolicy, \(key) in \(throttlePolicy)", nil
        )
      }
    }
    let configuration = GenerationConfiguration.from(data: request.configuration)
    guard let model = configuration.model else {
      return (false, "no valid model name ", nil)
    }
    // decode override models mapping
    let override = request.override
    let jsonDecoder = JSONDecoder()
    jsonDecoder.keyDecodingStrategy = .convertFromSnakeCase
    let overrideModels =
      (try? jsonDecoder.decode(
        [FailableDecodable<ModelZoo.Specification>].self, from: override.models
      ).compactMap({ $0.value })) ?? []
    let modelOverrideMapping = Dictionary(overrideModels.map { ($0.file, $0) }) { v, _ in v }
    let overrideLoras =
      (try? jsonDecoder.decode(
        [FailableDecodable<LoRAZoo.Specification>].self, from: override.loras
      ).compactMap({ $0.value })) ?? []
    let loraOverrideMapping = Dictionary(overrideLoras.map { ($0.file, $0) }) { v, _ in v }
    let hasImage = request.hasImage
    let shuffleCount = request.hints.reduce(0) {
      guard $1.hintType == "shuffle" else { return $0 }
      return $1.tensors.reduce(0) {
        $0 + ($1.weight > 0 ? 1 : 0)
      }
    }
    guard
      let cost = ComputeUnits.from(
        configuration, hasImage: hasImage, shuffleCount: shuffleCount,
        overrideMapping: (model: modelOverrideMapping, lora: loraOverrideMapping))
    else {
      logger.error(
        "Proxy Server can not calculate cost for configuration \(configuration)"
      )
      return (false, "Proxy Server can not calculate cost for model \(model)", model)
    }

    let (computeUnitPolicy, expirationTimestamp) =
      await controlConfigs.getComputeUnitPolicyAndExpirationTimestamp()
    let computeUnitPerBoost = await controlConfigs.computeUnitPerBoost
    let costThreshold = costThreshold(
      payload: payload,
      computeUnitPolicy: computeUnitPolicy,
      expirationTimestamp: expirationTimestamp,
      computeUnitPerBoost: computeUnitPerBoost
    )
    guard cost < costThreshold else {
      logger.error(
        "Proxy Server enqueue image generating request failed, cost \(cost) exceed threshold \(costThreshold)"
      )
      return (false, "cost \(cost) exceed threshold \(costThreshold)", model)
    }
    return (true, "", model)
  }

  func getEffectiveThrottlePolicy(
    for key: String, payload: JWTPayload, throttlePolicies: [String: Int]
  ) -> Int? {
    // API users without boost get special API limits
    if payload.fromBridge == true && payload.consumableType != .boost {
      let apiThrottlePolicyKey = payload.userClass == .plus ? "\(key)_api_plus" : "\(key)_api"
      return throttlePolicies[apiThrottlePolicyKey] ?? throttlePolicies[key]
    }

    let priorityKey = payload.userClass == .plus ? "\(key)_plus" : key
    return throttlePolicies[priorityKey] ?? throttlePolicies[key]
  }

  func costThreshold(
    payload: JWTPayload, computeUnitPolicy: [String: Int]?, expirationTimestamp: Date?,
    computeUnitPerBoost: Int
  ) -> Int {
    let costThresholdFromPolicy = ComputeUnits.threshold(
      for: payload.userClass?.rawValue,
      computeUnitPolicy: computeUnitPolicy,
      expirationTimestamp: expirationTimestamp
    )
    let boostsToSpend = payload.amount ?? 0
    let costThresholdFromBoost = ComputeUnits.thresholdAfterBoost(
      policyThreshold: costThresholdFromPolicy, boostsToSpend: boostsToSpend)
    logger.info(
      "Proxy Server payload.amount: \(payload.amount as Any), computeUnitPerBoost: \(computeUnitPerBoost), generation id: \(payload.generationId as Any) and costThresholdFromBoost: \(costThresholdFromBoost)"
    )
    if costThresholdFromBoost > costThresholdFromPolicy {
      logger.info(
        "Proxy Server applying consumable threshold \(costThresholdFromBoost) for generation id: \(payload.generationId as Any)"
      )
    }
    return costThresholdFromBoost
  }

  func generateImage(
    request: ServerRequest<ImageGenerationRequest>,
    context: ServerContext
  ) async throws -> StreamingServerResponse<ImageGenerationResponse> {
    guard
      let authorizationValue = request.metadata["authorization"].first(where: { _ in true }),
      case let .string(authorization) = authorizationValue,
      let bearToken = parseBearer(from: authorization)
    else {
      throw RPCError(code: .permissionDenied, message: "Service bear-token is empty")
    }
    logger.info("generateImage request")

    var validationRequest = request.message
    validationRequest.contents = []
    guard let encodedBlob = try? validationRequest.serializedData() else {
      throw RPCError(code: .permissionDenied, message: "Cannot encode validation request")
    }

    let logger = self.logger
    let requestMessage = request.message
    let requestMetadata = request.metadata
    return StreamingServerResponse(
      of: ImageGenerationResponse.self,
      metadata: [:]
    ) { writer in
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Metadata, Error>) in
        Task {
          let pem: String = await self.controlConfigs.publicKeyPEM
          let decoder = try? JWTDecoder(publicKeyPEM: pem)
          let payload = try? decoder?.decode(bearToken)
          guard let payload = payload else {
            logger.info("decode payload failed, bearToken:\(bearToken)")
            continuation.resume(
              throwing: RPCError(code: .permissionDenied, message: "Invalid payload"))
            return
          }
          let (isValidRequest, message, model) = await self.isValidRequest(
            payload: payload, encodedBlob: encodedBlob, request: requestMessage)
          guard isValidRequest, let model = model else {
            if payload.consumableType == .boost, let amount = payload.amount,
              let generationId = payload.generationId
            {
              logger.info(
                "isValidRequest cancel consumableType generationId:\( generationId), message:\(message)"
              )
              await self.proxyMessageSigner.completeBoost(
                action: .cancel, generationId: generationId, amount: amount,
                logger: logger)
            } else {
              logger.info(
                "isValidRequest cancel generationId:\( payload.generationId as Any), without completeBoost, consumableType:\(payload.consumableType as Any), amount:\(payload.amount as Any), message:\(message)"
              )
            }
            continuation.resume(
              throwing: RPCError(code: .permissionDenied, message: message))
            return
          }
          let throttlePolicies = await self.controlConfigs.throttlePolicy
          let priority = self.taskPriority(
            from: payload.userClass, payload: payload,
            throttlePolicies: throttlePolicies)
          let completionQueue = DispatchQueue(
            label: "ProxyCPUServer.taskCompletion.\(UUID().uuidString)")
          var completed = false
          let completeOnce: @Sendable (Result<Metadata, Error>) -> Void = { result in
            completionQueue.sync {
              guard !completed else { return }
              completed = true
            }
            continuation.resume(with: result)
          }
          let heartbeat = Task {
            while !Task.isCancelled && !context.cancellation.isCancelled {
              do {
                try await writer.write(ImageGenerationResponse())
              } catch {
                break
              }
              try? await Task.sleep(for: .seconds(20))
            }
          }
          let task = WorkTask(
            priority: priority,
            request: requestMessage,
            metadata: requestMetadata,
            responseWriter: writer,
            completion: completeOnce,
            heartbeat: heartbeat,
            creationTimestamp: Date(),
            model: model,
            payload: payload)
          await self.taskQueue.addTask(task)
          if let worker = await self.taskQueue.nextWorker() {
            let highThreshold = throttlePolicies["high_free_worker_threshold"] ?? 8
            let communityThreshold = throttlePolicies["community_free_worker_threshold"] ?? 0
            let throttleQueueTimeoutSeconds =
              throttlePolicies["throttle_queue_timeout_seconds"] ?? 3600
            let taskLoopBreakoutSeconds = throttlePolicies["task_loop_breakout_seconds"] ?? 30
            if let nextTaskForWorker = await self.taskQueue.nextTaskForWorker(
              worker, highThreshold: highThreshold, communityThreshold: communityThreshold,
              taskLoopBreakoutSeconds: taskLoopBreakoutSeconds)
            {
              do {
                try await worker.executeTask(
                  nextTaskForWorker, proxyMessageSigner: self.proxyMessageSigner,
                  throttleQueueTimeoutSeconds: throttleQueueTimeoutSeconds)
                logger.info("Task execution completed successfully for worker \(worker.id)")
              } catch {
                logger.error("Task execution failed for worker \(worker.id): \(error)")
              }
            }
            await self.taskQueue.returnWorker(worker)
          } else {
            logger.error("worker stream finished, can not get available worker")
            heartbeat.cancel()
            completeOnce(.failure(RPCError(code: .unavailable, message: "No available worker")))
          }
        }
      }
    }
  }

  func taskPriority(
    from userClass: UserClass?, payload: JWTPayload, throttlePolicies: [String: Int]
  )
    -> ProxyTaskPriority
  {
    if payload.consumableType == .boost {
      return .real
    }

    // Check if user has exceeded 24-hour limit
    if let dayStat = payload.stats["24_hour"],
      let daySoftLimitLow = throttlePolicies["daily_soft_limit_low"],
      let daySoftLimitHigh = throttlePolicies["daily_soft_limit_high"],
      dayStat >= daySoftLimitLow
    {
      if userClass == .plus {
        if dayStat >= daySoftLimitHigh {
          logger.info("downgrade dt plus to background")
          return .background
        }
        logger.info("downgrade dt plus to low")
        return .low
      } else {
        return .background
      }
    }

    switch userClass {
    case .plus:
      return .high
    case .community:
      return .low
    case .background:
      return .background
    case .banned:
      return .background
    case .throttled:
      logger.error(" userid: \(payload.userId as Any), is throttled. priority as background")
      return .background
    default:
      return .low
    }
  }

  func filesExist(request: ServerRequest<FileListRequest>, context: ServerContext) async throws
    -> ServerResponse<FileExistenceResponse>
  {
    let internalFilePath = await controlConfigs.modelListPath
    let response = FileExistenceResponse.with {
      $0.files = [String]()
      $0.existences = [Bool]()
      var fileList = [String]()
      if let fileContent = try? String(
        contentsOf: URL(fileURLWithPath: internalFilePath), encoding: .utf8)
      {
        fileList = fileContent.components(separatedBy: .newlines).filter { !$0.isEmpty }
      } else {
        logger.error("Proxy Server file list is nil")
      }
      for file in request.message.files {
        $0.files.append(file)
        let existence = fileList.contains(file)
        $0.existences.append(existence)
      }
    }
    return ServerResponse(message: response)
  }

  public func pubkey(request: ServerRequest<PubkeyRequest>, context: ServerContext)
    async throws -> ServerResponse<PubkeyResponse>
  {
    let pubkey = await self.proxyMessageSigner.getPublicKey()
    let response = PubkeyResponse.with {
      if let pubkey = pubkey {
        $0.pubkey = pubkey
        $0.message = "get pubkey successfully"
      } else {
        $0.message = "failed to get pubkey"
      }
    }
    return ServerResponse(message: response)
  }

  public func hours(request: ServerRequest<HoursRequest>, context: ServerContext) async throws
    -> ServerResponse<HoursResponse>
  {
    let (computeUnitPolicies, expirationTimestamp) =
      await controlConfigs.getComputeUnitPolicyAndExpirationTimestamp()

    let response = HoursResponse.with {

      if let expiration = expirationTimestamp, Date() < expiration {
        $0.thresholds = ComputeUnitThreshold.with {
          $0.community = Double(
            computeUnitPolicies["community"] ?? ComputeUnits.threshold(for: "community"))
          $0.plus = Double(computeUnitPolicies["plus"] ?? ComputeUnits.threshold(for: "plus"))
          $0.expireAt = Int64(expiration.timeIntervalSince1970)
        }
      }
    }
    return ServerResponse(message: response)
  }

  func echo(request: ServerRequest<EchoRequest>, context: ServerContext) async throws
    -> ServerResponse<EchoReply>
  {
    let internalFilePath = await controlConfigs.modelListPath
    let (computeUnitPolicies, expirationTimestamp) =
      await controlConfigs.getComputeUnitPolicyAndExpirationTimestamp()

    let response = EchoReply.with {
      logger.info("Proxy Server Received echo from: \(request.message.name)")
      $0.message = "Hello, \(request.message.name)!"
      var fileList = [String]()
      if let fileContent = try? String(
        contentsOf: URL(fileURLWithPath: internalFilePath), encoding: .utf8)
      {
        fileList = fileContent.components(separatedBy: .newlines).filter { !$0.isEmpty }
      } else {
        logger.error("Proxy Server file list is nil")
      }
      $0.files = fileList

      if let expiration = expirationTimestamp, Date() < expiration {
        $0.thresholds = ComputeUnitThreshold.with {
          $0.community = Double(
            computeUnitPolicies["community"] ?? ComputeUnits.threshold(for: "community"))
          $0.plus = Double(computeUnitPolicies["plus"] ?? ComputeUnits.threshold(for: "plus"))
          $0.expireAt = Int64(expiration.timeIntervalSince1970)
        }
      }
    }
    return ServerResponse(message: response)
  }

  func uploadFile(request: StreamingServerRequest<FileUploadRequest>, context: ServerContext)
    async throws -> StreamingServerResponse<UploadResponse>
  {
    throw RPCError(code: .unimplemented, message: "Service not supported")
  }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public class ProxyCPUServer {
  private let workers: [Worker]
  private let logger = Logger(label: "com.draw-things.image-generation-proxy-service")
  private var controlConfigs: ControlConfigs
  private var taskQueue: TaskQueue
  private var proxyMessageSigner: ProxyMessageSigner
  public init(
    workers: [Worker], publicKeyPEM: String, modelListPath: String, nonceSizeLimit: Int
  ) {
    self.workers = workers
    self.controlConfigs = ControlConfigs(
      throttlePolicy: [
        "15_min": 300, "10_min": 200, "5_min": 100, "1_hour": 1000, "1_min": 30,
        "24_hour_plus": 5000, "24_hour": 1000, "daily_soft_limit_low": 500,
        "daily_soft_limit_high": 750, "high_free_worker_threshold": 8,
        "community_free_worker_threshold": 0,
        "throttle_queue_timeout_seconds": 3600,
        "task_loop_breakout_seconds": 30,
        "24_hour_api_plus": 500, "24_hour_api": 100,
      ], publicKeyPEM: publicKeyPEM, logger: logger, modelListPath: modelListPath,
      nonceSizeLimit: nonceSizeLimit)
    self.proxyMessageSigner = ProxyMessageSigner()
    self.taskQueue = TaskQueue(workers: workers, logger: logger)
  }

  public func startControlPanel(hosts: [String], port: Int) async throws {
    logger.info("Control Panel Service starting on \(hosts) , port \(port)")
    try await withThrowingTaskGroup(of: Void.self) { group in
      for host in hosts {
        let taskQueue = self.taskQueue
        let controlConfigs = self.controlConfigs
        let logger = self.logger
        let proxyMessageSigner = self.proxyMessageSigner
        group.addTask {
          let controlPanelService = ControlPanelProxyService(
            taskQueue: taskQueue, controlConfigs: controlConfigs, logger: logger,
            proxyMessageSigner: proxyMessageSigner)
          let transport = HTTP2ServerTransport.Posix(
            address: .ipv4(host: host, port: port),
            transportSecurity: .plaintext
          )
          let server = GRPCServer(
            transport: transport,
            services: [controlPanelService as any RegistrableRPCService]
          )
          logger.info("Control Panel Service started on \(host):\(port)")
          try await server.serve()
        }
      }
      try await group.waitForAll()
    }
  }

  public func startAndWait(
    host: String, port: Int, TLS: Bool, certPath: String, keyPath: String, numberOfThreads: Int,
    healthCheck: Bool
  )
    async throws
  {
    logger.info("ImageGenerationProxyService starting on \(host):\(port)")
    let proxyService = ImageGenerationProxyService(
      taskQueue: taskQueue, controlConfigs: controlConfigs, logger: logger,
      healthCheck: healthCheck, proxyMessageSigner: proxyMessageSigner
    )

    var config = HTTP2ServerTransport.Posix.Config.defaults
    config.rpc.maxRequestPayloadSize = 1024 * 1024 * 1024

    let transportSecurity: HTTP2ServerTransport.Posix.TransportSecurity
    if TLS {
      if !certPath.isEmpty && !keyPath.isEmpty {
        transportSecurity = .tls(
          certificateChain: [.file(path: certPath, format: .pem)],
          privateKey: .file(path: keyPath, format: .pem)
        )
      } else {
        transportSecurity = .tls(
          certificateChain: [.bytes([UInt8](BinaryResources.server_crt_crt), format: .pem)],
          privateKey: .bytes([UInt8](BinaryResources.server_key_key), format: .pem)
        )
      }
    } else {
      transportSecurity = .plaintext
    }

    let transport = HTTP2ServerTransport.Posix(
      address: .ipv4(host: host, port: port),
      transportSecurity: transportSecurity,
      config: config,
      eventLoopGroup: .singletonMultiThreadedEventLoopGroup
    )
    let imageServer = GRPCServer(transport: transport, services: [proxyService])
    logger.info("Image Generation Proxy Service started on port \(host):\(port)")
    _ = numberOfThreads
    try await imageServer.serve()
  }

}
