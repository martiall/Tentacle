//
//  Client.swift
//  Tentacle
//
//  Created by Matt Diephouse on 3/3/16.
//  Copyright © 2016 Matt Diephouse. All rights reserved.
//

import Argo
import Foundation
import ReactiveSwift
import Result

extension JSONSerialization {
    internal static func deserializeJSON(_ data: Data) -> Result<JSON, AnyError> {
        return materialize(JSON(try JSONSerialization.jsonObject(with: data)))
    }
}

extension URL {
    internal func url(with queryItems: [URLQueryItem]) -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: true)!
        components.queryItems = (components.queryItems ?? []) + queryItems
        return components.url!
    }
    
    internal init<Value>(_ server: Server, _ request: Request<Value>, page: UInt? = nil, perPage: UInt? = nil) {
        let queryItems = [ ("page", page), ("per_page", perPage) ]
            .filter { arg -> Bool in let (_, value) = arg; return value != nil }
            .map { arg -> URLQueryItem in let (name, value) = arg; return URLQueryItem(name: name, value: "\(value!)") }

        let url = URL(string: server.endpoint)!
            .appendingPathComponent(request.path)
            .url(with: request.queryItems)
            .url(with: queryItems)

        self.init(string: url.absoluteString)!
    }
}

extension URLSession {
	/// Returns a producer that will download a file using the given request. The file will be
	/// deleted after the producer terminates.
	internal func downloadFile(_ request: URLRequest) -> SignalProducer<URL, AnyError> {
		return SignalProducer { observer, lifetime in
			let serialDisposable = SerialDisposable()
			let handle = lifetime += serialDisposable

			let task = self.downloadTask(with: request) { (url, response, error) in
				// Avoid invoking cancel(), or the download may be deleted.
				handle?.dispose()

				if let url = url {
					observer.send(value: url)
					observer.sendCompleted()
				} else if let error = error {
					observer.send(error: AnyError(error))
                } else {
                    fatalError("Request neither succeeded nor failed: \(String(describing: request.url))")
                }
			}

			serialDisposable.inner = AnyDisposable {
				task.cancel()
			}

			task.resume()
		}
	}
}

/// A GitHub API Client
public final class Client {
    /// The type of content to request from the GitHub API.
    internal static let APIContentType = "application/vnd.github.v3+json"
    
    /// The type of content to request from the GitHub API when downloading assets
    /// from releases.
    internal static let DownloadContentType = "application/octet-stream"
    
    /// An error from the Client.
    public enum Error: Swift.Error {
        /// An error occurred in a network operation.
        case networkError(Swift.Error)
        
        /// An error occurred while deserializing JSON.
        case jsonDeserializationError(Swift.Error)
        
        /// An error occurred while decoding JSON.
        case jsonDecodingError(DecodeError)
        
        /// A status code, response, and error that was returned from the API.
        case apiError(Int, Response, GitHubError)
        
        /// The requested object does not exist.
        case doesNotExist
    }
    
    /// Credentials for the GitHub API.
    internal enum Credentials {
        case token(String)
        case basic(username: String, password: String)
        
        var authorizationHeader: String {
            switch self {
            case let .token(token):
                return "token \(token)"
            case let .basic(username, password):
                let data = "\(username):\(password)".data(using: String.Encoding.utf8)!
                let encodedString = data.base64EncodedString()
                return "Basic \(encodedString)"
            }
        }
    }
    
    /// The user-agent to use for API requests.
    public static var userAgent: String?
    
    /// The Server that the Client connects to.
    public let server: Server
    
    /// Whether the Client is authenticated.
    public var isAuthenticated: Bool {
        return credentials != nil
    }
    
    /// The Credentials for the API.
    private let credentials: Credentials?

    /// The `URLSession` instance to use.
    private let urlSession: URLSession
    
    /// Create an unauthenticated client for the given Server.
    public init(_ server: Server, urlSession: URLSession = .shared) {
        self.server = server
        self.credentials = nil
        self.urlSession = urlSession
    }
    
    /// Create an authenticated client for the given Server with a token.
    public init(_ server: Server, token: String, urlSession: URLSession = .shared) {
        self.server = server
        self.credentials = .token(token)
        self.urlSession = urlSession
    }
    
    /// Create an authenticated client for the given Server with a username and password.
    public init(_ server: Server, username: String, password: String, urlSession: URLSession = .shared) {
        self.server = server
        self.credentials = .basic(username: username, password: password)
        self.urlSession = urlSession
    }
    
    /// Downloads the indicated release asset to a temporary file, returning the URL to the file on
    /// disk.
    ///
    /// The downloaded file will be deleted after the URL has been sent upon the signal.
    public func download(asset: Release.Asset) -> SignalProducer<URL, Error> {
        return urlSession
            .downloadFile(urlRequest(for: asset.apiURL, contentType: Client.DownloadContentType))
            .mapError { Error.networkError($0.error) }
    }
    
