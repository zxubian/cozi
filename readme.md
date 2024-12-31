# zig-async

## Goals
- to provide a set of independantly composable, orthogonal components for low-level parallel & concurrent computing

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
[ ] Fiber pool
  - reference: [Parallelizing the Naughty Dog Engine Using Fibers](https://www.youtube.com/watch?v=HIVBhKj7gQU&t=628s)
  - [ ] Worker abstraction over fibers and threads
Scheduler abstraction
- [ ] Separate "scheduler" from "executor"
- [ ] Scheduler "submit" hints (inline/lifo/queue-end etc)
### Fibers - stackfull cooperatively-scheduled user-space threads
- [x] Basic support
  - [x] Yield
Synchronization primitives
  - [x] Mutex
  - [x] Event
  - [x] Wait Group
  - [x] Barrier 
  - [ ] Optimize memory orders
- [ ] Channel (spinlock implementation)
- [ ] Select
  - [ ] Lock-free channel/select
### Futures & Promises
- [] eager (consider if this should be removed & only "lazy" should be kept)
- [] lazy
### Structured Concurrency
- [] TBC
### Testing
- [ ] basic random fault injection for unit tests
- [ ] study [Twist](https://gitlab.com/Lipovsky/twist) & consider which features to port
### Core
- [x] spin lock
- [x] intrusive foward list/queue/stack (to be used with locks)
- [ ] hazard pointers
- [ ] atomic shared pointer (?)
### Misc
- [ ] set up project to be consumed as a dependency in other Zig projects (main module)
- [ ] clean-up internal module structure & imports
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

