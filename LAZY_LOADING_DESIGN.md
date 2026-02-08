# Lazy Loading & Streaming: Problem Statement and Edge Cases

## Overview

ci-queue is a Ruby gem that distributes test execution across multiple CI workers using Redis as a coordination backend. Currently, every worker (leader and consumers) eagerly loads **all** test files upfront before running any tests. For large monoliths (36K+ test files, 588K+ tests), this eager loading consumes significant memory — each consumer pod loads every test file even though it only runs a small subset.

**Goal**: Reduce consumer memory by loading test files on-demand (lazily), only when a test from that file is actually dequeued for execution.

## Architecture

### Current (Eager) Flow

1. **Leader** loads all test files, discovers all tests, pushes test IDs to Redis queue
2. **Consumers** also load all test files (building an in-memory index), then poll Redis for test IDs to run
3. When a consumer gets a test ID like `"MyClass#test_method"`, it looks up the class in its pre-built index and runs the test

### New (Lazy/Streaming) Flow

1. **Leader** loads test files one-by-one, discovers tests from each file, and **streams** them to Redis incrementally (in batches)
2. **Consumers** do NOT load test files upfront. They poll Redis and receive queue entries that include enough information to resolve the test
3. When a consumer gets a queue entry, it loads the test file on-demand, resolves the class, and runs the test
4. After the test, the file's classes remain loaded for any future tests from the same file

### Queue Entry Format

In eager mode, queue entries are plain test IDs: `"ClassName#test_method"`

In streaming/lazy mode, queue entries need more information in order to resolve tests. The file path is needed because consumers don't have all files loaded — they need to know which file to load to find the class.

Redis operations (Lua scripts for acknowledge, requeue, reserve_lost, heartbeat) write to keys like `processed` and `error-reports` that are keyed by plain test ID. Whatever format is chosen for queue entries, these operations must be able to extract the plain test_id.

## Existing Components

### 1. Redis Worker (`ci/queue/redis/worker.rb`)

**Framework-agnostic** — knows nothing about Minitest, RSpec, etc. Handles leader election, queue population, polling, acknowledgment, requeue, heartbeat, and reservation tracking.

### 2. SingleExample (`minitest/queue.rb`)

**Minitest-specific** — represents a single test to run. Stores class name and method name. Provides `runnable` (the resolved Class), `id` (for Redis operations), and `run` (execute the test and return a result).

### 3. Runner (`minitest/queue/runner.rb`)

**Minitest-specific** — handles test discovery (loading files and extracting test methods) and the CLI interface (`minitest-queue` command).

### 4. Lua Scripts (acknowledge, requeue, reserve_lost, heartbeat)

Handle queue operations atomically in Redis.

## Edge Cases and Problems

### Class Resolution

These problems arise because the consumer must resolve a class name string to an actual Ruby Class object, potentially loading the file that defines it first.

#### 1. `const_get` ancestor chain leakage

Ruby's `Module#const_get(name)` with default `inherit=true` searches the receiver's ancestor chain, which includes `Object` for all modules. So `GraphApi::Admin.const_get("DraftOrderTest")` finds a **top-level** `DraftOrderTest` instead of raising `NameError`, even when `GraphApi::Admin::DraftOrderTest` hasn't been loaded yet.

**Impact**: Wrong class runs the test. The test method doesn't exist on the wrong class (NoMethodError). The result's `klass` mismatches the queue entry's class name (ReservationError on acknowledge).

#### 2. Short class name collisions

Multiple test files can define classes with the same short name (e.g., `OrderTest` in both `test/models/order_test.rb` and `test/controllers/order_test.rb`). A naive `Object.const_get("OrderTest")` returns whichever was loaded first, which may be the wrong one.

**Impact**: Wrong class runs the test, same cascading failures as #1.

#### 3. Module-vs-Class confusion

Some test class names match module names in the application. Resolving `"Foo"` via `const_get` might return a Module, not a Class. You can't call `.new` on a Module to instantiate a test.

#### 4. File loading in forked workers

When using fork-based parallelism (e.g., Pitchfork), the parent process's `$LOADED_FEATURES` is inherited by child workers. So `require(file)` is a no-op in the child (Ruby thinks it's already loaded), but the class definitions from that file don't exist in the child (they were never executed in this process).

**Impact**: Class resolution fails even though the file appears loaded.

#### 5. Double-loading and constant redefinition warnings

