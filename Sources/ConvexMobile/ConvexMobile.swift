// The Swift Programming Language
// https://docs.swift.org/swift-book

import Combine
import Foundation
@_exported import UniFFI

/// A client API for interacting with a Convex backend.
///
/// Handles marshalling of data between calling code and the
/// [convex-mobile](https://github.com/get-convex/convex-mobile) and
/// [convex-rs](https://github.com/get-convex/convex-rs) native libraries.
///
/// Consumers of this client should use Swift's ``Decodable``  protocol for handling data received from the
/// Convex backend.
public class ConvexClient {
  let ffiClient: UniFFI.MobileConvexClientProtocol

  /// Creates a new instance of ``ConvexClient``.
  ///
  /// - Parameters:
  ///   - deploymentUrl: The Convex backend URL to connect to; find it in the [dashboard](https://dashboard.convex.dev) Settings for your project
  public init(deploymentUrl: String) {
    self.ffiClient = UniFFI.MobileConvexClient(
      deploymentUrl: deploymentUrl, clientId: "swift-\(convexMobileVersion)")
  }

  init(ffiClient: UniFFI.MobileConvexClientProtocol) {
    self.ffiClient = ffiClient
  }

  /// Subscribes to the query with the given `name` and converts data from the subscription into an
  /// ``AnyPublisher<T, ClientError>``.
  ///
  /// The upstream Convex subscription will be canceled if whatever is subscribed to returned publisher
  /// stops listening.
  ///
  /// - Parameters:
  ///   - name: A value in "module:query_name"  format that will be used when calling the backend
  ///   - args: An optional ``Dictionary`` of arguments to be sent to the backend query function
  ///   - output: The type of data that will be returned in the Publisher, as a convenience to callers
  ///             where the type can't be easily inferred.
  public func subscribe<T: Decodable>(
    to name: String, with args: [String: ConvexEncodable?]? = nil, yielding output: T.Type? = nil
  ) -> AnyPublisher<T, ClientError> {
    // There are two steps to producing the final Publisher in this method.
    // 1. Subscribe to the data from Convex and publish the subscription handle
    // 2. Feed the subscription handle into the Convex data Publisher so it can cancel the upstream
    //    subscription when downstream subscribers are done consuming data

    // This Publisher will ultimated publish the data received from Convex.
    let convexPublisher = PassthroughSubject<T, ClientError>()
    let adapter = SubscriptionAdapter<T>(publisher: convexPublisher)

    // This Publisher is responsible for initializing the Convex subscription and returning a handle
    // to the upstream (Convex) subscription.
    let initializationPublisher = Future<SubscriptionHandle, ClientError> {
      result in
      Task {
        do {
          let subscriptionHandle = try await self.ffiClient.subscribe(
            name: name,
            args: args?.mapValues({ v in
              try v?.convexEncode() ?? "null"
            }) ?? [:], subscriber: adapter)
          result(.success(subscriptionHandle))
        } catch {
          result(.failure(ClientError.InternalError(msg: error.localizedDescription)))
        }
      }
    }

    // The final Publisher takes the handle from the initial Convex subscription and supplies it to
    // the data publisher so it can cancel the upstream subscription when consumers are no longer
    // listening for data.
    return initializationPublisher.flatMap({ subscriptionHandle in
      convexPublisher.handleEvents(receiveCancel: {
        subscriptionHandle.cancel()
      })
    })
    .eraseToAnyPublisher()
  }

  /// Executes the mutation with the given `name` and `args` and returns the result.
  ///
  /// For mutations that don't return a value, prefer calling the version of this method that doesn't return a value.
  ///
  /// - Parameters:
  ///   - name: A value in "module:mutation_name"  format that will be used when calling the backend
  ///   - args: An optional ``Dictionary`` of arguments to be sent to the backend mutation function
  public func mutation<T: Decodable>(_ name: String, with args: [String: ConvexEncodable?]? = nil)
    async throws -> T
  {
    try await callForResult(name: name, args: args, remoteCall: ffiClient.mutation)
  }

