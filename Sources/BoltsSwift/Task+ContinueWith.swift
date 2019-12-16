/*
 *  Copyright (c) 2016, Facebook, Inc.
 *  All rights reserved.
 *
 *  This source code is licensed under the BSD-style license found in the
 *  LICENSE file in the root directory of this source tree. An additional grant
 *  of patent rights can be found in the PATENTS file in the same directory.
 *
 * Kudos to pddkhanh for the CancellationToken implementation: https://github.com/BoltsFramework/Bolts-Swift/pull/49/commits/2229bf0fc0eb2550e18533e8294161b1e26ac7df
 *
 */

import Foundation

//---------------------------------------------
// MARK: - CancellationToken(Source/Reference)
//---------------------------------------------

/// A block that can be registered in a token for custom cancellation callbacks
public typealias CancellationBlock = () -> Void

/// Creates a token that can be used to check if a cancellation was requested. Only the source can cancel it's underlying token
open class CancellationTokenSource {
    
    public init() {}
    
    open var token: CancellationToken = CancellationToken()
    
    /// Cancellation via token
    open func cancel() {
        if !token.isCancellationRequested {
            self.token.cancel()
        }
    }
    
    /// Dispose all owned resources
    open func dispose() {
        self.token.dispose()
    }
}

/// Can be used to indicate that a task should be cancelled. Features registration of callbacks that are called on cancellation.
open class CancellationToken {
    
    public var registrations: [CancellationTokenRegistration]? = [CancellationTokenRegistration]()
    
    private var _cancellationRequested = false
    public var isCancellationRequested: Bool {
        get {
            return self.synchronizationQueue.sync { self._cancellationRequested }
        }
        set {
            self.synchronizationQueue.sync {
                if self._cancellationRequested {
                    return
                }
                
                self._cancellationRequested = newValue
            }
        }
    }
    
    private var _disposed = false
    public var isDisposed: Bool {
        get {
            return self.synchronizationQueue.sync { self._disposed }
        }
        set {
            self.synchronizationQueue.sync {
                if self._disposed {
                    return
                }
                
                self._disposed = newValue
            }
        }
    }
    
    /// Indicates that a cancellation was requested. This sets isCancellationRequested to true and calls all registered cancellation oberservs.
    func cancel() {
        var localRegistrations: [CancellationTokenRegistration]?
        self.synchronizationQueue.sync {
            if _cancellationRequested {
                return
            }
            
            _cancellationRequested = true
            localRegistrations = self.registrations
        }
        localRegistrations?.forEach { $0.notifyDelegate() }
    }
    
    /// Registers a callback to be called when a cancellation was requested (only once)
    ///
    /// - Parameter block: Custom callback to be called on cancellation
    /// - Returns: A handle that can be used to unregister the block
    @discardableResult
    public func registerCancellationObserverWithBlock(_ block: @escaping CancellationBlock) -> CancellationTokenRegistration {
        return self.synchronizationQueue.sync {
            let registration = CancellationTokenRegistration(token: self, delegate: block)
            self.registrations?.append(registration)
            return registration
        }
    }
    
    /// Unregisters a previously registered callback
    ///
    /// - Parameter registration: The handle received when registering
    func unregisterRegistration(_ registration: CancellationTokenRegistration) {
        self.synchronizationQueue.sync {
            self.registrations?.removeAll { $0 === registration }
        }
    }
    
    func dispose() {
        self.synchronizationQueue.sync {
            if self._disposed {
                return
            }
            
            if let r = self.registrations {
                r.forEach { $0.dispose() } //HINT: Mutating! Disposing a registration removes it from the token's registrations list.
                self.registrations = nil
            }
            self._disposed = true
        }
    }
    
    fileprivate let synchronizationQueue = DispatchQueue(label: "com.bolts.task+CancellationToken", attributes: DispatchQueue.Attributes.concurrent)
}

/// This handle can be used to unregister a previously registered callback.
public class CancellationTokenRegistration {
    
    private weak var token: CancellationToken?
    private var cancellationObserverBlock: CancellationBlock?
    
    private var _disposed = false
    public var isDisposed: Bool {
        get {
            return self.synchronizationQueue.sync { self._disposed }
        }
        set {
            self.synchronizationQueue.sync {
                if self._disposed {
                    return
                }
                
                self._disposed = newValue
            }
        }
    }
    
    init(token: CancellationToken?, delegate: @escaping CancellationBlock) {
        self.token = token
        self.cancellationObserverBlock = delegate
    }
    
    func notifyDelegate() {
        self.cancellationObserverBlock?()
    }
    