If a file is executed more than once (e.g., via `Kernel.load`), it redefines constants. In environments with strict warning enforcement, this causes `"already initialized constant"` errors that crash the test.

**Impact**: Using `Kernel.load` as a fallback for forked workers (#4) can trigger constant redefinition warnings that are elevated to errors.

### Test Execution Safety

#### 6. Errors during file loading crash workers

When loading a test file on-demand, the file's top-level code may raise arbitrary errors (missing dependencies, extension ordering errors, invalid API versions). If these errors aren't contained, they propagate up and crash the worker process. A crashed worker leaves tests stuck in the `running` set until they time out.

Additionally, any error-handling code that accesses the class (e.g., to get source_location for error reporting) can re-trigger the same file loading, causing the same error a second time in a context where it's no longer caught.

**Impact**: Worker crashes (exit 42). Tests that were assigned to this worker are lost until timeout recovery.

#### 7. Dynamically generated test methods don't exist on worker

Some test classes generate test methods dynamically based on what other classes are loaded. For example, a test might iterate over all loaded ActiveRecord models and generate `test_ModelName_associations_are_valid` for each one. The leader discovers all these tests (it has everything loaded), but the worker only loads the specific test file — the model classes that would trigger method generation aren't loaded.

**Impact**: The test method doesn't exist on the worker. NoMethodError when attempting to run the test. The test will always fail in lazy mode.

#### 8. Test ID mismatch between result and queue entry

After running a test, the test framework constructs the result's class name from `test.class.name`. Ruby's `Class#name` returns the name from the **first** constant assignment, which may differ from the fully-qualified name used in the queue entry. For example, a class accessible as `GraphApi::Admin::DraftOrderTest` might have `.name` return `"DraftOrderTest"` if it was originally defined at the top level and later assigned into the namespace.

**Impact**: The acknowledged test_id (from the result) doesn't match the reserved entry (from the queue). This causes a ReservationError when the worker tries to acknowledge or requeue the test.

### Streaming Coordination

#### 9. Consumer exits before leader finishes streaming

The leader pushes tests incrementally in batches as it loads files. Between batches, the Redis queue may be temporarily empty. Without coordination, consumers see an empty queue and think the run is exhausted, exiting the poll loop prematurely.

**Impact**: Consumers exit early, leaving unprocessed tests in the queue.

#### 10. Progress reporting during streaming

The total test count is not known upfront — it grows as the leader discovers tests. Early in streaming, the total may be 0 or very small, causing progress calculations to show negative numbers or nonsensical percentages.

### DRb / Parallel Testing

#### 11. Class objects can't be marshaled over DRb

In parallel testing with fork-based servers (e.g., Pitchfork), the parent process pops tests from the queue and sends them to forked workers via DRb (Distributed Ruby). Ruby's `Class` objects can't be marshaled for DRb transport — you can't send `MyTestClass` over the wire.

The solution must provide a way to represent a test's class that serializes safely over DRb and resolves to the actual class on the receiving end.

#### 12. `BasicObject` constraints

If a proxy object is used for class resolution, extending `BasicObject` (to delegate all method calls to the underlying class) introduces constraints:
- Standard methods (`is_a?`, `==`, `hash`, `to_s`, `inspect`, `respond_to?`) don't exist and must be explicitly implemented
- Top-level constants (`File`, `Process`, `Kernel`) must be referenced with `::` prefix since `BasicObject` has no `Object` in its ancestry
- Ruby's `if` modifier returns `nil` when the condition is false, which interacts poorly with instance variable assignment (e.g., `@x = foo if bar` sets `@x` to nil when `bar` is false)

## Constraints

1. **Worker layer must remain framework-agnostic**: `redis/worker.rb` should not reference Minitest, RSpec, etc. It deals with queue entries (strings), callbacks, and Redis operations.

2. **Fail gracefully, never crash the worker**: Any error during test loading or execution should produce an error result, not crash the poll loop. A crashed worker leaves tests stuck in the `running` set until they time out.

3. **Backward compatibility**: The eager loading flow must continue to work. Any changes to queue entry format or Redis operations must handle both eager and lazy modes.

4. **Fork safety**: The solution must work correctly across `fork()` boundaries, where `$LOADED_FEATURES` is inherited but class definitions are not.

5. **Idempotent file loading**: Loading the same file multiple times should be safe (no constant redefinition errors, no duplicate test method registration).
