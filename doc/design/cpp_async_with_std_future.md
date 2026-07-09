# Using the C++ async wrapper with `std::promise` / `std::future`

> **You no longer need to write this bridge by hand.** The generated wrapper
> ships a `std::future`-returning sibling for every request method:
>
> ```cpp
> std::future<Result<GetDevice>>
> getDeviceFuture(int64_t deviceId,
>                 std::chrono::milliseconds timeout =
>                     std::chrono::milliseconds(MYLIB_DEFAULT_ASYNC_TIMEOUT_MS));
> ```
>
> Use it directly: `auto fut = lib.getDeviceFuture(id); auto r = fut.get();`.
> It is backpressure-aware: past the async window the issuing call blocks
> briefly on an internal `std::counting_semaphore` instead of erroring.
> The rest of this document explains *how* that method is implemented (the
> `std::promise` bridge) and why it does **not** use `std::async`.

The generated C++ async method is **callback-based**:

```cpp
int32_t getDeviceAsync(int64_t deviceId,
                       std::function<void(Result<GetDevice>)> cb,
                       std::chrono::milliseconds timeout =
                           std::chrono::milliseconds(MYLIB_DEFAULT_ASYNC_TIMEOUT_MS));
```

- returns `0` when **queued** (the callback fires exactly once, later, on the
  library's delivery thread),
- returns a **negative** code when **not queued** (the callback never fires):
  `Mylib::asyncAgain` (`-6`, EAGAIN), `asyncBadContext` (`-5`),
  `asyncNoCallback` (`-7`), `asyncEncodeFailed` (`-1`).

That maps onto `std::future<Result<T>>` perfectly: a `std::promise` is fulfilled
from exactly one place, and `future::get()` blocks the caller until it is.

## The bridge

```cpp
#include <future>
#include <memory>
#include "mylib.hpp"
using namespace mylib;

// Turn the callback into a std::future. The promise is held by a shared_ptr
// because it must be fulfilled from exactly ONE of two places:
//   * the delivery-thread callback  (when rc == 0, the call was queued), or
//   * inline right here             (when rc != 0, the callback won't fire).
// The async contract guarantees those are mutually exclusive, so the promise
// is set exactly once — set_value twice would throw.
std::future<Result<GetDevice>> getDeviceFuture(Mylib& lib, int64_t id) {
    auto prom = std::make_shared<std::promise<Result<GetDevice>>>();
    auto fut  = prom->get_future();

    int32_t rc = lib.getDeviceAsync(id, [prom](Result<GetDevice> r) {
        prom->set_value(std::move(r));   // runs on the delivery thread
    });

    if (rc != 0) {                       // not queued → fulfil it ourselves
        prom->set_value(Result<GetDevice>::err(
            rc == Mylib::asyncAgain
                ? std::string("EAGAIN: async window full")
                : std::string("not queued: rc=") + std::to_string(rc)));
    }
    return fut;
}
```

Why `shared_ptr<promise>`: the lambda is copied into the wrapper's
`std::function` and boxed as the opaque `userData`; it lives until the callback
fires (or, on a negative return, we drop it after setting the value here). The
`shared_ptr` lets both the lambda and the `rc != 0` branch reference the same
promise without worrying about which one owns it.

`promise::set_value` from the delivery thread → `future::get()` on your thread
is exactly what `promise`/`future` are built for; no extra synchronization
needed. `-12` (timeout) / `-11` (shutdown) / provider errors all arrive as a
`Result::err(...)` inside the callback, so they flow through the same path.

## Usage

```cpp
// 1) Single call — block on the future.
auto fut = getDeviceFuture(lib, id);
Result<GetDevice> r = fut.get();          // parks THIS thread until delivery
if (r.isOk()) printf("name=%s\n", r->name.c_str());

// 2) Pipelined — issue all, then collect. Concurrency is bounded by the async
//    WINDOW (Mylib::asyncQueueDepth), NOT by OS threads. This is the win:
//    one delivery thread fulfils N promises; you park only at get().
std::vector<std::future<Result<GetDevice>>> futs;
for (int64_t id : ids) futs.push_back(getDeviceFuture(lib, id));
for (size_t i = 0; i < futs.size(); ++i) {
    auto res = futs[i].get();
    printf("[%zu] %s\n", i,
           res.isOk() ? res->name.c_str() : res.error().c_str());
}

// 3) Caller-side deadline (belt-and-suspenders; the library timeout already
//    bounds the call). Letting the future die before the callback fires is
//    safe: the promise is kept alive by the boxed lambda, so a late set_value
//    on a future-less promise is a harmless no-op.
if (fut.wait_for(std::chrono::seconds(2)) == std::future_status::ready)
    handle(fut.get());
```

For backpressure, keep the `getDeviceAsync` retry loop *outside* the bridge (so
a full window doesn't immediately resolve the future with an EAGAIN error), or
treat the EAGAIN-`Result::err` as a signal to back off and re-issue.

## Why NOT `std::async`

`std::async` runs a callable on another thread and hands you a future. It is the
right tool for the **blocking sync** method, and the **wrong** tool for the
async one.

```cpp
// OK-ish: parallelize the BLOCKING sync call. Each std::async parks one OS
// thread that blocks inside getDevice() (on the library's condvar) until the
// response lands — i.e. thread-per-in-flight-request, the exact ceiling the
// async ABI removes. Fine for a few calls; does not scale.
auto f = std::async(std::launch::async, [&lib, id]{ return lib.getDevice(id); });
auto r = f.get();
// (Caveat: a std::launch::async future's destructor BLOCKS until the task
//  finishes, so you cannot truly fire-and-forget this way.)

// WRONG: wrapping the async method in std::async.
auto bad = std::async(std::launch::async,
                      [&]{ return lib.getDeviceAsync(id, cb); });
// `bad` resolves when the ENQUEUE returns (the int32_t rc), NOT when the
// response arrives. The actual result still comes through `cb` later. Mixing
// the two just adds a pointless thread.
```

| Approach | Threads parked per in-flight call | Scales to the async window? |
|---|---|---|
| `std::promise` + `getDeviceAsync` | **0** (delivery thread fulfils) | **yes** |
| `std::async` + sync `getDevice` | 1 OS thread each | no (thread-per-request) |
| `std::async` + `getDeviceAsync` | 1 OS thread, wrong semantics | — (don't) |

**Rule of thumb:** use `std::promise` to adapt the async callback into a
`std::future`; reach for `std::async` only when you deliberately want to run the
*blocking* sync API on a worker thread.
