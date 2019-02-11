//
//  TaskCancellationSourceTests.swift
//  BoltsSwift-iOS
//
//  Created by Stephan Backhaus on 11.02.19.
//  Copyright © 2019 Facebook. All rights reserved.
//

import Foundation

import XCTest
import BoltsSwift

class CancellationTokenSourceTests: XCTestCase {
    
    func testInit() {
        let cts = CancellationTokenSource()
        let token = cts.token
        
        XCTAssertFalse(token.isCancellationRequested)
        XCTAssertFalse(token.isDisposed)
        XCTAssertNotNil(token.registrations)
        XCTAssertEqual(token.registrations!.count, 0)
    }
    
    func testTaskCancellationUsingToken() {
        let cts = CancellationTokenSource()
        cts.cancel()
        
        let task = Task<Bool>(true).continueWithTask(cancellationToken: cts.token) { task -> Task<Bool> in
            Task<Bool>(task.result ?? false)
        }
        
        XCTAssertTrue(task.completed)
        XCTAssertTrue(task.cancelled)
    }
    
    func testCancellationObservers() {
        let cts = CancellationTokenSource()
        let token = cts.token
        
        var callbacksCalled = 0
        
        token.registerCancellationObserverWithBlock {
            XCTAssertTrue(token.isCancellationRequested)
            XCTAssertFalse(token.isDisposed)
            callbacksCalled += 1
        }
        
        token.registerCancellationObserverWithBlock {
            callbacksCalled += 1
        }
        
        let expectation = self.expectation(description: self.name)
        var finished = false
        
        Task<Void>.withDelay(0.1).continueWith { task -> Void in
            cts.cancel()
        }
        
        Task<Void>.withDelay(0.2).continueWith(cancellationToken: token) { task -> Void in
            XCTAssertTrue(token.isCancellationRequested)
            if token.isCancellationRequested {
                return
            }
            
            finished = true
        }
        
        Task<Void>.withDelay(0.3).continueWith { task -> Void in
            XCTAssertFalse(finished)
            XCTAssertEqual(callbacksCalled, 2)
            expectation.fulfill()
        }
        
        waitForTestExpectations()
    }
    
    func testDisposingCancellationSource() {
        let cts = CancellationTokenSource()
        var counter = 0
        for i in 1...10 {
            cts.token.registerCancellationObserverWithBlock {
                counter += i
            }
        }
        
        let expectation = self.expectation(description: self.name)
        Task<Void>.withDelay(0.2).continueWithTask(cancellationToken: cts.token) { task -> Task<Void> in
            XCTAssertTrue(cts.token.isCancellationRequested)
            return Task<Void>.cancelledTask()
            }.continueWith { task -> Void in
                XCTAssertTrue(task.cancelled)
                expectation.fulfill()
        }
        
        Task<Void>.withDelay(0.1).continueWith { task -> Void in
            cts.dispose()
            XCTAssertTrue(cts.token.isDisposed)
            XCTAssertNil(cts.token.registrations)
            
            cts.cancel()
            XCTAssertTrue(cts.token.isCancellationRequested)
            XCTAssertEqual(counter, 0)
        }
        
        waitForTestExpectations()
    }
    
    
}
