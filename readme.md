# zig-async

## Goals
- empower Zig users to solve concurrent & parallel engineering problems
  - at a higher level of expressiveness than basic synchronization primitives (mutex/condvar)
  - while maintaining the low-level control that is crucial for systems programming
- to that end, provide a toolbox of software components with the following properties:
  - orthogonal - components are meaningful and useful by themselves. Components have minimal coupling between themselves.
  - composable - components can be combined to produce more powerful behaviours.
  - extensible - we cannot anticipate every use-case. So, our APIs must be designed in a way that allows users of the library to integrate their custom solutions.

## Features & Roadmap

### Stackfull Coroutine - a function you can suspend & resume
- [x] Basic support 
- Back-ends for machine context switch:
  - [x] aarch64
  - [ ] x86-64
    - [ ] Microsoft x64
    - [ ] System V AMD64 ABI
- [ ] ASAN support
- [x] TSAN support

### Executors & Schedulers
Thread pool
  - [x] "Compute" - single global queue
    - [ ] Use lock-free queue
  - [ ] "Fast" - similar to GoLang: per-thread local queues, work-stealing
  - Optimizations:
  - [ ] Option to "pin" thread pool worker threads to CPU core (core affinity)
- [ ] Fiber pool
  - reference: [Parallelizing the Naughty Dog Engine Using Fibers](https://www.youtube.com/watch?v=HIVBhKj7gQU&t=628s)
  - [ ] Worker abstraction over fibers and threads?
     
Other considerations:
- [ ] Separate "scheduler" from "executor"? (scheduler responsible for picking next task out of queue(s), executor actually runs it)
- [ ] Scheduler "submit" hints (inline/lifo/queue-end etc)
- [ ] Pass context with nursery etc. to all tasks submitted to executor/scheduler -> for structured concurrency 

### Fibers - stackfull cooperatively-scheduled user-space threads
- [x] Basic support
- [x] Yield

Synchronization primitives
  - [x] Mutex
  - [x] Event
  - [x] Wait Group
  - [x] Barrier 

Channel
- https://github.com/zxubian/zig-async/issues/2

### Futures & Promises
- [ ] lazy
- [ ] eager ? (consider if this should be removed & only "lazy" should be kept)


### Structured Concurrency
- [ ] cancellation token/source
- [ ] nursery?

### Testing
- [x] basic random fault injection for unit tests
- [ ] study [Twist](https://gitlab.com/Lipovsky/twist)

### Core
- [x] spin lock
- [x] intrusive foward list/queue/stack (not thread-safe)
- [ ] [Michael & Scott lock-free queue](https://dl.acm.org/doi/pdf/10.1145/248052.248106)
- [ ] hazard pointers

### Performance
- [ ] integrate with Tracy etc.
- [ ] optimize memory orders

### IO
- [ ] Play around with self-hosted IO dispatch
- [ ] Consider integration with [libxev](https://github.com/mitchellh/libxev)

### Long-term initiatives
- [ ] integration with Zig async/await
  - It is currently unclear what direction Zig will go with for language support of async/await. 
  - Once the Zig Language direction is decided, we will consider the best way to integrate it with the library.

## Memory Management Policy:
  - API must allow fine-grained control over allocations for users who care
  - provide "managed" API for users who don't
  - regardless of memory management approach chosen by the user, library must minimize # of runtime allocations