    public func dispose() {
        if self.synchronizationQueue.sync(execute: { () -> Bool in
            if self._disposed {
                return true
            }
            
            self._disposed = true
            return false
        }) {
            return
        }
        
        if let t = self.token {
            t.unregisterRegistration(self)
            self.token = nil
        }
        self.cancellationObserverBlock = nil
    }
    
    fileprivate let synchronizationQueue = DispatchQueue(label: "com.bolts.task+CancellationTokenRegistration", attributes: DispatchQueue.Attributes.concurrent)
    
}

//--------------------------------------
// MARK: - ContinueWith + cancellationToken
//--------------------------------------
public extension Task {
    
    @discardableResult
    func continueWith<S>(_ executor: Executor = .default, cancellationToken: CancellationToken, continuation: @escaping ((Task<TResult>) throws -> S)) -> Task<S> {
        
        return self.continueWithTask(executor, cancellationToken: cancellationToken, continuation: { (task) -> Task<S> in
            let state = TaskState.fromClosure({
                try continuation(task)
            })
            return Task<S>(state: state)
        })
    }
    
    @discardableResult
    func continueWithTask<S>(_ executor: Executor = .default, cancellationToken: CancellationToken, continuation: @escaping ((Task<TResult>) throws -> Task<S>)) -> Task<S> {
        return continueWithTask(executor, cancellationToken: cancellationToken, options: .RunAlways, continuation: continuation)
    }
    
    @discardableResult
    func continueOnSuccessWith<S>(_ executor: Executor = .default, cancellationToken: CancellationToken, continuation: @escaping ((TResult) throws -> S)) -> Task<S> {
        return continueOnSuccessWithTask(executor, cancellationToken: cancellationToken, continuation: { (taskResult) -> Task<S> in
            let state = TaskState.fromClosure({
                try continuation(taskResult)
            })
            return Task<S>(state: state)
        })
    }
    
    @discardableResult
    func continueOnSuccessWithTask<S>(_ executor: Executor = .default, cancellationToken: CancellationToken, continuation: @escaping ((TResult) throws -> Task<S>)) -> Task<S> {
        return continueWithTask(executor, cancellationToken: cancellationToken, options: .RunOnSuccess) { task in
            return try continuation(task.result!)
        }
    }
    
}


//--------------------------------------
// MARK: - ContinueWith
//--------------------------------------

extension Task {
    /**
     Internal continueWithTask. This is the method that all other continuations must go through.
     
     - parameter executor:              The executor to invoke the closure on.
     - parameter cancellationToken:     The cancellation token to cancel task later.
     - parameter options:               The options to run the closure with
     - parameter continuation:          The closure to execute.
     
     - returns: The task resulting from the continuation
     */
    fileprivate func continueWithTask<S>(_ executor: Executor,
                                         cancellationToken: CancellationToken? = nil,
                                         options: TaskContinuationOptions,
                                         continuation: @escaping ((Task) throws -> Task<S>)
        ) -> Task<S> {
        let taskCompletionSource = TaskCompletionSource<S>()
        let wrapperContinuation = {
            if cancellationToken?.isCancellationRequested == true {
                taskCompletionSource.cancel()
            } else {
                switch self.state {
                case .success where options.contains(.RunOnSuccess): fallthrough
                case .error where options.contains(.RunOnError): fallthrough
                case .cancelled where options.contains(.RunOnCancelled):
                    executor.execute {
                        let wrappedState = TaskState<Task<S>>.fromClosure {
                            try continuation(self)
                        }
                        
                        if cancellationToken?.isCancellationRequested == true {
                            taskCompletionSource.cancel()
                        } else {
                            
                            switch wrappedState {
                            case .success(let nextTask):
                                switch nextTask.state {
                                case .pending:
                                    nextTask.continueWith { nextTask in
                                        taskCompletionSource.setState(nextTask.state)
                                    }
                                default:
                                    taskCompletionSource.setState(nextTask.state)
                                }
                            case .error(let error):
                                taskCompletionSource.set(error: error)
                            case .cancelled:
                                taskCompletionSource.cancel()
                            default: abort() // This should never happen.
                            }
                        }
                        
                    }
                    
                    
                case .success(let result as S):
                    // This is for continueOnErrorWith - the type of the result doesn't change, so we can pass it through
                    taskCompletionSource.set(result: result)
                    
                case .error(let error):
                    taskCompletionSource.set(error: error)
                    
                case .cancelled:
                    taskCompletionSource.cancel()
                    
                default:
                    fatalError("Task was in an invalid state \(self.state)")
                }
            }
        }
        appendOrRunContinuation(wrapperContinuation)
        return taskCompletionSource.task
    }