    /// Create a `URLRequest` for the given URL with the given content type.
    internal func urlRequest(for url: URL, contentType: String?) -> URLRequest {
        var result = URLRequest(url: url)
        
        result.setValue(contentType, forHTTPHeaderField: "Accept")
        
        if let userAgent = Client.userAgent {
            result.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        
        if let credentials = credentials {
            result.setValue(credentials.authorizationHeader, forHTTPHeaderField: "Authorization")
        }
        
        return result
    }
    
    /// Create a `URLRequest` for the given `Request`.
    private func urlRequest<Value>(for request: Request<Value>, page: UInt? = nil, perPage: UInt? = nil) -> URLRequest {
        let url = URL(server, request, page: page, perPage: perPage)
        var result = urlRequest(for: url, contentType: Client.APIContentType)
        result.httpMethod = request.method.rawValue
        result.httpBody = request.body
        return result
    }

    /// Fetch a request from the API.
    private func execute<Value>(_ request: Request<Value>, page: UInt?, perPage: UInt?) -> SignalProducer<(Response, JSON), Error> {
        return urlSession
            .reactive
            .data(with: urlRequest(for: request, page: page, perPage: perPage))
            .mapError { Error.networkError($0.error) }
            .flatMap(.concat) { data, response -> SignalProducer<(Response, JSON), Error> in
                let response = response as! HTTPURLResponse
                let headers = response.allHeaderFields as! [String:String]

                // The explicitness is required to pick up
                // `init(_ action: @escaping () -> Result<Value, Error>)`
                // over `init(_ action: @escaping () -> Value)`.
                let producer: SignalProducer<JSON, Error> = SignalProducer { () -> Result<JSON, Error> in
                    return JSONSerialization.deserializeJSON(data).mapError { Error.jsonDeserializationError($0.error) }
                }
                return producer
                    .attemptMap { json in
                        if response.statusCode == 404 {
                            return .failure(.doesNotExist)
                        }
                        if response.statusCode >= 400 && response.statusCode < 600 {
                            return decode(json)
                                .mapError(Error.jsonDecodingError)
                                .flatMap { error in
                                    .failure(Error.apiError(response.statusCode, Response(headerFields: headers), error))
                            }
                        }
                        return .success(json)
                    }
                    .map { json in
                        return (Response(headerFields: headers), json)
                    }
        }
    }
    
    /// Fetch an object from the API.
    public func execute<Resource: ResourceType>(
        _ request: Request<Resource>
    ) -> SignalProducer<(Response, Resource), Error> where Resource.DecodedType == Resource {
        return execute(request, page: nil, perPage: nil)
            .attemptMap { response, json in
                return decode(json)
                    .map { resource in
                        (response, resource)
                    }
                    .mapError(Error.jsonDecodingError)
            }
    }
    
    /// Fetch a list of objects from the API.
    ///
    /// This method will automatically fetch all pages. Each value in the returned signal producer
    /// will be the response and releases from a single page.
    public func execute<Resource: ResourceType>(
        _ request: Request<[Resource]>,
        page: UInt? = 1,
        perPage: UInt? = 30
    ) -> SignalProducer<(Response, [Resource]), Error> where Resource.DecodedType == Resource {
        let nextPage = (page ?? 1) + 1
        return execute(request, page: page, perPage: perPage)
            .attemptMap { (response: Response, json: JSON) in
                return decode(json)
                    .map { resource in
                        (response, resource)
                    }
                    .mapError(Error.jsonDecodingError)
            }
            .flatMap(.concat) { response, json -> SignalProducer<(Response, [Resource]), Error> in
                return SignalProducer(value: (response, json))
                    .concat(response.links["next"] == nil ? SignalProducer.empty : self.execute(request, page: nextPage, perPage: perPage))
            }
    }
}

extension Client.Error: Hashable {
    public static func ==(lhs: Client.Error, rhs: Client.Error) -> Bool {
        switch (lhs, rhs) {
        case let (.networkError(error1), .networkError(error2)):
            return (error1 as NSError) == (error2 as NSError)

        case let (.jsonDeserializationError(error1), .jsonDeserializationError(error2)):
            return (error1 as NSError) == (error2 as NSError)

        case let (.jsonDecodingError(error1), .jsonDecodingError(error2)):
            return error1 == error2

        case let (.apiError(statusCode1, response1, error1), .apiError(statusCode2, response2, error2)):
            return statusCode1 == statusCode2 && response1 == response2 && error1 == error2

        case (.doesNotExist, .doesNotExist):
            return true

        default:
            return false
        }
    }

    public var hashValue: Int {
        switch self {
        case let .networkError(error):
            return (error as NSError).hashValue

        case let .jsonDeserializationError(error):
            return (error as NSError).hashValue

        case let .jsonDecodingError(error):
            return error.hashValue

        case let .apiError(statusCode, response, error):
            return statusCode.hashValue ^ response.hashValue ^ error.hashValue

        case .doesNotExist:
            return 4
        }
    }
}