  /// Executes the mutation with the given `name` and `args` without returning a result.
  ///
  /// For mutations that return a value, prefer calling the version of this method that returns a ``Decodable`` value.
  ///
  /// - Parameters:
  ///   - name: A value in "module:mutation_name"  format that will be used when calling the backend
  ///   - args: An optional ``Dictionary`` of arguments to be sent to the backend mutation function
  public func mutation(_ name: String, with args: [String: ConvexEncodable?]? = nil)
    async throws
  {
    let _: String? = try await mutation(name, with: args)
  }

  /// Executes the action with the given `name` and `args` and returns the result.
  ///
  /// For actions that don't return a value, prefer calling the version of this method that doesn't return a value.
  ///
  /// - Parameters:
  ///   - name: A value in "module:mutation_name"  format that will be used when calling the backend
  ///   - args: An optional ``Dictionary`` of arguments to be sent to the backend mutation function
  public func action<T: Decodable>(_ name: String, with args: [String: ConvexEncodable?]? = nil)
    async throws -> T
  {
    return try await callForResult(name: name, args: args, remoteCall: ffiClient.action)
  }

  /// Executes the action with the given `name` and `args` without returning a result.
  ///
  /// For actions that return a value, prefer calling the version of this method that returns a ``Decodable`` value.
  ///
  /// - Parameters:
  ///   - name: A value in "module:mutation_name"  format that will be used when calling the backend
  ///   - args: An optional ``Dictionary`` of arguments to be sent to the backend mutation function
  public func action(_ name: String, with args: [String: ConvexEncodable?]? = nil)
    async throws
  {
    let _: String? = try await action(name, with: args)
  }

  /// Common handler for `action` and `mutation` calls.
  ///
  /// To the client code, both work in a very similar fashion where remote code is invoked and a result is returned. This handler takes care of
  /// encoding the arguments and decoding the result, whether the call is an `action` or `mutation`.
  func callForResult<T: Decodable>(
    name: String, args: [String: ConvexEncodable?]? = nil, remoteCall: RemoteCall
  )
    async throws -> T
  {
    let rawResult = try await remoteCall(
      name,
      args?.mapValues({ v in
        try v?.convexEncode() ?? "null"
      }) ?? [:])
    return try! JSONDecoder().decode(T.self, from: Data(rawResult.utf8))
  }

  typealias RemoteCall = (String, [String: String]) async throws -> String
}

/// Authentication states that can be experienced when using an ``AuthProvider`` with
/// ``ConvexClientWithAuth``.
public enum AuthState<T> {
  /// Represents an authenticated user.
  ///
  /// Contains authentication data from the associated ``AuthProvider``.
  case authenticated(T)
  /// Represents an unauthenticated user.
  case unauthenticated
  /// Represents an ongoing authentication attempt.
  case loading
}

/// An authentication provider, used with ``ConvexClientWithAuth``.
///
/// The generic type `T` is the data returned by the provider upon a successful authentication attempt.
public protocol AuthProvider<T> {
  associatedtype T

  /// Trigger a login flow, which might launch a new UI/screen.
  func login() async throws -> T
  /// Trigger a logout flow, which might launch a new UI/screen.
  func logout() async throws
  /// Trigger a cached, UI-less re-authentication ussing stored credentials from a previous ``login()``.
  func loginFromCache() async throws -> T
  /// Extracts a [JWT ID token](https://openid.net/specs/openid-connect-core-1_0.html#IDToken)
  /// from the `authResult`.
  func extractIdToken(from authResult: T) -> String
}

/// Like ``ConvexClient``, but supports integration with an authentication provider via ``AuthProvider``.
///
/// The generic parameter `T` matches the type of data returned by the ``AuthProvider`` upon successful
/// authentication.
public class ConvexClientWithAuth<T>: ConvexClient {
  private let authPublisher = CurrentValueSubject<AuthState<T>, Never>(AuthState.unauthenticated)
  private let authProvider: any AuthProvider<T>

