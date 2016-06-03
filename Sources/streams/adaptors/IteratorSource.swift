//
//  GeneratorSource.swift
//  Noze.IO
//
//  Created by Helge Hess on 24/06/15.
//  Copyright © 2015 ZeeZide GmbH. All rights reserved.
//

#if swift(>=3.0) // #swift3-fd

import Dispatch
import core

public extension Sequence {
  
  func readableSource() -> SyncIteratorSource<Self.Iterator> {
    return SyncIteratorSource(self)
  }
  
  func asyncReadableSource() -> AsyncIteratorSource<Self.Iterator> {
    return AsyncIteratorSource(self)
  }
  
}

public extension IteratorProtocol {
  
  func readableSource() -> SyncIteratorSource<Self> {
    return SyncIteratorSource(self)
  }
  
  func asyncReadableSource() -> AsyncIteratorSource<Self> {
    return AsyncIteratorSource(self)
  }
  
}

/// Wraps a regular Swift Iterator in a ReadableSourceType.
///
/// Note that this one is synchronous, aka, the Generator should not block on
/// I/O or be otherwise expensive. For such cases use the AsyncGeneratorSource.
public struct SyncIteratorSource<G: IteratorProtocol> : GReadableSourceType {
  
  public static var defaultHighWaterMark : Int { return 5 } // TODO
  var source : G
  
  // MARK: - Init from a GeneratorType or a SequenceType
  
  init(_ source: G) {
    self.source = source
  }
  init<S: Sequence where S.Iterator == G>(_ source: S) {
    self.init(source.makeIterator())
  }
  
  // MARK: - queue based next() function
  
  /// Synchronously generates an item. That is, this directly yields a value
  /// back to the Readable.
  public mutating func next(queue _: dispatch_queue_t, count: Int,
                            yield : ( ErrorProtocol?, [ G.Element ]? ) -> Void)
  {
    guard let first = source.next() else {
      yield(nil, nil) // EOF
      return
    }
    
    if count == 1 {
      yield( nil, [ first ] )
      return
    }
    
    var buffer : [ G.Element ] = []
    buffer.reserveCapacity(count)
    buffer.append(first)
    
    for _ in 1..<count {
      guard let item = source.next() else {
        yield(nil, buffer)
        yield(nil, nil)    // EOF, two yields
        return
      }
      
      buffer.append(item)
    }
    
    yield(nil, buffer)
  }
}

/// Wraps a regular Swift Generator in a ReadableSourceType.
///
/// The AsyncGeneratorSource uses a worker queue to dispatch reading
/// asynchronously.
///
/// Note: Currently the worker queue is supposed to be a serial queue, as the
///       Readable might dispatch a set of reads and the source has no internal
///       synchronization yet.
/// TODO: support pause()?
public struct AsyncIteratorSource<G: IteratorProtocol> : GReadableSourceType {
  
  public static var defaultHighWaterMark : Int { return 5 } // TODO
  var source              : G
  let workerQueue         : dispatch_queue_t
  let maxCountPerDispatch : Int
  
  // MARK: - Init from a GeneratorType or a SequenceType
  
  init(_ source: G, workerQueue: dispatch_queue_t = getDefaultWorkerQueue(),
       maxCountPerDispatch: Int = 16)
  {
    self.source              = source
    self.workerQueue         = workerQueue
    self.maxCountPerDispatch = maxCountPerDispatch
  }
  init<S: Sequence where S.Iterator == G>
    (_ source: S, workerQueue: dispatch_queue_t = getDefaultWorkerQueue())
  {
    self.init(source.makeIterator(), workerQueue: workerQueue)
  }
  
  
  // MARK: - queue based next() function
  
  /// Asynchronously generate items.
  ///
  /// This dispatches the generator on the workerQueue of the source, but
  /// properly yields back results on the queue which is passed in.
  ///
  /// The number of generation attempts can be limited using the 
  /// maxCountPerDispatch property. I.e. that property presents an upper limit
  /// to the 'count' property which was passed in.

  public mutating func next(queue Q : dispatch_queue_t, count: Int,
                            yield   : ( ErrorProtocol?, [ G.Element ]? )-> Void)
  {
    // Note: we do capture self for the generator ...
    let maxCount = self.maxCountPerDispatch
    
    dispatch_async(workerQueue) {
      guard let first = self.source.next() else {
        dispatch_async(Q) { yield(nil, nil) } // EOF
        return
      }
      
      let actualCount = max(count, maxCount)
      
      if actualCount == 1 {
        let bucket = [ first ]
        dispatch_async(Q) { yield(nil, bucket) }
        return
      }
      
      var buffer : [ G.Element ] = []
      buffer.reserveCapacity(actualCount)
      buffer.append(first)
      
      var hitEOF = false
      for _ in 1..<actualCount {
        guard let item = self.source.next() else {
          hitEOF = true
          break
        }
        
        buffer.append(item)
      }
      dispatch_async(Q) {
        yield(nil, buffer)
        if hitEOF { yield(nil, nil) } // EOF
      }
    }
  }
}

private func getDefaultWorkerQueue() -> dispatch_queue_t {
  /* Nope: Use a serial queue, w/o internal synchronization we would generate
           yields out of order.
  return dispatch_get_global_queue(QOS_CLASS_DEFAULT,
                                   UInt(DISPATCH_QUEUE_PRIORITY_DEFAULT))
  */
  return dispatch_queue_create("io.noze.source.iterator.async", nil)
}

#endif // Swift 3.x+