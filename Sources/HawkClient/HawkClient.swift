import Foundation
import Combine
import Starscream
import SwiftyJSON

public enum HawkEvent {
    case error(error: any Error)
    case connectionState(isConnected: Bool, headers: [String:String]? = nil)
}

public class HawkClient: WebSocketDelegate {
    enum HawkError: Error {
        case unableToCreateChannel(message: String, statusCode: Int?)
        case unableToSubscribeToTopics(message: String, statusCode: Int?)
        case invalidToken
        case missingChannel
        case expiredChannel
        case invalidMessage(message: String)
        case topicError(message: String)
        case clientError(message: String)
    }
        
    public struct EventPayload {
        public let topic: String
        public let message: JSON
    }
    
    public private(set) var channelDetails: ChannelResponse?
    public private(set) var isConnected: Bool = false
    
    private var authToken: String
    private var host: String
    public private(set) var subscribedTopics: Set<String> = Set()
    private var socket: WebSocket?
    private var heartbeatTimer: Timer?
    
    private var userDisconnect = false
    
    public let notificationMessage = PassthroughSubject<EventPayload, Never>()
    public let socketEvent = PassthroughSubject<HawkEvent, Never>()
    
    // constants
    private let heartbeatTimeoutSeconds = 35.0
    private let topicLimit = 1000
    private let hawkServicePrefix = "streaming"
    private let apiPrefix = "api"
    private let userAgent = "Swift Hawk Client/1.0"
    private let systemTopics = ["channel.metadata", "v2.system.socket_closing"]

    public init(token: String, host: String) {
        self.authToken = token
        self.host = host
    }
    
    private func createAuthedUrlRequest(url: URL) -> URLRequest {
        var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        
        urlRequest.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        
        return urlRequest
    }
    
    private func createApiUrlRequest(url: URL) -> URLRequest {
        var urlRequest = createAuthedUrlRequest(url: url)
        
        urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.addValue("application/json", forHTTPHeaderField: "Accept")
        
        return urlRequest
    }
    
    private func isExpiredChannel() -> Bool {
        if let channelDetails {
            return channelDetails.expires >= .now
        }
        return false
    }
    
    private func closeSocket() {
        if let socket {
            socket.delegate = nil
            socket.disconnect()
            self.socket = nil
        }
    }
    
    private func createAndConnectSocket() throws {
        if let channelDetails {
            closeSocket()
            let request = URLRequest(url: URL(string: channelDetails.connectURI)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
            socket = WebSocket(request: request)
            if let socket {
                socket.delegate = self
                socket.connect()
            }
        } else {
            throw HawkError.missingChannel
        }
    }
    
    public func connect() throws {
        if channelDetails == nil {
            throw HawkError.missingChannel
        }
        
        if !isExpiredChannel() {
            throw HawkError.expiredChannel
        }
        try createAndConnectSocket()
    }

    private func reconnect() {
        socket?.disconnect()
        isConnected = false
        try? connect()
    }
    
    private func clearTimerIfExist() {
        // clear previous timer
        if heartbeatTimer != nil {
            heartbeatTimer?.invalidate()
            heartbeatTimer = nil
        }
    }
    
    private func startTimer() {
        clearTimerIfExist()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: heartbeatTimeoutSeconds, repeats: false) { _ in
            print("Hawk heartbeat expired!")
            self.reconnect()
        }
    }
    
    public func disconnect() {
        userDisconnect = true
        socket?.disconnect()
    }
    
    public func didReceive(event: Starscream.WebSocketEvent, client: Starscream.WebSocketClient) {
        switch event {
        case .connected(let headers):
            isConnected = true
            socketEvent.send(.connectionState(isConnected: isConnected, headers: headers))
            print("websocket is connected: \(headers)")
            startTimer()
            userDisconnect = false
            
        case .disconnected(let reason, let code):
            isConnected = false
            socketEvent.send(.connectionState(isConnected: isConnected))
            print("websocket is disconnected: \(reason) with code: \(code)")
            clearTimerIfExist()
            
            if !userDisconnect && channelDetails != nil {
                // unexpected disconnect from an expired channel
                if isExpiredChannel() {
                    Task {
                        try? await renewChannel()
                    }
                } else {
                    DispatchQueue.global().async {
                        try? self.connect()
                    }
                }
            }
            
        case .text(let string):
            startTimer()
            let json = JSON(parseJSON: string)
            if let topicName = json["topicName"].string {
                if systemTopics.contains(topicName) {
                    if topicName == "v2.system.socket_closing" {
                        reconnect()
                        return
                    }
                    // let heartbeat fall through
                    return
                }
                notificationMessage.send(EventPayload(topic: topicName, message: json))
            } else {
                socketEvent.send(.error(error: HawkError.invalidMessage(message: "Event has no 'topicName' field: \"\(string)\"")))
            }
        case .binary(let data):
            print("Received data: \(data.count)")
        case .ping(_):
            break
        case .pong(_):
            break
        case .viabilityChanged(_):
            break
        case .reconnectSuggested(_):
            break
        case .cancelled:
            isConnected = false
            clearTimerIfExist()
            socketEvent.send(.connectionState(isConnected: isConnected))
        
        case .error(let error):
            handleError(error)
            isConnected = false
            socketEvent.send(.connectionState(isConnected: isConnected))
            if let error {
                socketEvent.send(.error(error: error))
            }
            clearTimerIfExist()
            if let upgradeError = error as? Starscream.HTTPUpgradeError {
                switch upgradeError {
                case .notAnUpgrade(let statusCode, _):
                    if statusCode == 401 {
                        Task {
                            try? await self.renewChannel()
                        }
                        break
                    }
                    print("StatusCode \(statusCode)")
                    fallthrough
                case .invalidData:
                    print("Invalid Data")
                    try? self.createAndConnectSocket()
                }
            }
            
        case .peerClosed:
            print("peerClosed")
        }
    }
    