    /**
     Enqueues a given closure to be run once this task is complete.

     - parameter executor:     Determines how the the closure is called. The default is to call the closure immediately.
     - parameter continuation: The closure that returns the result of the task.

     - returns: A task that will be completed with a result from a given closure.
     */
    @discardableResult
    public func continueWith<S>(_ executor: Executor = .default, continuation: @escaping ((Task) throws -> S)) -> Task<S> {
        return continueWithTask(executor) { task in
            let state = TaskState.fromClosure({
                try continuation(task)
            })
            return Task<S>(state: state)
        }
    }

    /**
     Enqueues a given closure to be run once this task is complete.

     - parameter executor:     Determines how the the closure is called. The default is to call the closure immediately.
     - parameter continuation: The closure that returns a task to chain on.

     - returns: A task that will be completed when a task returned from a closure is completed.
     */
    @discardableResult
    public func continueWithTask<S>(_ executor: Executor = .default, continuation: @escaping ((Task) throws -> Task<S>)) -> Task<S> {
        return continueWithTask(executor, options: .RunAlways, continuation: continuation)
    }
}

//--------------------------------------
// MARK: - ContinueOnSuccessWith
//--------------------------------------

extension Task {
    /**
     Enqueues a given closure to be run once this task completes with success (has intended result).

     - parameter executor:     Determines how the the closure is called. The default is to call the closure immediately.
     - parameter continuation: The closure that returns a task to chain on.

     - returns: A task that will be completed when a task returned from a closure is completed.
     */
    @discardableResult
    public func continueOnSuccessWith<S>(_ executor: Executor = .default,
                                      continuation: @escaping ((TResult) throws -> S)) -> Task<S> {
        return continueOnSuccessWithTask(executor) { taskResult in
            let state = TaskState.fromClosure({
                try continuation(taskResult)
            })
            return Task<S>(state: state)
        }
    }

    /**
     Enqueues a given closure to be run once this task completes with success (has intended result).

     - parameter executor:     Determines how the the closure is called. The default is to call the closure immediately.
     - parameter continuation: The closure that returns a task to chain on.

     - returns: A task that will be completed when a task returned from a closure is completed.
     */
    @discardableResult
    public func continueOnSuccessWithTask<S>(_ executor: Executor = .default,
                                          continuation: @escaping ((TResult) throws -> Task<S>)) -> Task<S> {
        return continueWithTask(executor, options: .RunOnSuccess) { task in
            return try continuation(task.result!)
        }
    }
}

//--------------------------------------
// MARK: - ContinueOnErrorWith
//--------------------------------------

extension Task {
    /**
     Enqueues a given closure to be run once this task completes with error.

     - parameter executor:     Determines how the the closure is called. The default is to call the closure immediately.
     - parameter continuation: The closure that returns a task to chain on.

     - returns: A task that will be completed when a task returned from a closure is completed.
     */
    @discardableResult
    public func continueOnErrorWith<E: Error>(_ executor: Executor = .default, continuation: @escaping ((E) throws -> TResult)) -> Task {
        return continueOnErrorWithTask(executor) { (error: E) in
            let state = TaskState.fromClosure({
                try continuation(error)
            })
            return Task(state: state)
        }
    }

    /**
     Enqueues a given closure to be run once this task completes with error.

     - parameter executor:     Determines how the the closure is called. The default is to call the closure immediately.
     - parameter continuation: The closure that returns a task to chain on.

     - returns: A task that will be completed when a task returned from a closure is completed.
     */
    @discardableResult
    public func continueOnErrorWith(_ executor: Executor = .default, continuation: @escaping ((Error) throws -> TResult)) -> Task {
        return continueOnErrorWithTask(executor) { (error: Error) in
            let state = TaskState.fromClosure({
                try continuation(error)
            })
            return Task(state: state)
        }
    }

    /**
     Enqueues a given closure to be run once this task completes with error.

     - parameter executor:     Determines how the the closure is called. The default is to call the closure immediately.
     - parameter continuation: The closure that returns a task to chain on.

     - returns: A task that will be completed when a task returned from a closure is completed.
     */
    @discardableResult
    public func continueOnErrorWithTask<E: Error>(_ executor: Executor = .default, continuation: @escaping ((E) throws -> Task)) -> Task {
        return continueOnErrorWithTask(executor) { (error: Error) in
            if let error = error as? E {
                return try continuation(error)
            }
            return Task(state: .error(error))
        }
    }

    /**
     Enqueues a given closure to be run once this task completes with error.

     - parameter executor:     Determines how the the closure is called. The default is to call the closure immediately.
     - parameter continuation: The closure that returns a task to chain on.

     - returns: A task that will be completed when a task returned from a closure is completed.
     */
    @discardableResult
    public func continueOnErrorWithTask(_ executor: Executor = .default, continuation: @escaping ((Error) throws -> Task)) -> Task {
        return continueWithTask(executor, options: .RunOnError) { task in
            return try continuation(task.error!)
        }
    }
}