  /// A publisher that updates with the current ``AuthState`` of this client instance.
  public let authState: AnyPublisher<AuthState<T>, Never>

  /// Creates a new instance of ``ConvexClientWithAuth``.
  ///
  /// - Parameters:
  ///   - deploymentUrl: The Convex backend URL to connect to; find it in the [dashboard](https://dashboard.convex.dev) Settings for your project
  ///   - authProvider: An instance that will handle the actual authentication duties.
  public init(deploymentUrl: String, authProvider: any AuthProvider<T>) {
    self.authProvider = authProvider
    self.authState = authPublisher.eraseToAnyPublisher()
    super.init(deploymentUrl: deploymentUrl)
  }

  init(ffiClient: MobileConvexClientProtocol, authProvider: any AuthProvider<T>) {
    self.authProvider = authProvider
    self.authState = authPublisher.eraseToAnyPublisher()
    super.init(ffiClient: ffiClient)
  }

  /// Triggers a UI driven login flow and updates the ``authState``.
  ///
  /// The ``authState`` is set to ``AuthState.loading`` immediately upon calling this method and
  /// will change to either ``AuthState.authenticated`` or ``AuthState.unauthenticated``
  /// depending on the result.
  public func login() async -> Result<T, Error> {
    await login(strategy: authProvider.login)
  }

  /// Triggers a cached, UI-less re-authentication flow using previously stored credentials and updates the
  /// ``authState``.
  ///
  /// If no credentials were previously stored, or if there is an error reusing stored credentials, the resulting
  /// ``authState`` willl be ``AuthState.unauthenticated``. If supported by the ``AuthProvider``,
  /// a call to ``login()`` should store another set of credentials upon successful authentication.
  ///
  /// The ``authState`` is set to ``AuthState.loading`` immediately upon calling this method and
  /// will change to either ``AuthState.authenticated`` or ``AuthState.unauthenticated``
  /// depending on the result.
  public func loginFromCache() async -> Result<T, Error> {
    await login(strategy: authProvider.loginFromCache)
  }

  /// Triggers a logout flow and updates the ``authState``.
  ///
  /// The ``authState`` will change to ``AuthState.unauthenticated`` if logout is successful.
  public func logout() async {
    do {
      try await authProvider.logout()
      try await ffiClient.setAuth(token: nil)
      authPublisher.send(AuthState.unauthenticated)
    } catch {
      dump(error)
    }
  }

  private func login(strategy: LoginStrategy) async -> Result<T, Error> {
    authPublisher.send(AuthState.loading)
    do {
      let authData = try await strategy()
      try await ffiClient.setAuth(token: authProvider.extractIdToken(from: authData))
      authPublisher.send(AuthState.authenticated(authData))
      return Result.success(authData)
    } catch {
      dump(error)
      authPublisher.send(AuthState.unauthenticated)
      return Result.failure(error)
    }
  }

  private typealias LoginStrategy = () async throws -> T
}

private class SubscriptionAdapter<T: Decodable>: QuerySubscriber {
  typealias Publisher = PassthroughSubject<T, ClientError>

  let publisher: Publisher

  init(publisher: Publisher) {
    self.publisher = publisher
  }

  func onError(message: String, value: String?) {
    let err: ClientError
    if let value {
      err = ClientError.ConvexError(data: value)
    } else {
      err = ClientError.ServerError(msg: message)
    }
    publisher.send(
      completion: Subscribers.Completion.failure(err))
  }

  func onUpdate(value: String) {
      do {
          let decodedData = try JSONDecoder().decode(Publisher.Output.self, from: Data(value.utf8))
          publisher.send(decodedData)
      } catch {
          publisher.send(completion: Subscribers.Completion.failure(ClientError.InternalError(msg: error.localizedDescription)))
      }
  }
}