    private func handleError(_ error: Error?) {
        if let e = error as? WSError {
            print("websocket encountered an error: \(e.message)")
        } else if let e = error {
            print("websocket encountered an error: \(e.localizedDescription)")
        } else {
            print("websocket encountered an error")
        }
    }
    
    public func subscribeToTopics(topics: Set<String>, append: Bool = false) async throws -> Set<String> {
        if topics.count > topicLimit {
            throw HawkError.topicError(message: "Topic count of \(topics.count) is more than limit of \(topicLimit)")
        }
        let _ = try await getChannel()
        if let channelDetails {
            let urlString = "https://\(apiPrefix).\(host)/api/v2/notifications/channels/\(channelDetails.id)/subscriptions"
            guard let url = URL(string: urlString) else {
                throw HawkError.unableToSubscribeToTopics(message: "invalid subscription URL: \(urlString)", statusCode: nil)
            }
            var urlRequest = createApiUrlRequest(url: url)
            urlRequest.httpMethod = append ? "POST" : "PUT"
            urlRequest.httpBody = createSubscriptionPayload(topics: topics).data(using: .utf8)
            print(urlString)
            var data: Data
            do {
                let response = try await URLSession.shared.data(for: urlRequest)
                if let httpResponse = response.1 as? HTTPURLResponse {
                    if httpResponse.statusCode == 401 {
                        throw HawkError.invalidToken
                    }
                    if httpResponse.statusCode != 200 {
                        print("\(String(decoding: response.0, as: UTF8.self)) \(httpResponse.statusCode)")
                        throw HawkError.unableToSubscribeToTopics(message: "Unexpected status code", statusCode: httpResponse.statusCode)
                    }
                    data = response.0
                } else {
                    throw HawkError.unableToSubscribeToTopics(message: "unable to get status code", statusCode: nil)
                }
            } catch {
                throw HawkError.unableToSubscribeToTopics(message: error.localizedDescription, statusCode: nil)
            }
            
            do {
                let result = try JSONDecoder().decode(SubscriptionResponse.self, from: data)
                for entity in result.entities {
                    subscribedTopics.insert(entity.id)
                }
                return subscribedTopics
            } catch {
                throw HawkError.unableToSubscribeToTopics(message: "Response decode error \(error.localizedDescription)", statusCode: nil)
            }
        } else {
            throw HawkError.missingChannel
        }
    }
    
    private func renewChannel() async throws {
        do {
            try await createChannel()
            let topicsToSubscribeTo = subscribedTopics
            subscribedTopics.removeAll(keepingCapacity: true)
            let _ = try await subscribeToTopics(topics: topicsToSubscribeTo)
            try createAndConnectSocket()
        } catch {
            throw HawkError.clientError(message: error.localizedDescription)
        }
    }
    
    private func getChannel() async throws -> ChannelResponse {
        if channelDetails != nil {
            return channelDetails!
        }
        try await createChannel()
        return channelDetails!
    }
    
    private func createSubscriptionPayload(topics: Set<String>) -> String {
        let json = JSON(topics.map({ ["id" : $0] }))
        return json.rawString()!
    }
    
    private func createChannel() async throws {
        let urlString = "https://\(apiPrefix).\(host)/api/v2/notifications/channels"
        guard let url = URL(string: urlString) else {
            throw HawkError.unableToCreateChannel(message: "Invalid URL: \(urlString)", statusCode: nil)
        }
        var urlRequest = createAuthedUrlRequest(url: url)
        urlRequest.httpMethod = "POST"
        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 401 {
                    throw HawkError.invalidToken
                }
                if httpResponse.statusCode != 200 {
                    throw HawkError.unableToCreateChannel(message: "Unexpected status code", statusCode: httpResponse.statusCode)
                }

                do {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .customISO8601
                    channelDetails = try decoder.decode(ChannelResponse.self, from: data)
                    print("channel expires on \(channelDetails!.expires)")
                } catch {
                    throw HawkError.unableToCreateChannel(message: "Unable to decode response", statusCode: nil)
                }
            }
        } catch {
            throw HawkError.unableToCreateChannel(message: error.localizedDescription, statusCode: nil)
        }
    }
}
